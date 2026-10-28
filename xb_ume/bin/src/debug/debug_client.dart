// 断点调试核心：把 VM service 的 Debug 流包成「断点 / 暂停 / 步进 / 栈 / 变量」。
//
// 定位边界：这里只做 IDE 调器里「控制面板」那一半——不读源码、不做语法
// 高亮，断点只认「脚本 URI + 行号」。脚本 URI 的两种写法都会试：编译器对
// 工作区内代码通常给 file://，对依赖包 / 测试给 package:。
//
// 条件断点：vm_service 14.x 的 addBreakpoint* 没有 condition 参数，Breakpoint
// 里也不存条件，所以按 Dart-Code 的做法在客户端判定——命中后在该帧 evaluate
// 条件表达式，结果为 false 立即自动 resume，并回一个 conditionMissed 事件。
//
// 日志断点（logpoint）：与条件断点同一套机制，命中后在该帧 evaluate 日志
// 表达式，把结果拼成一行输出（logpointHit 事件）再自动 resume，不打断程序。
// 表达式求值失败只输出原因、仍然继续——日志是观察，不该改变运行行为。
//
// 热重启：会换 isolate，VM 侧断点随之清空；调用方 resetIsolate() 后用
// reapplyBreakpoints() 按本客户端登记过的清单重新下发。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../scenario/vm_client.dart' show normalizeVmUri, vmErrorText;

/// 调试失败（连接 / 协议 / 参数），message 已转成可直接展示的说明。
class DebugException implements Exception {
  DebugException(this.message, {this.method});

  final String message;

  /// 出错的 VM service 方法名（有则拼进 toString）。
  final String? method;

  @override
  String toString() => method == null ? message : '$method: $message';
}

/// 步进方向；wire 是 VM service `resume` 的 step 取值。
enum DebugStep { into, over, out }

extension DebugStepWire on DebugStep {
  String get wire => switch (this) {
        DebugStep.into => 'Into',
        DebugStep.over => 'Over',
        DebugStep.out => 'Out',
      };

  String get label => switch (this) {
        DebugStep.into => '单步进入',
        DebugStep.over => '单步跳过',
        DebugStep.out => '单步跳出',
      };
}

/// 一个断点（可能尚未解析到真实代码位置）。
class DebugBreakpoint {
  const DebugBreakpoint({
    required this.id,
    this.scriptUri,
    this.line,
    this.column,
    this.resolved = false,
    this.enabled = true,
    this.condition,
    this.logMessage,
  });

  /// VM 断点 id（`breakpoints/3`），删除 / 启停都靠它。
  final String id;

  /// 解析后的脚本 URI；未解析时是设置时传入的候选 URI。
  final String? scriptUri;
  final int? line;
  final int? column;

  /// VM 是否已把断点落到具体代码位置。
  final bool resolved;
  final bool enabled;

  /// 客户端条件（VM 不存），null 表示无条件。
  final String? condition;

  /// 客户端日志表达式（VM 不存），null 表示普通断点；非空时命中不暂停。
  final String? logMessage;

  DebugBreakpoint copyWith({
    String? scriptUri,
    int? line,
    int? column,
    bool? resolved,
    bool? enabled,
    String? condition,
    String? logMessage,
  }) =>
      DebugBreakpoint(
        id: id,
        scriptUri: scriptUri ?? this.scriptUri,
        line: line ?? this.line,
        column: column ?? this.column,
        resolved: resolved ?? this.resolved,
        enabled: enabled ?? this.enabled,
        condition: condition ?? this.condition,
        logMessage: logMessage ?? this.logMessage,
      );

  @override
  String toString() =>
      'DebugBreakpoint($id, ${scriptUri ?? '?'}:$line, resolved: $resolved'
      '${condition == null ? '' : ', if: $condition'}'
      '${logMessage == null ? '' : ', log: $logMessage'})';
}

/// 栈帧里的一个变量（只取一层，够「暂停时看一眼」用）。
class DebugVar {
  const DebugVar({
    required this.name,
    required this.value,
    this.type,
    this.kind,
    this.objectId,
  });

  final String name;

  /// 可读值：valueAsString，对象退化成 `Instance of X`。
  final String value;

  /// classRef.name。
  final String? type;

  /// InstanceKind（String / Null / PlainInstance…）。
  final String? kind;

  /// 对象 id；后续要展开一层时用。
  final String? objectId;
}

/// 一个栈帧；index 可直接用于 evaluateInFrame（0 = 栈顶）。
class DebugFrame {
  const DebugFrame({
    required this.index,
    required this.function,
    this.scriptUri,
    this.line,
    this.column,
    this.vars = const <DebugVar>[],
  });

  final int index;
  final String function;
  final String? scriptUri;
  final int? line;
  final int? column;
  final List<DebugVar> vars;

