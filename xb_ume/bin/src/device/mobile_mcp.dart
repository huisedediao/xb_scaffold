// 可选的 mobile-mcp 适配器（P2）。
//
// 定位：把 MobileNext 的 mobile-mcp 后端当成"另一个设备后端"，补齐自研
// adb/hdc/simctl/idevice 覆盖不到的能力。它是**可选**的：
//   - 默认不启用（--device-backend 必须显式包含 mobile-mcp）；
//   - npx 不存在 / 适配器起不来 / initialize 失败 → 该后端自动禁用并给出
//     原因，不影响其他后端；
//   - 能力按对方 tools/list 的实际暴露情况推导，不假设工具名固定，
//     没有对应工具的能力一律不声明（不做"假装支持"）。
//
// 传输：手写 JSON-RPC over Streamable HTTP（dart:io），零新增依赖。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bridge.dart';
import 'process.dart';

/// 适配器默认监听端口（与 MCP HTTP 46140 / GUI 46129-46138 错开）。
const int kMobileMcpDefaultPort = 46150;

class MobileMcpBridge extends DeviceBridge {
  MobileMcpBridge({this.port = kMobileMcpDefaultPort, String? npx})
      : _npx = npx ?? findExecutable('npx');

  final int port;
  final String? _npx;
  Process? _proc;
  String? _sessionId;
  String? _baseUrlCache;
  int _seq = 0;
  Future<void>? _boot;
  String? _startError;
  List<Map<String, Object?>> _tools = const <Map<String, Object?>>[];

  @override
  String get backend => 'mobile-mcp';

  @override
  bool get available => _npx != null && _startError == null;

  @override
  String? get unavailableReason {
    if (_npx == null) return '未找到 npx（需要 Node.js 18+，npm i -g npx）';
    return _startError;
  }

  @override
  Set<DeviceCapability> get capabilities => _discoverCapabilities(_tools);

  // ── 启动与 JSON-RPC ──

  Future<void> _ensure() {
    if (_startError != null) {
      throw DeviceCommandError(backend, 'start', _startError!);
    }
    return _boot ??= _start();
  }

