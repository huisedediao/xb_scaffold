// MCP 会话注册表：发现本机 VM service、维护当前会话、序列化写操作。
//
// 设计要点：
//   - 复用 bin/src/session/discovery.dart（与 daemon 同一套发现逻辑）；
//   - 会话 id 用端口（s65296），稳定且便于人读；fingerprint 用于去重；
//   - VmClient 按会话懒建并复用（每次工具调用重新握手会拖慢 10 倍）；
//   - 写操作（tap/swipe/input/navigate）串行化：并发注入手势会让
//     GestureBinding 的指针状态互相干扰。
library;

import 'dart:async';
import 'dart:io';

import '../scenario/vm_client.dart';
import '../session/discovery.dart';
import 'client_scope.dart';

/// 一个可操作的调试会话。
class McpSession {
  McpSession({
    required this.id,
    required this.wsUrl,
    required this.port,
    required this.source,
    required this.fingerprint,
    required this.appName,
    this.manual = false,
  });

  final String id;
  final String wsUrl;
  final int port;

  /// 来源标识：adb:SERIAL#port:N / hdc:SERIAL#port:N / port:N。
  final String source;
  final String fingerprint;
  final String appName;

  /// 由 --uri 手工注入：扫描时不被移除（可能在另一台机器的转发端口上）。
  final bool manual;

  VmClient? _client;

  VmClient get client => _client ??= VmClient(wsUrl);

  bool get connected => _client != null;

  /// 会话所属设备（从 source 里拆出 adb:/hdc: 前缀），无转发映射时为 null。
  String? get deviceId {
    final i = source.indexOf('#');
    if (i <= 0) return null;
    final s = source.substring(0, i);
    return s.contains(':') ? s : null;
  }

  String get platform {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return Platform.operatingSystem;
  }

  Map<String, Object?> toJson({bool current = false}) => <String, Object?>{
        'id': id,
        'port': port,
        'wsUrl': wsUrl,
        // Flutter 的 getVM.name 恒为 'vm'，无信息量，归一化为 null。
        'app': (appName.isEmpty || appName == 'vm') ? null : appName,
        'source': source,
        'deviceId': deviceId,
        'platform': platform,
        'connected': connected,
        'current': current,
      };

  Future<void> close() async {
    final c = _client;
    _client = null;
    if (c != null) {
      try {
        await c.close();
      } catch (_) {
        // 关闭失败按已断开处理。
      }
    }
  }
}

/// 会话集合 + 当前选择 + 写操作队列。
class SessionRegistry {
  SessionRegistry({this.skipPorts = const <int>{}});

  /// 需要排除的自身端口（MCP HTTP / GUI）。
  final Set<int> skipPorts;

  final Map<String, McpSession> _sessions = <String, McpSession>{};

  /// 按 MCP 客户端连接各记一份「当前会话」。
  ///
  /// 同一个 AI 开两个会话连到**同一个**进程时（Qoder 两个窗口都连 HTTP 46140），
  /// 各选各的会话，不会互相覆盖（见 client_scope.dart）。
  /// 空串 key = 默认值：`--uri` 注入的会话，以及客户端没回传 Mcp-Session-Id 时的兼底。
  final Map<String, String> _currentByClient = <String, String>{};

  DateTime? _lastRefresh;
  String? _lastError;
  int _lastScannedPorts = 0;

  /// 写操作串行队列（读操作不受限）。
  Future<void> _writeChain = Future<void>.value();

  List<McpSession> get all {
    final list = _sessions.values.toList()
      ..sort((a, b) => a.port.compareTo(b.port));
    return list;
  }

  McpSession? get current =>
      _currentId == null ? null : _sessions[_currentId!];

  /// 本连接选中的会话；自己没选过时退回默认（`--uri` / 单会话自动选中）。
  ///
  /// 只有一个会话时**直接算选中**（不落表）：否则第二个窗口在第一个窗口 3 秒
  /// 内打开时，会命中扫描缓存、跳过自动选中，一直卡在「未选择会话」。
  String? get _currentId {
    final own = _currentByClient[clientKey];
    if (own != null) return own;
    if (clientKey.isNotEmpty) {
      final dflt = _currentByClient[''];
      if (dflt != null) return dflt;
    }
    if (_sessions.length == 1) return _sessions.keys.first;
    return null;
  }

  set _currentId(String? id) {
    if (id == null) {
      _currentByClient.remove(clientKey);
    } else {
      _currentByClient[clientKey] = id;
    }
  }

  /// 当前客户端连接标识（HTTP = Mcp-Session-Id，stdio = `stdio`）。
  String get clientKey => currentMcpClient;

  /// 各客户端连接当前选中的会话（排障用：谁选了哪个）。
  Map<String, String> get currentByClient =>
      Map<String, String>.unmodifiable(_currentByClient);