  String get label => '$function  ${scriptUri ?? '?'}:${line ?? '?'}';
}

/// 一次暂停的现场。
class DebugPause {
  const DebugPause({
    required this.reason,
    this.topFrame,
    this.breakpointIds = const <String>[],
    this.exception,
  });

  /// PauseBreakpoint / PauseInterrupted / PauseException。
  final String reason;
  final DebugFrame? topFrame;

  /// 停在同一位置的所有断点 id（单步暂停时为空）。
  final List<String> breakpointIds;

  /// PauseException 的可读异常值。
  final String? exception;

  bool get fromBreakpoint => reason == 'PauseBreakpoint';
  bool get fromException => reason == 'PauseException';
  String? get scriptUri => topFrame?.scriptUri;
  int? get line => topFrame?.line;
}

enum DebugEventKind {
  pause,
  resume,
  exit,
  start,
  breakpointAdded,
  breakpointResolved,
  breakpointRemoved,
  breakpointUpdated,
  inspect,

  /// 本地合成：条件断点条件为 false，已自动继续。
  conditionMissed,

  /// 本地合成：日志断点命中，已把求值结果写进 message 并自动继续。
  logpointHit,

  /// 本地合成：连接断开。
  disconnected,
  unknown,
}

/// Debug 流事件（解析后）。
class DebugEvent {
  const DebugEvent({
    required this.kind,
    this.isolateId,
    this.pause,
    this.breakpoint,
    this.condition,
    this.message,
  });

  final DebugEventKind kind;
  final String? isolateId;
  final DebugPause? pause;
  final DebugBreakpoint? breakpoint;

  /// conditionMissed 时命中的条件表达式。
  final String? condition;

  /// 额外说明（断开原因、异常文案等）。
  final String? message;

  bool get isPause => kind == DebugEventKind.pause;

  DebugEvent copyWith({DebugPause? pause, String? message}) => DebugEvent(
        kind: kind,
        isolateId: isolateId,
        pause: pause ?? this.pause,
        breakpoint: breakpoint,
        condition: condition,
        message: message ?? this.message,
      );
}

/// 断点脚本 URI 候选：编译器对工作区内代码通常用 file://，对依赖包 / 测试
/// 用 package:，两个都试；路径先做符号链接归一（macOS 的 /var → /private/var）。
List<String> breakpointScriptUriCandidates(
  String filePath, {
  String? projectRoot,
  String? packageName,
}) {
  final out = <String>[];
  void add(String uri) {
    if (uri.isNotEmpty && !out.contains(uri)) out.add(uri);
  }

  if (filePath.trim().isEmpty) return out;
  final abs = File(filePath).absolute.path;
  add(Uri.file(abs, windows: Platform.isWindows).toString());
  final real = _realPath(abs);
  if (real != null && real != abs) {
    add(Uri.file(real, windows: Platform.isWindows).toString());
  }

  final pkg = packageName?.trim();
  final rootRaw = projectRoot?.trim();
  if (pkg == null || pkg.isEmpty || rootRaw == null || rootRaw.isEmpty) {
    return out;
  }
  final rootAbs = Directory(rootRaw).absolute.path;
  final roots = <String>[
    _stripTrailingSlash(_slash(rootAbs)),
    if (_realPath(rootAbs) case final r?) _stripTrailingSlash(_slash(r)),
  ];
  for (final path in <String>[abs, if (real != null) real]) {
    final s = _slash(path);
    for (final root in roots) {
      final prefix = Platform.isWindows ? root.toLowerCase() : root;
      final target = Platform.isWindows ? s.toLowerCase() : s;
      if (!target.startsWith('$prefix/')) continue;
      final rel = s.substring(root.length + 1);
      if (!rel.startsWith('lib/')) continue;
      add('package:$pkg/${rel.substring(4)}');
    }
  }
  return out;
}