  Future<void> _start() async {
    final exe = _npx!;
    // 端口上已有适配器且能握手：直接复用，不再拉起进程。
    if (await _probeAny()) return;
    try {
      _proc = await Process.start(
        exe,
        <String>['-y', '@mobilenext/mobile-mcp@latest', '--listen', '$port'],
        // Windows 上 npx 是 npx.cmd：CreateProcess 不能直接执行批处理。
        runInShell: needsShellOnWindows(exe),
      );
    } on ProcessException catch (e) {
      _startError = '启动 mobile-mcp 失败：${e.message}';
      throw DeviceCommandError(backend, 'npx mobile-mcp', _startError!);
    }
    // 进程输出必须被消费，否则 pipe 满了会卡死适配器；stderr 留尾用于报告失败原因。
    final tail = <String>[];
    _proc!.stdout.drain<void>();
    _proc!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      tail.add(line);
      if (tail.length > 6) tail.removeAt(0);
    });
    var exited = false;
    unawaited(_proc!.exitCode.then((_) => exited = true));
    // 首次 npx 要下载适配器包，给比常规探测更宽的窗口。
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (exited) {
        _startError = 'mobile-mcp 启动即退出：${_tail(tail)}';
        throw DeviceCommandError(backend, 'npx mobile-mcp', _startError!);
      }
      if (await _probeAny()) return;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    _startError =
        'mobile-mcp 30 秒内未监听 127.0.0.1/[::1]:$port：${_tail(tail)}';
    throw DeviceCommandError(backend, 'npx mobile-mcp', _startError!);
  }

  /// 适配器的监听地址不确定：Node/Express 常见只绑 `[::1]`，
  /// 因此同时试 IPv4 / IPv6 / localhost，记住能握手的那个。
  List<String> get _candidates => <String>[
        'http://127.0.0.1:$port/mcp',
        'http://[::1]:$port/mcp',
        'http://localhost:$port/mcp',
      ];

  String get _baseUrl => _baseUrlCache ?? _candidates.first;

  Future<bool> _probeAny() async {
    for (final url in _candidates) {
      if (await _probeEndpoint(url)) {
        _baseUrlCache = url;
        return true;
      }
    }
    return false;
  }

  /// stderr 尾部（多行合成一行，便于放进 reason）。
  String _tail(List<String> lines) =>
      lines.isEmpty ? '（无输出）' : oneLine(lines.join(' | '), max: 300);

  Future<bool> _probeEndpoint(String url) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;
      req.headers.set('Accept', 'application/json, text/event-stream');
      req.write(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': ++_seq,
        'method': 'initialize',
        'params': <String, Object?>{
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{},
          'clientInfo': <String, Object?>{'name': 'xb_ume', 'version': '0'},
        },
      }));
      final resp = await req.close().timeout(const Duration(seconds: 4));
      final sid = resp.headers.value('mcp-session-id');
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return false;
      final msg = _extractJson(body);
      if (msg == null || msg['result'] == null) return false;
      _sessionId = sid;
      await _sendNotification(url, 'notifications/initialized');
      _tools = await _listTools(url);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, Object?>>> _listTools(String url) async {
    final r = await _rpc(url, 'tools/list', <String, Object?>{});
    final tools = (r['tools'] as List?) ?? const <Object?>[];
    return tools
        .whereType<Map>()
        .map((e) => e.cast<String, Object?>())
        .toList(growable: false);
  }

  Future<Map<String, Object?>> _call(
      String tool, Map<String, Object?> args) async {
    await _ensure();
    final r = await _rpc(_baseUrl, 'tools/call', <String, Object?>{
      'name': tool,
      'arguments': args,
    });
    return r;
  }

  Future<Map<String, Object?>> _rpc(
    String url,
    String method,
    Map<String, Object?> params,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;
      req.headers.set('Accept', 'application/json, text/event-stream');
      if (_sessionId != null) req.headers.set('mcp-session-id', _sessionId!);
      req.write(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': ++_seq,
        'method': method,
        'params': params,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 60));
      final sid = resp.headers.value('mcp-session-id');
      if (sid != null) _sessionId = sid;
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw DeviceCommandError(
            backend, method, 'HTTP ${resp.statusCode}: ${oneLine(body)}');
      }
      final msg = _extractJson(body);
      if (msg == null) {
        throw DeviceCommandError(backend, method, '响应不是 JSON：${oneLine(body)}');
      }
      final err = msg['error'];
      if (err is Map) {
        throw DeviceCommandError(
            backend, method, oneLine('${err['message'] ?? err}'));
      }
      final result = msg['result'];
      return result is Map
          ? result.cast<String, Object?>()
          : <String, Object?>{};
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _sendNotification(String url, String method) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;
      req.headers.set('Accept', 'application/json, text/event-stream');
      if (_sessionId != null) req.headers.set('mcp-session-id', _sessionId!);
      req.write(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': method,
        'params': <String, Object?>{},
      }));
      await (await req.close()).drain<void>();
    } catch (_) {
      // 通知失败不阻断（部分实现不需要 initialized）。
    } finally {
      client.close(force: true);
    }
  }

  // ── DeviceBridge 实现（按发现到的工具名映射） ──

  @override
  Future<void> warmup() async {
    await _ensureQuiet();
  }

  /// 确保适配器就绪；失败返回 false（错误信息留在 _startError）。
  Future<bool> _ensureQuiet() async {
    try {
      await _ensure();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<DeviceInfo>> listDevices() async {
    if (!await _ensureQuiet()) return <DeviceInfo>[];
    final tool = _findTool(const <String>['list', 'available', 'devices']);
    if (tool == null) return <DeviceInfo>[];
    final r = await _call(tool, <String, Object?>{});
    return _parseDevices(_resultText(r));
  }

  @override
  Future<void> install(String deviceId, String artifact) async {
    final tool = await _readyTool(const <String>['install']);
    if (tool == null) {
      throw DeviceUnsupported(DeviceCapability.install, backend, '适配器未暴露安装工具');
    }
    await _call(tool, <String, Object?>{
      ..._deviceArg(deviceId),
      'appPath': artifact,
      'path': artifact
    });
  }

  @override
  Future<void> uninstall(String deviceId, String packageId) async {
    final tool = await _readyTool(const <String>['uninstall']);
    if (tool == null) {
      throw DeviceUnsupported(
          DeviceCapability.uninstall, backend, '适配器未暴露卸载工具');
    }
    await _call(tool, <String, Object?>{
      ..._deviceArg(deviceId),
      'packageName': packageId,
      'appId': packageId,
      'bundleId': packageId,
    });
  }

  @override
  Future<String> launch(String deviceId, String packageId) async {
    final tool =
        await _readyTool(const <String>['launch', 'open', 'start'], any: true);
    if (tool == null) {
      throw DeviceUnsupported(DeviceCapability.launch, backend, '适配器未暴露启动工具');
    }
    final r = await _call(tool, <String, Object?>{
      ..._deviceArg(deviceId),
      'packageName': packageId,
      'appId': packageId,
      'bundleId': packageId,
    });
    return oneLine(_resultText(r), max: 200);
  }

  @override
  Future<void> terminate(String deviceId, String packageId) async {
    final tool = await _readyTool(
        const <String>['terminate', 'force-stop', 'kill'],
        any: true);
    if (tool == null) {
      throw DeviceUnsupported(
          DeviceCapability.terminate, backend, '适配器未暴露停止工具');
    }
    await _call(tool, <String, Object?>{
      ..._deviceArg(deviceId),
      'packageName': packageId,
      'appId': packageId,
      'bundleId': packageId,
    });
  }

  @override
  Future<void> pressKey(String deviceId, DeviceKey key) async {
    final tool =
        await _readyTool(const <String>['press', 'keyevent'], any: true);
    if (tool == null) {
      throw DeviceUnsupported(DeviceCapability.pressKey, backend, '适配器未暴露按键工具');
    }
    await _call(tool, <String, Object?>{
      ..._deviceArg(deviceId),
      // mobile-mcp 用 button（枚举名）；其他实现可能用 key，两个都给。
      'button': _buttonName(key),
      'key': key.name,
    });
  }

  @override
  Future<void> tapNative(String deviceId, int x, int y) async {
    final tool = await _readyTool(const <String>['tap', 'click'], any: true);
    if (tool == null) {
      throw DeviceUnsupported(
          DeviceCapability.tapNative, backend, '适配器未暴露点击工具');
    }
    await _call(
        tool, <String, Object?>{..._deviceArg(deviceId), 'x': x, 'y': y});
  }

  @override
  Future<List<CrashReport>> crashList(
    String deviceId, {
    String? packageId,
    int limit = 20,
  }) async {
    final tool = await _readyTool(const <String>['crash']);
    if (tool == null) {
      throw DeviceUnsupported(
          DeviceCapability.crashList, backend, '适配器未暴露崩溃工具');
    }
    final r = await _call(tool, <String, Object?>{
      ..._deviceArg(deviceId),
      if (packageId != null) 'packageName': packageId,
      'limit': limit,
    });
    return <CrashReport>[
      CrashReport(
        id: 'mobile-mcp',
        title: oneLine(_resultText(r), max: 120),
        package: packageId,
        summary: oneLine(_resultText(r), max: 200),
      ),
    ];
  }

  @override
  Future<String> crashGet(String deviceId, String crashId) async {
    throw DeviceUnsupported(
      DeviceCapability.crashGet,
      backend,
      'mobile-mcp 适配器未提供稳定的按 id 读取崩溃能力',
    );
  }

  /// 关闭适配器进程（MCP server shutdown 时调用）。
  @override
  Future<void> dispose() async {
    final p = _proc;
    _proc = null;
    if (p != null) {
      try {
        p.kill(ProcessSignal.sigterm);
        await p.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          p.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }
  }

  // ── 解析辅助 ──

  /// 在工具名里按关键词找（全部小写、忽略分隔符）。
  String? _findTool(List<String> keywords) {
    for (final t in _tools) {
      final name =
          '${t['name']}'.toLowerCase().replaceAll(RegExp(r'[\_\-\s]'), '');
      if (keywords.every(name.contains)) return '${t['name']}';
    }
    return null;
  }

  /// 确保握手后取工具名：适配器首次调用时 _tools 还是空的。
  Future<String?> _readyTool(List<String> keywords, {bool any = false}) async {
    await _ensure();
    return any ? _findToolAny(keywords) : _findTool(keywords);
  }

  /// 择一匹配：命中任一关键词即可（用于 tap|click 这类同义工具名）。
  String? _findToolAny(List<String> keywords) {
    for (final t in _tools) {
      final name =
          '${t['name']}'.toLowerCase().replaceAll(RegExp(r'[\_\-\s]'), '');
      if (keywords.any(name.contains)) return '${t['name']}';
    }
    return null;
  }

  /// DeviceKey → mobile-mcp 的 button 枚举名。
  String _buttonName(DeviceKey key) => switch (key) {
        DeviceKey.back => 'BACK',
        DeviceKey.home => 'HOME',
        DeviceKey.enter => 'ENTER',
        DeviceKey.delete => 'DELETE',
        DeviceKey.tab => 'TAB',
        DeviceKey.escape => 'ESCAPE',
        DeviceKey.menu => 'MENU',
        DeviceKey.appSwitch => 'APP_SWITCH',
        DeviceKey.volumeUp => 'VOLUME_UP',
        DeviceKey.volumeDown => 'VOLUME_DOWN',
        DeviceKey.power => 'POWER',
      };

  Set<DeviceCapability> _discoverCapabilities(
      List<Map<String, Object?>> tools) {
    if (tools.isEmpty) return <DeviceCapability>{};
    final out = <DeviceCapability>{};
    bool has(List<String> k) => _findTool(k) != null;
    if (has(const <String>['install'])) {
      out.add(DeviceCapability.install);
    }
    if (has(const <String>['uninstall'])) {
      out.add(DeviceCapability.uninstall);
    }
    if (has(const <String>['launch']) || has(const <String>['open'])) {
      out.add(DeviceCapability.launch);
    }
    if (has(const <String>['terminate']) || has(const <String>['stop'])) {
      out.add(DeviceCapability.terminate);
    }
    if (has(const <String>['press'])) {
      out.add(DeviceCapability.pressKey);
    }
    if (has(const <String>['tap']) || has(const <String>['click'])) {
      out.add(DeviceCapability.tapNative);
    }
    if (has(const <String>['crash'])) {
      out.add(DeviceCapability.crashList);
    }
    return out;
  }

  /// 设备参数兼容多种命名（deviceId / device_id / serial / udid）。
  Map<String, Object?> _deviceArg(String deviceId) => <String, Object?>{
        'deviceId': deviceId,
        'device_id': deviceId,
        'serial': deviceId,
        'udid': deviceId,
      };

  /// MCP tools/call 的文本结果。
  String _resultText(Map<String, Object?> r) {
    final content = r['content'];
    if (content is List) {
      final texts = <String>[];
      for (final c in content) {
        if (c is Map && c['type'] == 'text') texts.add('${c['text']}');
      }
      if (texts.isNotEmpty) return texts.join('\n');
    }
    final sc = r['structuredContent'];
    if (sc is Map) return jsonEncode(sc);
    return '';
  }

  /// 从响应体提取 JSON-RPC 消息：兼容纯 JSON 与 SSE（`data:` 多行）。
  ///
  /// Streamable HTTP 允许两种响应体，且不同适配器版本可能随时切换，
  /// 因此先按整体 JSON 解析，失败再按 SSE 事件块解析，取最后一个带
  /// `result`/`error` 的消息。
  Map<String, Object?>? _extractJson(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;
    final direct = _asJsonMessage(trimmed);
    if (direct != null) return direct;
    Map<String, Object?>? last;
    for (final chunk in body.split(RegExp(r'\r?\n\r?\n'))) {
      final data = StringBuffer();
      for (final line in chunk.split('\n')) {
        final t = line.trimRight();
        if (!t.startsWith('data:')) continue;
        data.write(t.substring(5).trimLeft());
      }
      if (data.isEmpty) continue;
      final msg = _asJsonMessage(data.toString());
      if (msg == null) continue;
      if (msg.containsKey('result') || msg.containsKey('error')) last = msg;
    }
    return last;
  }

  /// 解析单条 JSON（对象或 JSON-RPC 批次，批次里优先取带响应的那条）。
  Map<String, Object?>? _asJsonMessage(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map) return v.cast<String, Object?>();
      if (v is List) {
        for (final e in v) {
          if (e is Map && (e.containsKey('result') || e.containsKey('error'))) {
            return e.cast<String, Object?>();
          }
        }
      }
    } catch (_) {
      // 不是 JSON，交给调用方继续尝试。
    }
    return null;
  }

  /// 解析设备列表：能解析成 JSON 就以 JSON 为准，否则退回逐行解析。
  ///
  /// 注意：适配器可能返回 `{"devices":[],"hint":"..."}`——空列表要如实
  /// 返回空，不能把提示文本误当成一台设备。
  List<DeviceInfo> _parseDevices(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return <DeviceInfo>[];
    final out = <DeviceInfo>[];
    var isJson = false;
    try {
      final decoded = jsonDecode(trimmed);
      isJson = true;
      final list = decoded is List
          ? decoded
          : (decoded is Map ? (decoded['devices'] ?? decoded['result']) : null);
      if (list is List) {
        for (final d in list) {
          if (d is! Map) continue;
          final id =
              (d['id'] ?? d['deviceId'] ?? d['udid'] ?? d['serial'] ?? '')
                  .toString();
          if (id.isEmpty) continue;
          out.add(DeviceInfo(
            backend: backend,
            id: id,
            name: (d['name'] ?? d['model'] ?? id).toString(),
            platform: (d['platform'] ?? d['os'] ?? 'unknown')
                .toString()
                .toLowerCase(),
            state: (d['state'] ?? d['status'] ?? 'device')
                .toString()
                .toLowerCase(),
          ));
        }
      }
    } catch (_) {
      // 不是 JSON，走逐行解析。
    }
    if (isJson) return out;
    for (final line in trimmed.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final parts = t.split(RegExp(r'\s+[·|\-]\s+'));
      final id = parts.first.trim();
      if (id.isEmpty) continue;
      out.add(DeviceInfo(
        backend: backend,
        id: id,
        name: parts.length > 1 ? parts[1].trim() : id,
        platform: 'unknown',
        state: 'device',
      ));
    }
    return out;
  }
}