  String? get currentId => _currentId;
  DateTime? get lastRefresh => _lastRefresh;
  String? get lastError => _lastError;
  int get lastScannedPorts => _lastScannedPorts;

  McpSession? byId(String id) => _sessions[id] ?? _sessions['s$id'];

  /// 扫描本机会话；[maxAge] 内的结果直接复用（避免 AI 连续调用反复扫盘）。
  Future<List<McpSession>> refresh({
    bool force = false,
    Duration maxAge = const Duration(seconds: 3),
  }) async {
    final last = _lastRefresh;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < maxAge) {
      return _settleSelection();
    }
    _lastRefresh = DateTime.now();
    try {
      final ports = await loopbackListeningPorts();
      _lastScannedPorts = ports.length;
      final discovered = await discoverLocalVmServices(skipPorts: skipPorts);
      final seen = <String>{};
      for (final d in discovered) {
        final id = 's${d.port}';
        seen.add(id);
        final existing = _sessions[id];
        if (existing != null && existing.fingerprint == d.fingerprint) {
          continue; // 同一实例同一端口，保留已有连接。
        }
        if (existing != null) {
          await existing.close();
        }
        _sessions[id] = McpSession(
          id: id,
          wsUrl: d.wsUrl,
          port: d.port,
          source: d.source,
          fingerprint: d.fingerprint,
          appName: d.name,
        );
      }
      // 端口已消失的会话移除（fingerprint 相同的重连由新端口覆盖）。
      for (final id in _sessions.keys.toList()) {
        if (!seen.contains(id) && !(_sessions[id]?.manual ?? false)) {
          await _sessions.remove(id)?.close();
          // 会话没了，所有指着它的连接都清掉。
          _currentByClient.removeWhere((_, v) => v == id);
        }
      }
      _lastError = null;
    } catch (e) {
      _lastError = e.toString();
    }
    // 只有一个会话时自动选中，省掉一次 use_session 往返（每个连接各选各的）。
    return _settleSelection();
  }

  /// 唯一会话时给本连接记上选中项（台账用），并清掉指向已消失会话的记录。
  ///
  /// 命中 3 秒扫描缓存时也要走一遍：不然同一助手刚开的第二个窗口不会出现在
  /// `xbume_clients` 的「各记各的当前会话」里（读取本身有懒回退，不会播错会话）。
  List<McpSession> _settleSelection() {
    if (_currentByClient[clientKey] == null && _sessions.length == 1) {
      _currentByClient[clientKey] = _sessions.keys.first;
    }
    final cur = _currentId;
    if (cur != null && !_sessions.containsKey(cur)) {
      _currentByClient.removeWhere((_, v) => v == cur);
    }
    return all;
  }

  /// 选定会话；不存在时按最新扫描结果重试一次。
  Future<McpSession> use(String id) async {
    var s = byId(id);
    if (s == null) {
      await refresh(force: true);
      s = byId(id);
    }
    if (s == null) {
      final known = all.map((e) => e.id).join(', ');
      throw StateError(
          '会话 $id 不存在${known.isEmpty ? '（未发现任何调试会话）' : '，可用：$known'}');
    }
    _currentId = s.id;
    return s;
  }

  /// 手工注入会话（--uri）：跳过扫描，直接注册并选中。
  McpSession addManual(String raw) {
    final ws = normalizeVmUri(raw);
    final u = Uri.tryParse(ws);
    final port = u != null && u.hasPort ? u.port : 0;
    final id = port > 0 ? 's$port' : 'manual';
    final s = McpSession(
      id: id,
      wsUrl: ws,
      port: port,
      source: 'manual:$raw',
      fingerprint: 'manual:$ws',
      appName: 'manual',
      manual: true,
    );
    _sessions[id] = s;
    // `--uri`（无连接上下文）注入的会话兼作默认值；工具调用里拉起的只给当前连接。
    if (clientKey.isEmpty) _currentByClient[''] = id;
    _currentId = id;
    return s;
  }

  /// 取当前会话；未指定且无候选时给出可操作提示。
  McpSession requireCurrent([String? id]) {
    if (id != null && id.isNotEmpty) {
      final s = byId(id);
      if (s == null) {
        throw StateError('会话 $id 不存在，先调用 xbume_sessions 刷新');
      }
      return s;
    }
    final s = current;
    if (s == null) {
      throw StateError('未选择会话：先调用 xbume_sessions 查看，再用 xbume_use_session 选定');
    }
    return s;
  }

  /// 串行执行写操作；任意一步抛异常不阻断后续队列。
  Future<T> serializeWrite<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _writeChain = _writeChain.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// 会话不可用时清空连接，便于下次重建。
  Future<void> invalidate(McpSession s) async {
    await s.close();
  }

  Future<void> closeAll() async {
    for (final s in _sessions.values) {
      await s.close();
    }
    _sessions.clear();
    _currentByClient.clear();
  }
}