/// 反向映射：脚本 URI → 本机路径（只认 file: 与「本项目」的 package:）。
String? debugScriptUriToPath(
  String scriptUri, {
  String? projectRoot,
  String? packageName,
}) {
  final uri = scriptUri.trim();
  if (uri.startsWith('file:')) {
    try {
      final path = Uri.parse(uri).toFilePath(windows: Platform.isWindows);
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }
  if (!uri.startsWith('package:')) return null;
  final rootRaw = projectRoot?.trim();
  if (rootRaw == null || rootRaw.isEmpty) return null;
  final rest = uri.substring('package:'.length);
  final slash = rest.indexOf('/');
  if (slash <= 0 || slash == rest.length - 1) return null;
  final name = rest.substring(0, slash);
  final pkg = packageName?.trim();
  if (pkg != null && pkg.isNotEmpty && name != pkg) return null;
  final root = _stripTrailingSlash(_slash(Directory(rootRaw).absolute.path));
  return '$root/lib/${rest.substring(slash + 1)}';
}

/// getVM 的 isolates 里挑主 isolate（name == 'main'），没有就取第一个。
String? pickMainIsolate(Object? isolates) {
  final list = isolates is List ? isolates : const <Object?>[];
  String? first;
  for (final raw in list) {
    final m = _asMap(raw);
    final id = _str(m?['id']);
    if (id == null) continue;
    first ??= id;
    if (_str(m?['name']) == 'main') return id;
  }
  return first;
}

/// 解析 VM 的 Breakpoint。
DebugBreakpoint? parseBreakpoint(Object? raw, {String? condition}) {
  final m = _asMap(raw);
  final id = _str(m?['id']);
  if (m == null || id == null) return null;
  final loc = _asMap(m['location']);
  final scriptUri = _str(_asMap(loc?['script'])?['uri']) ?? _str(loc?['scriptUri']);
  return DebugBreakpoint(
    id: id,
    scriptUri: scriptUri,
    line: _int(loc?['line']),
    column: _int(loc?['column']),
    resolved: m['resolved'] == true,
    enabled: m['enabled'] != false,
    condition: condition,
  );
}

/// 解析 VM 的 Frame（含 vars）。
DebugFrame? parseFrame(Object? raw) {
  final m = _asMap(raw);
  if (m == null) return null;
  final loc = _asMap(m['location']);
  final fn = _asMap(m['function']);
  final name = _str(fn?['name']) ??
      _str(_asMap(fn?['owner'])?['name']) ??
      _str(fn?['kind']) ??
      '<anonymous>';
  final vars = <DebugVar>[];
  final list = m['vars'];
  if (list is List) {
    for (final item in list) {
      final bv = _asMap(item);
      final varName = _str(bv?['name']);
      if (bv == null || varName == null) continue;
      final value = _asMap(bv['value']);
      vars.add(DebugVar(
        name: varName,
        value: describeInstanceRef(bv['value']),
        // 真机返回的类名在 class.name（classRef 是旧写法），两种都认。
        type: _className(value),
        kind: _str(value?['kind']),
        objectId: _str(value?['id']),
      ));
    }
  }
  return DebugFrame(
    index: _int(m['index']) ?? 0,
    function: name,
    scriptUri: _str(_asMap(loc?['script'])?['uri']) ?? _str(loc?['scriptUri']),
    line: _int(loc?['line']),
    column: _int(loc?['column']),
    vars: vars,
  );
}

/// 解析 getStack 的结果（只取同步栈 frames）。
List<DebugFrame> parseStack(Object? raw) {
  final list = _asMap(raw)?['frames'];
  if (list is! List) return const <DebugFrame>[];
  return <DebugFrame>[
    for (final item in list)
      if (parseFrame(item) case final f?) f,
  ];
}

/// 解析 Debug 流事件（传入 streamNotify.params.event）。
DebugEvent? parseDebugEvent(Object? raw) {
  final m = _asMap(raw);
  if (m == null) return null;
  final kindStr = _str(m['kind']) ?? '';
  final isolateId = _str(m['isolateId']);

  DebugPause? pause;
  if (kindStr == 'PauseBreakpoint' ||
      kindStr == 'PauseInterrupted' ||
      kindStr == 'PauseException') {
    final ids = <String>[];
    final list = m['pauseBreakpoints'];
    if (list is List) {
      for (final item in list) {
        final id = parseBreakpoint(item)?.id;
        if (id != null) ids.add(id);
      }
    }
    pause = DebugPause(
      reason: kindStr,
      topFrame: parseFrame(m['topFrame']),
      breakpointIds: ids,
      exception: kindStr == 'PauseException'
          ? describeInstanceRef(m['exception'])
          : null,
    );
  }

  final kind = switch (kindStr) {
    'PauseBreakpoint' || 'PauseInterrupted' || 'PauseException' =>
      DebugEventKind.pause,
    'Resume' => DebugEventKind.resume,
    'PauseExit' => DebugEventKind.exit,
    'PauseStart' => DebugEventKind.start,
    'BreakpointAdded' => DebugEventKind.breakpointAdded,
    'BreakpointResolved' => DebugEventKind.breakpointResolved,
    'BreakpointRemoved' => DebugEventKind.breakpointRemoved,
    'BreakpointUpdated' => DebugEventKind.breakpointUpdated,
    'Inspect' => DebugEventKind.inspect,
    _ => DebugEventKind.unknown,
  };

  return DebugEvent(
    kind: kind,
    isolateId: isolateId,
    pause: pause,
    breakpoint: parseBreakpoint(m['breakpoint']),
    message: pause?.exception,
  );
}

/// InstanceRef → 可读字符串；evaluate 的 Error 也走这里。
String describeInstanceRef(Object? raw) {
  if (raw == null) return '';
  if (raw is! Map) return raw.toString();
  // vm_service 14 的错误对象是 ErrorRef（type == '@Error'），老版本/包装层
  // 可能直接给 'Error'，两种都认，否则会把 message 丢掉只剩一个 '@Error'。
  final type = _str(raw['type']);
  if (type == 'Error' || type == '@Error') {
    final msg = _str(raw['message']);
    if (msg != null) return msg;
  }
  if (type == 'Sentinel') {
    return '<${_str(raw['kind']) ?? 'sentinel'}>';
  }
  final value = raw['valueAsString'];
  if (value is String && value.isNotEmpty) return value;
  switch (_str(raw['kind'])) {
    case 'Null':
      return 'null';
    case 'String':
      return '""';
    case 'Bool':
      return _str(raw['valueAsString']) ?? '<bool>';
  }
  final cls = _className(_asMap(raw));
  if (cls != null) return 'Instance of $cls';
  return type ?? '';
}

/// 一个 VM service Debug 客户端（单 WebSocket，事件广播）。
class DebugClient {
  DebugClient(
    String wsUrl, {
    String? projectRoot,
    String? packageName,
  })  : wsUrl = normalizeVmUri(wsUrl),
        projectRoot = _blankToNull(projectRoot),
        packageName = _blankToNull(packageName);

  final String wsUrl;

  /// 项目根与本包名：用于生成 / 反解 `package:` 脚本 URI。
  final String? projectRoot;
  final String? packageName;

  final StreamController<DebugEvent> _events =
      StreamController<DebugEvent>.broadcast();
  final Map<String, _Pending> _pending = <String, _Pending>{};
  final Map<String, String> _conditions = <String, String>{};
  final Map<String, String> _logMessages = <String, String>{};
  final Map<String, DebugBreakpoint> _breakpoints = <String, DebugBreakpoint>{};
  final List<_OwnedBreakpoint> _owned = <_OwnedBreakpoint>[];

  WebSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  int _seq = 0;
  String? _isolateId;
  DebugPause? _pause;
  bool _listening = false;
  bool _closed = false;

  /// Debug 流事件（暂停 / 继续 / 断点增删改 / 条件未命中等）。
  Stream<DebugEvent> get events => _events.stream;

  /// 当前是否停在某个暂停点。
  bool get paused => _pause != null;
  DebugPause? get currentPause => _pause;

  /// 已解析到的 isolate id（热重启后会换成新的）。
  String? get knownIsolateId => _isolateId;

  bool get connected => _socket != null;

  /// 本客户端设置过、仍有效的断点（不含 IDE 自己加的）。
  List<DebugBreakpoint> get breakpoints => _breakpoints.values
      .where((b) => _owned.any((o) => o.id == b.id))
      .toList(growable: false);

  /// 建立连接并订阅 Debug 流（可重复调用）。
  Future<void> connect() async {
    await _ensureConnected();
    if (_listening) return;
    try {
      await rpc('streamListen', <String, Object?>{'streamId': 'Debug'});
    } catch (e) {
      // 别的客户端（IDE / 上一次连接）已订阅时 VM 报 103，视为成功。
      final text = e.toString().toLowerCase();
      if (!text.contains('already subscribed')) rethrow;
    }
    _listening = true;
  }

  /// 通用 JSON-RPC；错误统一转 DebugException。
  Future<Map<String, Object?>> rpc(
    String method, [
    Map<String, Object?>? params,
  ]) async {
    await _ensureConnected();
    final id = 'd${_seq++}';
    final pending = _Pending(method, Completer<Map<String, Object?>>());
    _pending[id] = pending;
    _socket!.add(jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }));
    return pending.completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw DebugException('VM service 响应超时（会话可能已挂起或断开）', method: method);
      },
    );
  }

  /// 当前 isolate id；refresh 用于热重启后强制重新解析。
  Future<String> isolateId({bool refresh = false}) async {
    if (!refresh && _isolateId != null) return _isolateId!;
    final vm = await rpc('getVM');
    final id = pickMainIsolate(vm['isolates']);
    if (id == null) {
      throw DebugException('未找到可调试的 isolate（应用可能已退出）');
    }
    _isolateId = id;
    return id;
  }

  /// 热重启后清掉旧 isolate / 断点缓存（保留 _owned 以便重新下发）。
  void resetIsolate() {
    _isolateId = null;
    _pause = null;
    _breakpoints.clear();
    _conditions.clear();
    _logMessages.clear();
  }

  /// 脚本 URI → 本机路径（GUI 展示用）。
  String? localPathOf(String scriptUri) => debugScriptUriToPath(
        scriptUri,
        projectRoot: projectRoot,
        packageName: packageName,
      );

  /// 当前 isolate 已加载的脚本 URI（用于挑正确的 file:/package: 候选）。
  Future<Set<String>> loadedScriptUris() async {
    final r = await rpc('getScripts', <String, Object?>{
      'isolateId': await isolateId(),
    });
    final out = <String>{};
    final list = r['scripts'];
    if (list is List) {
      for (final raw in list) {
        final uri = _str(_asMap(raw)?['uri']);
        if (uri != null) out.add(uri);
      }
    }
    return out;
  }

  /// 在 [path] 的 [line]（1 基）设断点。
  ///
  /// 候选脚本 URI 里优先用「已加载」的那个，避免给猜出来的 URI 建一个永远
  /// 不会解析的断点；都未加载时按候选顺序试。
  Future<DebugBreakpoint> addBreakpoint({
    required String path,
    required int line,
    int? column,
    String? condition,
    String? logMessage,
  }) async {
    if (path.trim().isEmpty) throw DebugException('断点路径为空');
    if (line < 1) throw DebugException('断点行号从 1 开始：$line');
    final iso = await isolateId();
    final candidates = breakpointScriptUriCandidates(
      path,
      projectRoot: projectRoot,
      packageName: packageName,
    );
    if (candidates.isEmpty) throw DebugException('无法把路径转成脚本 URI：$path');

    var ordered = candidates;
    try {
      final loaded = await loadedScriptUris();
      if (loaded.isNotEmpty) {
        final hit = candidates.where(loaded.contains).toList();
        if (hit.isNotEmpty) {
          ordered = <String>[
            ...hit,
            ...candidates.where((c) => !hit.contains(c)),
          ];
        }
      }
    } catch (_) {
      // getScripts 失败不影响设断点，按原候选顺序试。
    }

    Object? lastError;
    for (final uri in ordered) {
      try {
        final bp = await _addAtUri(iso, uri, line, column);
        final cond = _blankToNull(condition);
        if (cond != null) _conditions[bp.id] = cond;
        final log = _blankToNull(logMessage);
        if (log != null) _logMessages[bp.id] = log;
        final merged = bp.copyWith(condition: cond, logMessage: log);
        _breakpoints[bp.id] = merged;
        _owned
          ..removeWhere((o) => o.id == bp.id)
          ..add(_OwnedBreakpoint(
            id: bp.id,
            path: path,
            line: bp.line ?? line,
            column: bp.column ?? column,
            condition: cond,
            logMessage: log,
          ));
        return merged;
      } catch (e) {
        lastError = e;
      }
    }
    throw DebugException('设置断点失败（$path:$line）：${lastError ?? '未知错误'}');
  }

  Future<DebugBreakpoint> _addAtUri(
    String iso,
    String uri,
    int line,
    int? column,
  ) async {
    final params = <String, Object?>{
      'isolateId': iso,
      'scriptUri': uri,
      'line': line,
      if (column != null) 'column': column,
    };
    Map<String, Object?> raw;
    try {
      raw = await rpc('addBreakpointWithScriptUri', params);
    } catch (_) {
      // Dart < 2.17 没有 add*；set* 会阻塞到解析完成，仅作兜底。
      raw = await rpc('setBreakpointWithScriptUri', params);
    }
    final bp = parseBreakpoint(raw);
    if (bp == null) throw DebugException('VM 返回的断点无法解析：$raw');
    return bp;
  }

  /// 删除一个断点。
  Future<void> removeBreakpoint(String breakpointId) async {
    await rpc('removeBreakpoint', <String, Object?>{
      'isolateId': await isolateId(),
      'breakpointId': breakpointId,
    });
    _breakpoints.remove(breakpointId);
    _conditions.remove(breakpointId);
    _logMessages.remove(breakpointId);
    _owned.removeWhere((o) => o.id == breakpointId);
  }

  /// 启停断点（VM 的 setBreakpointState，不删断点）。
  Future<void> setBreakpointEnabled(String breakpointId, bool enabled) async {
    final raw = await rpc('setBreakpointState', <String, Object?>{
      'isolateId': await isolateId(),
      'breakpointId': breakpointId,
      'enable': enabled,
    });
    final bp = parseBreakpoint(raw);
    if (bp != null) {
      _breakpoints[bp.id] = bp.copyWith(
        condition: _conditions[bp.id],
        logMessage: _logMessages[bp.id],
      );
    }
  }

  /// 以 VM 为准拉一遍断点（含 IDE 加的）。
  Future<List<DebugBreakpoint>> listBreakpoints() async {
    final raw = await rpc('getIsolate', <String, Object?>{
      'isolateId': await isolateId(),
    });
    final out = <DebugBreakpoint>[];
    final list = raw['breakpoints'];
    if (list is List) {
      for (final item in list) {
        final bp = parseBreakpoint(item);
        if (bp == null) continue;
        final merged = bp.copyWith(condition: _conditions[bp.id]);
        _breakpoints[merged.id] = merged;
        out.add(merged);
      }
    }
    return out;
  }

  /// 热重启后按本客户端登记过的清单重新下发断点。
  ///
  /// [from] 是重启**前**留的快照：重启会让旧 isolate 的断点全部消失，VM
  /// 还会逐个发 BreakpointRemoved，把 [_owned] 一起清空。不带快照时只能
  /// 用当前清单（适合非重启场景）。
  Future<List<DebugBreakpoint>> reapplyBreakpoints(
      {BreakpointSnapshot? from}) async {
    final previous = from?._items ?? List<_OwnedBreakpoint>.from(_owned);
    _breakpoints.clear();
    _conditions.clear();
    _logMessages.clear();
    _owned.clear();
    final out = <DebugBreakpoint>[];
    for (final old in previous) {
      try {
        out.add(await addBreakpoint(
          path: old.path,
          line: old.line,
          column: old.column,
          condition: old.condition,
          logMessage: old.logMessage,
        ));
      } catch (_) {
        // 单个断点重下失败（行已删、文件改过）不影响其它断点。
      }
    }
    return out;
  }

  /// 留一份「本客户端登记过的断点」快照（热重启动手前调用）。
  BreakpointSnapshot snapshotBreakpoints() =>
      BreakpointSnapshot._(List<_OwnedBreakpoint>.from(_owned));

  /// 本客户端登记过的断点数（诊断/测试用）。
  int get ownedBreakpointCount => _owned.length;

  /// 暂停（等同于工具栏的暂停按钮）。
  Future<void> pause() async {
    await rpc('pause', <String, Object?>{'isolateId': await isolateId()});
  }

  /// 继续 / 单步。
  Future<void> resume({DebugStep? step}) async {
    await rpc('resume', <String, Object?>{
      'isolateId': await isolateId(),
      if (step != null) 'step': step.wire,
    });
    _pause = null;
  }

  /// 当前调用栈（含每个栈帧的局部变量）。
  Future<List<DebugFrame>> stack({int limit = 32}) async {
    final raw = await rpc('getStack', <String, Object?>{
      'isolateId': await isolateId(),
      'limit': limit,
    });
    return parseStack(raw);
  }

  /// 在当前调用栈的第 [frameIndex] 帧求值（0 = 栈顶）。
  ///
  /// VM 只认帧序号：Pause 事件里的 topFrame 没有 id，也不能当 evaluate 的
  /// targetId（会报 invalid 'targetId'），所以统一走 evaluateInFrame。
  Future<String> evaluateInFrame(int frameIndex, String expression) async {
    final raw = await rpc('evaluateInFrame', <String, Object?>{
      'isolateId': await isolateId(),
      'frameIndex': frameIndex,
      'expression': expression,
      // 判定条件时别再被断点打断，否则会自己停在自己身上。
      'disableBreakpoints': true,
    });
    if (raw['type'] == 'Error' ||
        raw['type'] == '@Error' ||
        raw['type'] == 'Sentinel') {
      throw DebugException(describeInstanceRef(raw));
    }
    return describeInstanceRef(raw);
  }

  /// 断开连接并结束事件流。
  ///
  /// 先关 socket 再取消订阅：反过来的话 dart:io 的 WebSocket 不会真正
  /// 释放底层 FD（lsof 里留着 CLOSED 的连接），其事件端口会让独立脚本
  /// 退不出去、长跑的 GUI 每断一次会话就漏一个连接。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pause = null;
    for (final p in _pending.values) {
      p.completer.completeError(DebugException('调试连接已关闭', method: p.method));
    }
    _pending.clear();
    final socket = _socket;
    final sub = _sub;
    _socket = null;
    _sub = null;
    _listening = false;
    try {
      // 对端可能已经死了：关握手不能无限等。
      await socket?.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // 关不掉也继续取消订阅，尽量把 FD 交给 GC。
    }
    try {
      await sub?.cancel().timeout(const Duration(seconds: 2));
    } catch (_) {}
    if (!_events.isClosed) await _events.close();
  }

  // ---------------------------------------------------------------- 内部

  Future<void> _ensureConnected() async {
    if (_socket != null) return;
    if (_closed) throw DebugException('调试连接已关闭');
    final socket = await WebSocket.connect(wsUrl).timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw DebugException('连接 VM service 超时：$wsUrl'),
    );
    _socket = socket;
    _sub = socket.listen(
      _onMessage,
      onDone: () => _onClosed('连接已关闭'),
      onError: (Object e) => _onClosed('连接异常：$e'),
    );
  }

  void _onMessage(dynamic message) {
    if (message is! String) return;
    Object? parsed;
    try {
      parsed = jsonDecode(message);
    } catch (_) {
      return;
    }
    final m = _asMap(parsed);
    if (m == null) return;

    final id = _str(m['id']);
    if (id != null) {
      final pending = _pending.remove(id);
      if (pending == null) return;
      if (m['error'] != null) {
        pending.completer.completeError(
          DebugException(vmErrorText(m['error']), method: pending.method),
        );
      } else {
        pending.completer.complete(_asMap(m['result']) ?? <String, Object?>{});
      }
      return;
    }

    if (m['method'] != 'streamNotify') return;
    final params = _asMap(m['params']);
    if (_str(params?['streamId']) != 'Debug') return;
    final event = _asMap(params?['event']);
    if (event == null) return;
    unawaited(_handleEvent(event));
  }

  Future<void> _handleEvent(Map<String, Object?> raw) async {
    final event = parseDebugEvent(raw);
    if (event == null) return;
    final iso = event.isolateId;
    if (iso != null && iso.isNotEmpty) _isolateId = iso;

    switch (event.kind) {
      case DebugEventKind.pause:
        final pause = await _hydratePause(event.pause!);
        _pause = pause;
        final ev = event.copyWith(pause: pause);
        final conditions = <String>[];
        for (final id in pause.breakpointIds) {
          final c = _blankToNull(_conditions[id]);
          if (c != null) conditions.add(c);
        }
        final condition = conditions.join(' || ');
        if (condition.isNotEmpty && pause.topFrame != null) {
          // 条件为 false 就自己继续；求值失败则保持暂停并把原因带回去，
          // 不能静默吞掉断点。
          final (hit, error) =
              await _evalCondition(condition, pause.topFrame!.index);
          if (error != null) {
            _emit(ev.copyWith(message: '条件求值失败：$error（保持暂停）'));
            return;
          }
          if (!hit) {
            try {
              await resume();
              _emit(DebugEvent(
                kind: DebugEventKind.conditionMissed,
                isolateId: iso,
                pause: pause,
                condition: condition,
              ));
            } catch (_) {
              _emit(ev);
            }
            return;
          }
        }
        // 日志断点：命中后求值打到输出区再自动继续，不停下来（求值失败
        // 也只输原因，不把日志断点变成普通断点）。
        final logs = <String>[];
        for (final id in pause.breakpointIds) {
          final l = _blankToNull(_logMessages[id]);
          if (l != null) logs.add(l);
        }
        if (logs.isNotEmpty && pause.topFrame != null) {
          final text = await _evalLogs(logs, pause);
          try {
            await resume();
            _emit(DebugEvent(
              kind: DebugEventKind.logpointHit,
              isolateId: iso,
              pause: pause,
              message: text,
            ));
          } catch (_) {
            _emit(ev);
          }
          return;
        }
        _emit(ev);
        return;
      case DebugEventKind.resume:
      case DebugEventKind.exit:
      case DebugEventKind.start:
        _pause = null;
        _emit(event);
        return;
      case DebugEventKind.breakpointAdded:
      case DebugEventKind.breakpointResolved:
      case DebugEventKind.breakpointUpdated:
        final bp = event.breakpoint;
        if (bp != null) {
          _breakpoints[bp.id] = bp.copyWith(
            condition: _conditions[bp.id],
            logMessage: _logMessages[bp.id],
          );
        }
        _emit(event);
        return;
      case DebugEventKind.breakpointRemoved:
        final bp = event.breakpoint;
        if (bp != null) {
          _breakpoints.remove(bp.id);
          _conditions.remove(bp.id);
          _logMessages.remove(bp.id);
          _owned.removeWhere((o) => o.id == bp.id);
        }
        _emit(event);
        return;
      default:
        _emit(event);
    }
  }

  /// Pause 事件里的 topFrame 只带位置、不带 vars（也没有 id）；补一次
  /// getStack，让 GUI 变量面板和条件判定都拿到完整帧。
  Future<DebugPause> _hydratePause(DebugPause pause) async {
    final frame = pause.topFrame;
    if (frame != null && frame.vars.isNotEmpty) return pause;
    try {
      final frames = await stack(limit: 1);
      if (frames.isNotEmpty) {
        return DebugPause(
          reason: pause.reason,
          topFrame: frames.first,
          breakpointIds: pause.breakpointIds,
          exception: pause.exception,
        );
      }
    } catch (_) {
      // 补帧失败就保留原帧：位置仍可展示，只是不能求值。
    }
    return pause;
  }

  /// 返回 (是否命中, 错误说明)。错误非空时调用方应保持暂停。
  Future<(bool, String?)> _evalCondition(
    String expression,
    int frameIndex,
  ) async {
    try {
      final raw = await rpc('evaluateInFrame', <String, Object?>{
        'isolateId': await isolateId(),
        'frameIndex': frameIndex,
        'expression': expression,
        'disableBreakpoints': true,
      });
      final kind = _str(raw['kind']);
      final type = _str(raw['type']);
      // 编译 / 运行时错误（ErrorRef）不能当条件值用，带出具体原因。
      if (type == 'Error' || type == '@Error' || type == 'Sentinel') {
        return (true, describeInstanceRef(raw));
      }
      if (kind == 'Bool') return (_str(raw['valueAsString']) == 'true', null);
      if (kind == 'Null') return (false, null);
      return (true, '条件不是 bool：${describeInstanceRef(raw)}');
    } catch (e) {
      return (true, '$e');
    }
  }

  /// 日志断点求值：逐条拼成「[logpoint] 文件:行  表达式 => 值」。
  /// 单条失败只把原因写进该行，不影响其它表达式，也不影响继续运行。
  Future<String> _evalLogs(List<String> expressions, DebugPause pause) async {
    final frame = pause.topFrame;
    final frameIndex = frame?.index ?? 0;
    final loc = _logLocation(frame);
    final lines = <String>[];
    for (final expr in expressions) {
      String value;
      try {
        value = await _evalLogExpr(frameIndex, expr);
      } catch (e) {
        value = '求值失败：$e';
      }
      lines.add('[logpoint] $loc  $expr => $value');
    }
    return lines.join('\n');
  }

  /// 先按表达式求值；不合法时按字符串插值再试（`i=$i` 这类裸模板）。
  Future<String> _evalLogExpr(int frameIndex, String expr) async {
    try {
      return await evaluateInFrame(frameIndex, expr);
    } catch (first) {
      final body = expr
          .replaceAll(r'\', r'\\')
          .replaceAll("'", r"\'")
          .replaceAll('\n', r'\n');
      try {
        return await evaluateInFrame(frameIndex, "'$body'");
      } catch (second) {
        throw DebugException('$second（表达式求值也失败：$first）');
      }
    }
  }

  String _logLocation(DebugFrame? frame) {
    final uri = frame?.scriptUri;
    final path = uri == null ? null : localPathOf(uri);
    final name =
        path == null ? (uri ?? '?') : _slash(path).split('/').last;
    final line = frame?.line;
    return '$name${line == null ? '' : ':$line'}';
  }

  void _emit(DebugEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _onClosed(String reason) {
    _socket = null;
    _listening = false;
    _pause = null;
    for (final p in _pending.values) {
      p.completer.completeError(DebugException(reason, method: p.method));
    }
    _pending.clear();
    // 主动 close() 时不重复发「断开」事件（前端自己知道是点了断开）。
    if (!_closed) _emit(DebugEvent(kind: DebugEventKind.disconnected, message: reason));
  }
}

class _Pending {
  _Pending(this.method, this.completer);

  final String method;
  final Completer<Map<String, Object?>> completer;
}

/// 本客户端设置过的断点参数，热重启后照它重新下发。
class _OwnedBreakpoint {
  _OwnedBreakpoint({
    required this.id,
    required this.path,
    required this.line,
    this.column,
    this.condition,
    this.logMessage,
  });

  final String id;
  final String path;
  final int line;
  final int? column;
  final String? condition;
  final String? logMessage;
}

/// 断点清单快照（不透明）：热重启前留一份，重启后用 [DebugClient.reapplyBreakpoints] 重下。
class BreakpointSnapshot {
  BreakpointSnapshot._(this._items);

  final List<_OwnedBreakpoint> _items;
}

// ------------------------------------------------------------- 解析小工具

/// InstanceRef 的类名：真机是 `class`，部分版本/包装层给 `classRef`。
String? _className(Map<String, Object?>? instanceRef) =>
    _str(_asMap(instanceRef?['classRef'])?['name']) ??
    _str(_asMap(instanceRef?['class'])?['name']);

Map<String, Object?>? _asMap(Object? raw) {
  if (raw is Map<String, Object?>) return raw;
  if (raw is Map) {
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
  return null;
}

String? _str(Object? raw) {
  final s = raw?.toString();
  return s == null || s.isEmpty ? null : s;
}

int? _int(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '');
}

String? _blankToNull(String? s) {
  final t = s?.trim();
  return t == null || t.isEmpty ? null : t;
}

String _slash(String path) => path.replaceAll(r'\', '/');

String _stripTrailingSlash(String path) {
  var p = path;
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

String? _realPath(String path) {
  // 文件和目录都会走到这里：realpath 与实体类型无关，两种入口都试一下。
  try {
    return File(path).resolveSymbolicLinksSync();
  } catch (_) {}
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } catch (_) {}
  return null;
}
