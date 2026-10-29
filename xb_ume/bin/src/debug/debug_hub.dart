// GUI「调试」中枢：跑 app（flutter run）+ 连 VM 设断点，合成一套操作。
//
// 与 MCP 的 xbume_app_launch 走同一条链路（FlutterRunLauncher + 磁盘清单
// ~/.xb_ume_ide/launch/live/<pid>.json + FIFO 热重载），所以：
//   - GUI 启动的会话 AI 能复用（不会重复重装包），反之 GUI 也能接管；
//   - 断点只调 VM service，不碰编译/安装流程（GUI 不是编辑器）。
//
// 所有操作经 [handle] 分发（HTTP POST /api/debug/op），结果统一回一份状态
// 快照；调试事件与 flutter run 输出经 [push] 推给前端 WebSocket。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../device/bridge.dart' show DeviceCommandError;
import '../device/flutter_run.dart';
import '../device/live_store.dart' show pidAlive;
import '../device/run_profile.dart';
import 'breakpoint_store.dart';
import 'debug_client.dart';

/// 推送回调（GUI 侧接 `GuiState.broadcast`）。
typedef DebugPush = void Function(Map<String, Object?> message);

/// 下拉框默认值：没有选设备时用本机桌面跑起来（与 GUI 默认一致）。
final String kDebugDefaultDevice = Platform.isWindows ? 'windows' : 'macos';

/// 从 pubspec.yaml 读本包名（生成 / 反解 `package:` 脚本 URI 需要）。
String? readPubspecName(String projectRoot) {
  if (projectRoot.trim().isEmpty) return null;
  final f = File('$projectRoot/pubspec.yaml');
  if (!f.existsSync()) return null;
  try {
    for (final line in f.readAsLinesSync()) {
      final t = line.trim();
      if (!t.startsWith('name:')) continue;
      final v = t.substring(5).split('#').first.trim().replaceAll('"', '');
      return v.isEmpty ? null : v;
    }
  } catch (_) {
    // 读不到就当没有：只影响 package: 候选，file: 仍可用。
  }
  return null;
}

/// 断点参数里的「路径或脚本 URI」→ 本机路径（相对路径按项目根补全）。
String? breakpointPathOf(
  String raw, {
  String? projectRoot,
  String? packageName,
}) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  if (t.startsWith('package:') || t.startsWith('file:')) {
    return debugScriptUriToPath(t,
        projectRoot: projectRoot, packageName: packageName);
  }
  final f = File(t);
  if (f.isAbsolute) return f.path;
  final base = (projectRoot == null || projectRoot.trim().isEmpty)
      ? Directory.current.path
      : projectRoot;
  return File('$base/$t').absolute.path;
}

Map<String, Object?> debugBreakpointJson(
  DebugBreakpoint bp, {
  String? localPath,
}) =>
    <String, Object?>{
      'id': bp.id,
      'scriptUri': bp.scriptUri,
      if (localPath != null) 'path': localPath,
      'line': bp.line,
      'column': bp.column,
      'resolved': bp.resolved,
      'enabled': bp.enabled,
      if (bp.condition != null) 'condition': bp.condition,
      if (bp.logMessage != null) 'logMessage': bp.logMessage,
    };

/// 断点落盘清单里的一条（`absPath` 展开成本机绝对路径，前端直接展示）。
Map<String, Object?> debugSavedBreakpointJson(
  String projectRoot,
  SavedBreakpoint b,
) =>
    <String, Object?>{
      'path': b.path,
      'absPath': BreakpointStore.absolutePathOf(projectRoot, b.path),
      'line': b.line,
      if (b.column != null) 'column': b.column,
      if (b.condition != null) 'condition': b.condition,
      if (b.logMessage != null) 'logMessage': b.logMessage,
      'enabled': b.enabled,
    };

/// 「已记住」总览的目录顺序：按路径排序，当前项目（且真有断点）排最前。
/// 没记住任何断点的当前项目不占一个空分组。
List<String> savedAllDirs(Iterable<String> dirs, String? current) {
  final all = dirs.toList();
  final out = all.toList()..sort();
  if (current != null && all.contains(current)) {
    out
      ..remove(current)
      ..insert(0, current);
  }
  return out;
}

/// 这次会话归属的项目根：显式给的（启动时的 cwd、会话列表里的 projectRoot）
/// 优先，其次是这次认领到的 flutter run 的 cwd。
///
/// **不**回退到上一个会话的项目根：接入别的项目（IDE 里的会话、daemon 没反
/// 推出根）时若沿用旧根，会把新项目的断点记到上一个项目名下、又反向恢复旧
/// 项目的断点，两个项目的清单就串了。拿不到根宁可这次不落盘。
String? bindProjectRoot(String? explicit, String? handleCwd) {
  for (final raw in <String?>[explicit, handleCwd]) {
    final s = raw?.trim() ?? '';
    if (s.isNotEmpty) return BreakpointStore.normalizeRoot(s);
  }
  return null;
}

Map<String, Object?> debugVarJson(DebugVar v) => <String, Object?>{
      'name': v.name,
      'value': v.value,
      if (v.type != null) 'type': v.type,
      if (v.kind != null) 'kind': v.kind,
      if (v.objectId != null) 'objectId': v.objectId,
      // 框架 / 依赖库里声明的字段：界面默认藏起来（`ChangeNotifier._count` 之类）。
      if (!v.own) 'own': false,
      // 值类型是框架 / 依赖对象：筛选扫描不往里钻。
      if (v.fw) 'fw': true,
    };

Map<String, Object?> debugFrameJson(
  DebugFrame f, {
  String? Function(String uri)? toLocal,
}) =>
    <String, Object?>{
      'index': f.index,
      'function': f.function,
      'scriptUri': f.scriptUri,
      if (f.scriptUri != null && toLocal != null)
        'path': toLocal(f.scriptUri!),
      'line': f.line,
      'column': f.column,
      'vars': <Object?>[for (final v in f.vars) debugVarJson(v)],
      'label': f.label,
    };

Map<String, Object?> debugPauseJson(
  DebugPause p, {
  String? Function(String uri)? toLocal,
}) =>
    <String, Object?>{
      'reason': p.reason,
      'fromBreakpoint': p.fromBreakpoint,
      'fromException': p.fromException,
      'breakpointIds': p.breakpointIds,
      if (p.exception != null) 'exception': p.exception,
      if (p.topFrame != null)
        'topFrame': debugFrameJson(p.topFrame!, toLocal: toLocal),
    };

Map<String, Object?> debugEventJson(
  DebugEvent e, {
  String? Function(String uri)? toLocal,
}) =>
    <String, Object?>{
      'kind': e.kind.name,
      if (e.isolateId != null) 'isolateId': e.isolateId,
      if (e.pause != null) 'pause': debugPauseJson(e.pause!, toLocal: toLocal),
      if (e.breakpoint != null)
        'breakpoint': debugBreakpointJson(
          e.breakpoint!,
          localPath: e.breakpoint!.scriptUri == null
              ? null
              : toLocal?.call(e.breakpoint!.scriptUri!),
        ),
      if (e.condition != null) 'condition': e.condition,
      if (e.message != null) 'message': e.message,
    };

/// 用户可读的错误文案（DeviceCommandError 的 toString 太长，取 message）。
String debugErrorText(Object e) {
  if (e is DebugException) return e.message;
  if (e is DeviceCommandError) return e.message;
  return '$e';
}

/// 求值失败时的「是不是写错了」建议（IDE 式的 did you mean）。
///
/// VM 编译表达式的错误长这样（一大段）：
///   Error: The getter 'runTimeType' isn't defined for the class 'HomePage'. -
///   'HomePage' is from 'package:app/x.dart' ('lib/x.dart').
/// 从里面认出错写的成员名 + 类名 + 来源文件，到本机源码里扫该类的成员，
/// 按编辑距离取最近的 1~2 个（`runTimeType` → `runtimeType`）。
/// 认不出 / 读不到源码时返回空列表，调用方原样展示错误。
List<String> evalMemberSuggestions(String error, String? projectRoot) {
  final m = RegExp(
          r"'([A-Za-z_$][\w$]*)' isn't defined for the class '([A-Za-z_$][\w$]*)'")
      .firstMatch(error);
  if (m == null) return const <String>[];
  final member = m.group(1)!;
  final cls = m.group(2)!;
  if (projectRoot == null || projectRoot.isEmpty) return const <String>[];

  // 来源文件在错误末尾：('lib/pages/…/x.dart')，是相对项目根的路径。
  final files = RegExp(r"\('([^']+\.dart)'\)").allMatches(error).toList();
  if (files.isEmpty) return const <String>[];
  final rel = files.last.group(1)!;
  final path = rel.startsWith('/') ? rel : '$projectRoot/$rel';
  String src;
  try {
    src = File(path).readAsStringSync();
  } catch (_) {
    return const <String>[];
  }

  final body = _dartClassBodyOf(src, cls);
  if (body == null) return const <String>[];
  // 类体里声明的成员 + 继承来的常用成员（runtimeType 之类不会出现在类体里，
  // 光扫源码的话 `runTimeType` 永远没有候选）。
  final names = <String>{..._dartMemberNamesOf(body), ..._commonMembers};

  // 阈值随名字长度放宽：短名字 1，长名字最多 3——太宽会变成噪音。
  // 比较用小写，避免大小写差异（runTimeType / runtimeType）被算成两处错。
  final limit = member.length <= 4 ? 1 : (member.length <= 10 ? 2 : 3);
  final low = member.toLowerCase();
  final scored = <(int, String)>[];
  for (final n in names) {
    if (n == member) continue;
    final d = _editDistance(low, n.toLowerCase());
    if (d <= limit) scored.add((d, n));
  }
  scored.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  return <String>[for (final s in scored.take(2)) s.$2];
}

/// 源码中类 <clsName> 的类体（大括号配平截取，不含外层花括号）；找不到返回 null。
/// 匹配口径与 GUI 路由栈那套静态解析一致（允许 abstract/base/final/sealed 前缀）。
String? _dartClassBodyOf(String src, String clsName) {
  final m = RegExp(
          '(?:^|\\s)(?:abstract\\s+|base\\s+|final\\s+|sealed\\s+|mixin\\s+)*class\\s+'
          '${RegExp.escape(clsName)}[\\s<]')
      .firstMatch(src);
  if (m == null) return null;
  final open = src.indexOf('{', m.end);
  if (open < 0) return null;
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  return null;
}

/// 不写在类体里、但 Object / Widget / State 都有的成员。
/// 用户把 `runtimeType` 写成 `runTimeType` 时，扫源码扫不到它，只能靠这份兜底。
const _commonMembers = <String>[
  'runtimeType',
  'toString',
  'hashCode',
  'noSuchMethod',
  'mounted',
  'context',
  'widget',
  'setState',
  'build',
  'dispose',
  'initState',
];

/// 类体里的成员名（字段 / getter / setter / 方法），给拼写建议用。
Set<String> _dartMemberNamesOf(String body) {
  final out = <String>{};
  for (final m
      in RegExp(r'\b(?:get|set)\s+([A-Za-z_$][\w$]*)').allMatches(body)) {
    out.add(m.group(1)!);
  }
  for (final m in RegExp(
          r'\b(?:final|late|const|var|static)\s+[^;=(){}]*?\b([A-Za-z_$][\w$]*)\s*(?:=|;)')
      .allMatches(body)) {
    out.add(m.group(1)!);
  }
  // 不带修饰符的字段：`int page = 0;` / `EasyRefreshController c;`。
  // 只认行首（缩进后）的「类型 名字 =/;」，避免把方法体里的表达式也算成成员。
  for (final m in RegExp(
          r'^\s*[A-Za-z_$][\w$<>?,\[\] ]*\s+([A-Za-z_$][\w$]*)\s*(?:=|;)',
          multiLine: true)
      .allMatches(body)) {
    out.add(m.group(1)!);
  }
  for (final m in RegExp(
          r'\b[A-Za-z_$][\w$<>?,\[\] ]*\s+([A-Za-z_$][\w$]*)\s*\(')
      .allMatches(body)) {
    out.add(m.group(1)!);
  }
  out.removeAll(const <String>{
    'if', 'for', 'while', 'switch', 'catch', 'return', 'else', 'new', 'assert',
    'await', 'super', 'this', 'is', 'as', 'in', 'throw', 'try', 'do', 'when',
  });
  return out;
}

/// 两个标识符的编辑距离（Levenshtein，滚动两行，短串够用）。
int _editDistance(String a, String b) {
  final m = a.length, n = b.length;
  if (m == 0) return n;
  if (n == 0) return m;
  var prev = List<int>.generate(n + 1, (i) => i);
  var cur = List<int>.filled(n + 1, 0);
  for (var i = 1; i <= m; i++) {
    cur[0] = i;
    for (var j = 1; j <= n; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var v = prev[j - 1] + cost;
      if (prev[j] + 1 < v) v = prev[j] + 1;
      if (cur[j - 1] + 1 < v) v = cur[j - 1] + 1;
      cur[j] = v;
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[n];
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

int? _int(Object? v) {
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}'.trim());
}

/// 一次调试会话的编排器（GUI 单实例一个）。
class DebugHub {
  DebugHub({
    required this.push,
    FlutterRunLauncher? launcher,
    BreakpointStore? store,
  })  : launcher = launcher ?? FlutterRunLauncher(),
        store = store ?? BreakpointStore();

  final DebugPush push;
  final FlutterRunLauncher launcher;

  /// 断点落盘：VM 会把断开客户端的断点删掉，重连后靠它恢复。
  final BreakpointStore store;

  DebugClient? _client;
  StreamSubscription<DebugEvent>? _eventSub;
  LaunchHandle? _handle;
  String? _wsUri;
  String? _projectRoot;
  String? _packageName;
  bool _reused = false;
  bool _busy = false;
  String? _message;

  // flutter run 输出跟随：自己拉起与认领的会话都从日志文件增量读，
  // 不依赖进程句柄（GUI 重启、AI 先启动的场景一样能看输出）。
  Timer? _followTimer;
  String? _followPath;
  int _followOffset = 0;
  String _followPending = '';
  Timer? _flushTimer;
  final List<String> _pendingOut = <String>[];
  final List<String> _tail = <String>[];
  int _outSeq = 0;

  /// 当前会话状态快照（前端整屏渲染就用它）。
  Map<String, Object?> status({bool withOutput = false}) {
    final c = _client;
    final h = _handle;
    final pause = c?.currentPause;
    return <String, Object?>{
      'running': h != null && pidAlive(h.pid),
      'pid': h?.pid,
      'device': h?.device,
      'target': h?.target,
      'cwd': h?.cwd ?? _projectRoot,
      'logPath': h?.logPath,
      'wsUri': _wsUri ?? h?.wsUri,
      'owner': h?.owner,
      'reused': _reused,
      'adopted': h?.adopted ?? false,
      'attached': c?.connected ?? false,
      'paused': c?.paused ?? false,
      'isolateId': c?.knownIsolateId,
      'pause': pause == null ? null : debugPauseJson(pause, toLocal: _toLocal),
      'breakpoints': _breakpointList(),
      'projectRoot': _projectRoot,
      'packageName': _packageName,
      'busy': _busy,
      if (_message != null) 'message': _message,
      'outSeq': _outSeq,
      if (withOutput) 'output': List<String>.of(_tail),
    };
  }

  /// 关闭调试连接与后台跟随（不停 app：GUI 退出后 flutter run 继续跑，
  /// 这正是「AI/GUI 互相复用」的前提）。
  Future<void> dispose() async {
    _stopFollow();
    await _detachClient();
  }

  /// 统一入口：`op` 见 README/前端按钮；结果总是「ok + 状态快照」，
  /// 失败时带 error 文案，不向 HTTP 层抛异常。
  Future<Map<String, Object?>> handle(
    String op,
    Map<String, Object?> args,
  ) async {
    var extra = const <String, Object?>{};
    try {
      extra = await _dispatch(op, args);
      return <String, Object?>{'ok': true, 'op': op, ...status(), ...extra};
    } catch (e) {
      // 求值写错成员名很常见，顺手给一份拼写候选（其余 op 不带）。
      final suggest = op == 'eval'
          ? evalMemberSuggestions(debugErrorText(e), _projectRoot)
          : const <String>[];
      return <String, Object?>{
        'ok': false,
        'op': op,
        'error': debugErrorText(e),
        if (suggest.isNotEmpty) 'suggest': suggest,
        ...status(),
      };
    } finally {
      _pushState();
    }
  }

  Future<Map<String, Object?>> _dispatch(
    String op,
    Map<String, Object?> a,
  ) async {
    switch (op) {
      case 'status':
        // 整屏渲染一次拿全：状态 + 最近输出（最多 300 行）。
        return <String, Object?>{'output': List<String>.of(_tail)};
      case 'start':
        return _start(a);
      case 'attach':
        return _attach(a);
      case 'detach':
        await _detachClient();
        _stopFollow();
        _message = '已断开调试连接（app 仍在运行）';
        return const <String, Object?>{};
      case 'stop':
        return _stop(a);
      case 'hot':
        return _hot(a);
      case 'pause':
        await _requireClient().pause();
        _message = '已请求暂停';
        return const <String, Object?>{};
      case 'resume':
        return _resume(a);
      case 'addBreakpoint':
        return _addBreakpoint(a);
      case 'removeBreakpoint':
        return _removeBreakpoint(a);
      case 'updateBreakpoint':
        return _updateBreakpoint(a);
      case 'toggleBreakpoint':
        return _toggleBreakpoint(a);
      case 'toggleAllBreakpoints':
        // 一键启停（IDE 的「停用所有断点」）：断点不删，只切 VM 的 enable。
        return _toggleAllBreakpoints(a);
      case 'listBreakpoints':
        final bps = await _requireClient().listBreakpoints();
        return <String, Object?>{'count': bps.length};
      case 'saved':
      case 'savedBreakpoints':
        // 已记住的断点：没连会话也能看（GUI 重启后断点表为空，但清单还在）。
        final dir = _savedRoot(a);
        if (dir == null) return <String, Object?>{'saved': const <Object?>[]};
        return <String, Object?>{
          'dir': BreakpointStore.normalizeRoot(dir),
          'saved': <Object?>[
            for (final b in store.load(dir))
              debugSavedBreakpointJson(dir, b),
          ],
        };
      case 'savedAll':
        // 所有项目记住的断点（换项目后也能看见旧项目的清单）。
        return _savedAll();
      case 'forgetSaved':
        final root = _savedRoot(a);
        if (root == null) {
          throw DebugException('缺少项目目录 dir：先在调试页选项目目录');
        }
        final n = store.clear(root);
        _message = n == 0 ? '没有记住的断点' : '已忘记 $n 个断点（下次连接不再自动恢复）';
        return <String, Object?>{'cleared': n};
      case 'rememberBreakpoint':
        return _rememberBreakpoint(a);
      case 'forgetBreakpoint':
        // 只删落盘清单里的一条（源码面板「再点一次取消」用；不碰当前会话）。
        return _forgetSavedBreakpoint(a);
      case 'enableSavedBreakpoint':
        // 启停「已记住」里的一条：没连会话也能改，下次接入按新状态恢复；
        // 当前会话有同位置断点时一并切 VM 的启停。
        return _enableSavedBreakpoint(a);
      case 'stack':
        final frames = await _requireClient().stack(limit: _int(a['limit']) ?? 32);
        return <String, Object?>{
          'frames': <Object?>[
            for (final f in frames) debugFrameJson(f, toLocal: _toLocal),
          ],
        };
      case 'getObject':
        // 展开变量里的对象实例（DebugVar.objectId）：只读一层，子项再点再读。
        final objectId = _str(a['objectId']);
        if (objectId == null || objectId.isEmpty) {
          throw DebugException('缺少 objectId：刷新调用栈后重点变量行左侧箭头');
        }
        final fields = await _requireClient().objectFields(
          objectId,
          offset: _int(a['offset']) ?? 0,
          count: _int(a['count']) ?? 50,
        );
        return <String, Object?>{
          'vars': <Object?>[for (final v in fields.vars) debugVarJson(v)],
          'total': fields.total,
          'truncated': fields.truncated,
        };
      case 'runProfile':
        return _runProfile(a);
      case 'eval':
        return _eval(a);
      default:
        throw DebugException('未知操作：$op');
    }
  }

  // ---------------------------------------------------------------- 运行

  /// 当前项目的运行配置（GUI 只读展示 + 「打开配置」用）。
  ///
  /// 没有目录 / 没配置都正常返回（`profile` 缺席），前端据此显示「未配置」。
  Map<String, Object?> _runProfile(Map<String, Object?> a) {
    final dir = _str(a['dir']) ?? _projectRoot;
    final path = runProfileFilePath();
    if (dir == null) {
      return <String, Object?>{
        'dir': null,
        'path': path,
        'exists': File(path).existsSync(),
      };
    }
    final p = loadRunProfile(dir);
    return <String, Object?>{
      'dir': normalizeProjectRoot(dir),
      'path': path,
      'exists': File(path).existsSync(),
      if (p != null) 'profile': p.toJson(),
    };
  }

  Future<Map<String, Object?>> _start(Map<String, Object?> a) async {
    if (_busy) throw DebugException('正在启动中，请稍候再点');
    final device = _str(a['device']) ?? kDebugDefaultDevice;
    final target = _str(a['target']);
    final platform = _str(a['platform']);
    final cwd = _str(a['cwd']) ?? _handle?.cwd ?? _projectRoot;
    _busy = true;
    final profile = cwd == null ? null : loadRunProfile(cwd);
    // 只在「配置对当前平台生效」时才提示预启动；平台未知时按后端识别的结果算，
    // 这里不抢话术（宁可说“启动中”）。
    final willPreRun = profile != null &&
        profile.preRun.isNotEmpty &&
        profile.appliesTo(platformKeyOf(platform));
    _message = willPreRun
        ? '正在执行预启动命令（${profile.preRun.length} 条）…'
        : '正在启动 flutter run -d $device …';
    _pushState();
    try {
      final r = await launcher.launch(
        device: device,
        target: target,
        cwd: cwd,
        platform: platform,
        owner: 'gui',
        timeout: const Duration(seconds: 240),
      );
      _reused = r.reused;
      final ws = _str(r.wsUri);
      if (ws == null) {
        throw DebugException('会话已启动（pid ${r.pid}）但没拿到 VM service 地址，'
            '编译可能仍在进行：稍后点「接入」或重新点启动（会自动复用）。');
      }
      final note = await _bind(
        wsUri: ws,
        pid: r.pid,
        projectRoot: cwd,
        // 自己拉起的从日志头开始（能看到预启动与编译过程）；复用只看新输出。
        followFromStart: !r.reused,
      );
      // 预启动输出已写在日志文件头部，_startFollow（followFromStart）
      // 会从文件头读进来，这里不再重复推。
      final preNote = r.preRunCommands.isEmpty
          ? ''
          : '；预启动 ${r.preRunCommands.length} 条命令'
              '${r.preRunLines.any((l) => l.contains('失败：')) ? '（有失败，已按配置继续）' : '完成'}';
      _message =
          '${r.reused ? '复用已有会话 pid ${r.pid}（未重装包）' : '已启动 pid ${r.pid}（$device）'}'
          '$preNote${r.note == null ? '' : '；${r.note}'}'
          '${note == null ? '' : '；$note'}';
      return <String, Object?>{
        'pid': r.pid,
        'reused': r.reused,
        'platform': platform,
        'preRun': r.preRunCommands,
      };
    } on DeviceCommandError catch (e) {
      // 启动失败（编译 / 装包 / 端口转发）时输出已落在日志文件里：接到
      // 「运行输出」，否则页面上只剩几秒的提示，真正的原因（在日志末尾）
      // 看不到，看起来就像“什么都没打印”。
      _followFailureLog(e.logPath);
      _message = '启动失败：${e.message.split('\n').first}';
      rethrow;
    } finally {
      _busy = false;
    }
  }

  /// 启动失败后把已落盘的日志接到输出面板（文件不在就算了）。
  void _followFailureLog(String? path) {
    if (path == null || path.isEmpty) return;
    if (!File(path).existsSync()) return;
    _startFollow(path, fromStart: true);
  }

  Future<Map<String, Object?>> _attach(Map<String, Object?> a) async {
    final raw = _str(a['wsUri']) ?? _str(a['uri']);
    if (raw == null) {
      throw DebugException('缺少 wsUri：从会话列表选一条调试会话，或直接点「启动」');
    }
    final pid = _int(a['pid']);
    _reused = true;
    final note = await _bind(
      wsUri: raw,
      pid: pid,
      projectRoot: _str(a['projectRoot']),
      packageName: _str(a['packageName']),
      followFromStart: a['fromStart'] == true,
    );
    final h = _handle;
    _message = h == null
        ? '已接入外部会话（只能断点/单步，热重载需从 IDE/终端操作）'
        : '已接入会话 pid ${h.pid}（${h.device}）';
    if (note != null) _message = '$_message；$note';
    return <String, Object?>{
      'pid': h?.pid,
      'hotReloadable': h != null,
    };
  }

  Future<Map<String, Object?>> _stop(Map<String, Object?> a) async {
    final pid = _resolvePid(_int(a['pid']));
    await _detachClient();
    _stopFollow();
    if (pid == null) {
      _handle = null;
      _wsUri = null;
      _message = '没有在跑的 flutter run 会话（只断开了调试连接）';
      return <String, Object?>{'stopped': false};
    }
    if (launcher.byPid(pid) == null) {
      // 磁盘清单里没有这个 pid：可能是 IDE 的进程，绝不能按 pid 乱杀。
      throw DebugException('pid $pid 不是本工具（GUI/MCP）拉起的 flutter run，'
          '不能在 GUI 里停止；请回到 IDE / 终端操作。');
    }
    final r = await launcher.stop(pid);
    _handle = null;
    _wsUri = null;
    _reused = false;
    for (final line in r.postStopLines) {
      _onOutput(line);
    }
    final postNote = r.postStopLines.isEmpty
        ? ''
        : '；停止清理${r.postStopLines.any((l) => l.contains('失败')) ? '有失败（见输出）' : '完成'}';
    _message = r.stopped
        ? '已停止 pid $pid${r.children.isEmpty ? '' : '（子进程 ${r.children.join(', ')}）'}$postNote'
        : 'pid $pid 已不在运行';
    return <String, Object?>{
      'stopped': r.stopped,
      'children': r.children,
      'postStop': r.postStopLines,
    };
  }

  Future<Map<String, Object?>> _hot(Map<String, Object?> a) async {
    final restart = a['restart'] == true;
    final pid = _resolvePid(null);
    if (pid == null) {
      throw DebugException('当前没有本机 flutter run 会话，无法热重载：'
          '先在「调试」里启动，或用会话列表接入 GUI/MCP 拉起的会话');
    }
    if (launcher.byPid(pid) == null) {
      throw DebugException('pid $pid 不在本工具的运行清单里，无法热重载：'
          '请回到 IDE / 终端按 r');
    }
    // 热重启会换 isolate：VM 会为旧 isolate 的断点逐个发 BreakpointRemoved，
    // 客户端的登记清单会被一并清空，所以动手前先留快照，重启完按它重下。
    final snap = restart ? _client?.snapshotBreakpoints() : null;
    final r = await launcher.hotReload(pid, restart: restart);
    if (!r.ok) {
      _message = r.message;
      throw DebugException(r.message);
    }
    if (restart && _client != null) {
      _client!.resetIsolate();
      try {
        await _client!.reapplyBreakpoints(from: snap);
      } catch (_) {
        // 单个断点重下失败（行已删）不影响整体。
      }
    }
    // 热重载常直接把 UI 重建到断点上：把「已暂停」带在消息里，免得
    // 暂停事件先到、被这句覆盖后看不出停在哪（状态行/工具条仍显示位置）。
    final pausedNow = _client?.paused ?? false;
    _message = '${restart ? '热重启' : '热重载'}完成（${r.elapsedMs}ms）：${r.message}'
        '${pausedNow ? '；已暂停在断点' : ''}';
    return <String, Object?>{'elapsedMs': r.elapsedMs};
  }

  // ---------------------------------------------------------------- 断点

  /// 只写进落盘清单（不建 VM 断点）：异常栈帧 / 网络发起位置没连会话时
  /// 「一键下断点」用它先记住，下次 start / attach 到同一项目自动重下。
  Future<Map<String, Object?>> _rememberBreakpoint(
      Map<String, Object?> a) async {
    final raw = _str(a['path']);
    if (raw == null) throw DebugException('缺少 path（源码文件路径）');
    final line = _int(a['line']);
    if (line == null || line < 1) throw DebugException('缺少行号 line（从 1 开始）');
    final root = _savedRoot(a);
    if (root == null) {
      throw DebugException('缺少项目目录 dir：先在调试页选项目目录');
    }
    final rel = BreakpointStore.relativePathOf(root, raw);
    store.add(
      root,
      SavedBreakpoint(
        path: rel,
        line: line,
        condition: _str(a['condition']),
        logMessage: _str(a['logMessage']),
      ),
    );
    _message = '已记住断点 ${_short(raw)}:$line，下次启动 / 接入自动生效';
    return <String, Object?>{
      'dir': root,
      'saved': <Object?>[
        for (final b in store.load(root)) debugSavedBreakpointJson(root, b),
      ],
    };
  }

  /// 从「已记住」清单里删一条（不碰当前会话的 VM 断点）：源码面板再点一次取消它。
  Future<Map<String, Object?>> _forgetSavedBreakpoint(
      Map<String, Object?> a) async {
    final raw = _str(a['path']);
    if (raw == null) throw DebugException('缺少 path（源码文件路径）');
    final line = _int(a['line']);
    if (line == null || line < 1) throw DebugException('缺少行号 line（从 1 开始）');
    final root = _savedRoot(a);
    if (root == null) {
      throw DebugException('缺少项目目录 dir：先在调试页选项目目录');
    }
    final rel = BreakpointStore.relativePathOf(root, raw);
    final hit = store.remove(root, rel, line, column: _int(a['column']));
    _message = hit
        ? '已取消记住 ${_short(raw)}:$line'
        : '这条不在记住的清单里（可能已被清空）';
    return <String, Object?>{'removed': hit};
  }

  /// 启停「已记住」清单里的一条（没有 VM 断点 id 也能用）。
  ///
  /// 会话断点与落盘清单是两套状态：只改清单的话，当前会话里那条断点依旧
  /// 命中，用户会觉得「点了停用却没用」。所以同位置的会话断点也一并切；
  /// 对不上（换了项目 / 断点还没下发）就只改清单，下次接入按新状态恢复。
  Future<Map<String, Object?>> _enableSavedBreakpoint(
      Map<String, Object?> a) async {
    final raw = _str(a['path']);
    if (raw == null) throw DebugException('缺少 path（源码文件路径）');
    final line = _int(a['line']);
    if (line == null || line < 1) throw DebugException('缺少行号 line（从 1 开始）');
    final root = _savedRoot(a);
    if (root == null) {
      throw DebugException('缺少项目目录 dir：先在调试页选项目目录');
    }
    final rel = BreakpointStore.relativePathOf(root, raw);
    final column = _int(a['column']);

    // 不传 enabled 就按清单现值取反（前端点一下就是切一下）。
    final bool want;
    final rawEnabled = a['enabled'];
    if (rawEnabled is bool) {
      want = rawEnabled;
    } else {
      final cur =
          store.load(root).where((b) => b.path == rel && b.line == line);
      want = cur.isEmpty ? true : !cur.first.enabled;
    }
    final hit = store.setEnabled(root, rel, line, want, column: column);

    var applied = 0;
    final client = _client;
    if (client != null) {
      for (final bp in client.breakpoints) {
        if (bp.line != line) continue;
        final uri = bp.scriptUri;
        final local = uri == null ? null : client.localPathOf(uri);
        if (local == null) continue;
        if (BreakpointStore.relativePathOf(root, local) != rel) continue;
        try {
          await client.setBreakpointEnabled(bp.id, want);
          applied++;
        } catch (_) {
          // 会话正在断 / 该断点已失效：清单已改，这里不阻断。
        }
      }
    }

    _message = hit
        ? '已${want ? '启用' : '停用'}记住的断点 ${_short(raw)}:$line'
            '${applied > 0 ? '（当前会话已同步）' : ''}'
        : '这条不在记住的清单里（可能已被清空）';
    return <String, Object?>{
      'enabled': want,
      'applied': applied,
      'hit': hit,
    };
  }

  Future<Map<String, Object?>> _addBreakpoint(Map<String, Object?> a) async {
    final raw = _str(a['path']);
    if (raw == null) throw DebugException('缺少 path（源码文件路径或脚本 URI）');
    final line = _int(a['line']);
    if (line == null) throw DebugException('缺少行号 line（从 1 开始）');
    final path = breakpointPathOf(raw,
        projectRoot: _projectRoot, packageName: _packageName);
    if (path == null) {
      throw DebugException('无法解析断点路径：$raw（只支持本项目源码与本机文件）');
    }
    final bp = await _requireClient().addBreakpoint(
      path: path,
      line: line,
      column: _int(a['column']),
      condition: _str(a['condition']),
      logMessage: _str(a['logMessage']),
    );
    // 断点落盘：VM 在客户端断开时会把它删掉，下次连同一项目靠这份清单恢复。
    final root = _projectRoot;
    if (root != null && bp.line != null) {
      store.add(
        root,
        SavedBreakpoint(
          path: BreakpointStore.relativePathOf(root, path),
          line: bp.line!,
          column: bp.column,
          condition: bp.condition,
          logMessage: bp.logMessage,
          enabled: bp.enabled,
        ),
      );
    }
    _message = '已加断点 ${_short(bp.scriptUri ?? path)}:${bp.line ?? line}'
        '${bp.resolved ? '' : '（待解析）'}'
        '${bp.condition == null ? '' : ' if ${bp.condition}'}'
        '${bp.logMessage == null ? '' : ' log ${bp.logMessage}'}'
        '${root == null ? '（没识别出项目根，这次断点不会记住）' : ''}';
    return <String, Object?>{'breakpoint': debugBreakpointJson(bp, localPath: path)};
  }

  Future<Map<String, Object?>> _removeBreakpoint(
      Map<String, Object?> a) async {
    final id = _str(a['id']);
    if (id == null) throw DebugException('缺少断点 id');
    final client = _requireClient();
    final bp = _breakpointById(client, id);
    await client.removeBreakpoint(id);
    _syncSavedBreakpoint(client, bp);
    _message = '已删除断点 $id';
    return const <String, Object?>{};
  }

  /// 改断点的条件 / 日志表达式：位置不变，只改客户端登记并覆盖落盘清单。
  Future<Map<String, Object?>> _updateBreakpoint(
      Map<String, Object?> a) async {
    final id = _str(a['id']);
    if (id == null) throw DebugException('缺少断点 id');
    final client = _requireClient();
    final bp = client.updateBreakpoint(
      id,
      condition: _str(a['condition']),
      logMessage: _str(a['logMessage']),
    );
    final root = _projectRoot;
    final uri = bp.scriptUri;
    final local = uri == null ? null : client.localPathOf(uri);
    if (root != null && local != null && bp.line != null) {
      store.add(
        root,
        SavedBreakpoint(
          path: BreakpointStore.relativePathOf(root, local),
          line: bp.line!,
          column: bp.column,
          condition: bp.condition,
          logMessage: bp.logMessage,
          enabled: bp.enabled,
        ),
      );
    }
    _message = '已更新断点 ${_short(bp.scriptUri ?? id)}:${bp.line ?? '?'}'
        '${bp.condition == null ? '' : ' if ${bp.condition}'}'
        '${bp.logMessage == null ? '' : ' log ${bp.logMessage}'}';
    return <String, Object?>{
      'breakpoint': debugBreakpointJson(bp, localPath: local),
    };
  }

  Future<Map<String, Object?>> _toggleBreakpoint(
      Map<String, Object?> a) async {
    final id = _str(a['id']);
    if (id == null) throw DebugException('缺少断点 id');
    final client = _requireClient();
    var enable = a['enabled'];
    if (enable is! bool) {
      final cur = client.breakpoints.where((b) => b.id == id);
      enable = cur.isEmpty ? true : !cur.first.enabled;
    }
    await client.setBreakpointEnabled(id, enable);
    final bp = _breakpointById(client, id)?.copyWith(enabled: enable);
    _syncSavedBreakpoint(client, bp, enabled: enable);
    _message = '断点 $id 已${enable ? '启用' : '停用'}';
    return <String, Object?>{'enabled': enable};
  }

  /// 一键启停当前会话的全部断点：断点都留着，只切 VM 的 enable。
  ///
  /// VM 没有批量 RPC，逐条 `setBreakpointState`；已经处于目标状态的跳过，
  /// 免得一次点击变成一串无意义的往返。落盘清单同步成新状态（下次接入
  /// 恢复的就是「全部停用」）。
  Future<Map<String, Object?>> _toggleAllBreakpoints(
      Map<String, Object?> a) async {
    final enable = a['enabled'];
    if (enable is! bool) throw DebugException('缺少 enabled（true / false）');
    final client = _requireClient();
    final all = client.breakpoints;
    var changed = 0;
    for (final bp in all) {
      if (bp.enabled == enable) continue;
      await client.setBreakpointEnabled(bp.id, enable);
      _syncSavedBreakpoint(client, _breakpointById(client, bp.id),
          enabled: enable);
      changed++;
    }
    final action = enable ? '启用' : '停用';
    _message = all.isEmpty
        ? '当前会话还没有断点'
        : '已$action $changed 个断点（共 ${all.length} 个）';
    return <String, Object?>{
      'enabled': enable,
      'changed': changed,
      'count': all.length,
    };
  }

  DebugBreakpoint? _breakpointById(DebugClient c, String id) {
    for (final b in c.breakpoints) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// 删掉（enabled 传 null）/ 启停断点时同步落盘清单；路径转成项目内相对。
  void _syncSavedBreakpoint(DebugClient c, DebugBreakpoint? bp, {bool? enabled}) {
    final root = _projectRoot;
    if (root == null || bp == null || bp.line == null) return;
    final uri = bp.scriptUri;
    final local = uri == null ? null : c.localPathOf(uri);
    if (local == null) return;
    final rel = BreakpointStore.relativePathOf(root, local);
    if (enabled == null) {
      store.remove(root, rel, bp.line!, column: bp.column);
    } else {
      store.setEnabled(root, rel, bp.line!, enabled, column: bp.column);
    }
  }

  // ---------------------------------------------------------------- 执行

  Future<Map<String, Object?>> _resume(Map<String, Object?> a) async {
    final step = switch ('${a['step'] ?? 'continue'}'.trim().toLowerCase()) {
      'into' || 'stepin' || 'step-into' => DebugStep.into,
      'over' || 'stepover' || 'step-over' => DebugStep.over,
      'out' || 'stepout' || 'step-out' => DebugStep.out,
      _ => null,
    };
    await _requireClient().resume(step: step);
    _message = step == null ? '已继续' : step.label;
    return <String, Object?>{'step': step?.name};
  }

  Future<Map<String, Object?>> _eval(Map<String, Object?> a) async {
    final expr = _str(a['expression']);
    if (expr == null) throw DebugException('缺少 expression');
    final idx = _int(a['frameIndex']) ?? 0;
    final frames = await _requireClient().stack(limit: 1);
    if (frames.isEmpty) {
      throw DebugException('当前没有调用栈：先暂停（断点命中）再求值');
    }
    final value = await _requireClient().evaluateInFrame(idx, expr);
    return <String, Object?>{'expression': expr, 'frameIndex': idx, 'value': value};
  }

  // ---------------------------------------------------------------- 内部

  Future<String?> _bind({
    required String wsUri,
    int? pid,
    String? projectRoot,
    String? packageName,
    bool followFromStart = false,
  }) async {
    launcher.adoptRecords();
    var h = pid == null ? null : launcher.byPid(pid);
    // 只给了 VM 地址（从会话列表接入）时按端口反查运行清单：认领到句柄
    // 才能热重载，也才能跟到它那份 flutter run 日志。
    if (h == null) {
      final port = Uri.tryParse(wsUri)?.port ?? 0;
      final found = port > 0 ? launcher.pidForPort(port) : null;
      if (found != null) h = launcher.byPid(found);
    }
    await _detachClient();
    _stopFollow();
    // 新会话从空白输出开始（上一轮日志已随 status 回给前端留档）。
    _tail.clear();
    _pendingOut.clear();
    _handle = h;
    _wsUri = wsUri;
    _projectRoot = bindProjectRoot(projectRoot, h?.cwd);
    _packageName = _str(packageName) ?? readPubspecName(_projectRoot ?? '');
    final client = DebugClient(
      wsUri,
      projectRoot: _projectRoot,
      packageName: _packageName,
    );
    await client.connect();
    // 外部 IDE 起的会话没有运行清单句柄（h == null），也就没有 cwd：从 VM 的入口
    // 脚本反推项目根，否则断点无处落盘、源码面板与文件清单都用不了。
    if (_projectRoot == null) {
      final inferred = await _inferProjectRoot(client);
      if (inferred != null) {
        final root = BreakpointStore.normalizeRoot(inferred);
        _projectRoot = root;
        _packageName ??= readPubspecName(root);
        client.retarget(projectRoot: _projectRoot, packageName: _packageName);
      }
    }
    _client = client;
    _eventSub = client.events.listen(_onEvent);
    try {
      await client.listBreakpoints();
    } catch (_) {
      // 老版本 VM 可能不支持；断点列表随事件增量更新。
    }
    // 接进来的可能是「已在断点上暂停」的会话（GUI 重启 / 复用别人的调试）：
    // VM 不会重发 Pause 事件，不同步的话界面会显示运行中、单步也用不了。
    try {
      await client.syncPause();
    } catch (_) {
      // isolate 正在启动 / 老版本 VM 没有 pauseEvent：当运行中处理。
    }
    _startFollow(h?.logPath ?? '', fromStart: followFromStart);
    // VM 在客户端断开时会把断点一起删掉：重连到同一项目就把上次的断点重下。
    return _restoreBreakpoints();
  }

  /// 从 VM 入口脚本（isolate.rootLib）反推项目根。
  /// 只看入口脚本：path 依赖的库也是 file: 且自带 pubspec，全局扫脚本会误认。
  Future<String?> _inferProjectRoot(DebugClient c) async {
    try {
      final iso = await c.isolateId();
      final r = await c.rpc('getIsolate', <String, Object?>{'isolateId': iso});
      final rootLib = r['rootLib'];
      final uri = rootLib is Map ? _str(rootLib['uri']) : null;
      if (uri == null) return null;
      if (uri.startsWith('file:')) return projectRootFromScriptUri(uri);
      if (!uri.startsWith('package:')) return null;
      // 入口脚本是 package:<pkg>/main.dart：在已加载脚本里找同包名的 file: 路径，
      // 再用 pubspec 的 name 校验，避开同样以 file: 出现的 path 依赖。
      final rest = uri.substring('package:'.length);
      final pkg = rest.split('/').first;
      if (pkg.isEmpty) return null;
      for (final u in await c.loadedScriptUris()) {
        if (!u.startsWith('file:')) continue;
        final root = projectRootFromScriptUri(u);
        if (root == null) continue;
        if (readPubspecName(root) == pkg) return root;
      }
    } catch (_) {
      // isolate 正在启动 / 已退出：交给调用方按空处理。
    }
    return null;
  }

  /// 按项目根把上次的断点重下（已存在的同位置跳过）。返回给人看的摘要。
  Future<String?> _restoreBreakpoints() async {
    final root = _projectRoot;
    final c = _client;
    if (root == null || c == null) return null;
    final saved = store.load(root);
    if (saved.isEmpty) return null;
    var ok = 0;
    var failed = 0;
    for (final s in saved) {
      final path = breakpointPathOf(s.path,
              projectRoot: root, packageName: _packageName) ??
          BreakpointStore.absolutePathOf(root, s.path);
      // 同一位置已在（IDE 也设过 / 本会话已恢复）就跳过，避免重复条目。
      final dup = c.breakpoints.any((b) {
        if (b.line != s.line) return false;
        final p = b.scriptUri == null ? null : c.localPathOf(b.scriptUri!);
        return p != null && (p == path || p.endsWith('/${s.path}'));
      });
      if (dup) {
        ok++;
        continue;
      }
      try {
        final bp = await c.addBreakpoint(
          path: path,
          line: s.line,
          column: s.column,
          condition: s.condition,
          logMessage: s.logMessage,
        );
        if (!s.enabled) {
          try {
            await c.setBreakpointEnabled(bp.id, false);
          } catch (_) {
            // 停用失败不影响断点已建；状态行仍会写恢复成功。
          }
        }
        ok++;
      } catch (_) {
        // 行号被删 / 文件改名：跳过，保留记录（切回分支常又能用）。
        failed++;
      }
    }
    if (ok == 0 && failed == 0) return null;
    return '已恢复 $ok 个记住的断点'
        '${failed == 0 ? '' : '（$failed 个失败，代码可能已改）'}';
  }

  Future<void> _detachClient() async {
    final sub = _eventSub;
    _eventSub = null;
    await sub?.cancel();
    final c = _client;
    _client = null;
    if (c != null) {
      try {
        await c.close();
      } catch (_) {
        // 连接可能已断：关不掉也不影响后续重建。
      }
    }
  }

  DebugClient _requireClient() {
    final c = _client;
    if (c == null) {
      throw DebugException(
          '未连接调试会话：先点「启动」，或从会话列表接入一条 VM service 地址');
    }
    return c;
  }

  /// 「已记住的断点」归属的项目根：显式 dir > 当前会话的项目根。
  String? _savedRoot(Map<String, Object?> a) {
    final raw = _str(a['dir']) ?? _projectRoot;
    if (raw == null || raw.trim().isEmpty) return null;
    return BreakpointStore.normalizeRoot(raw);
  }

  /// 会话对应的 flutter run pid：优先内存句柄，其次按 VM 端口反查磁盘清单。
  int? _resolvePid(int? explicit) {
    if (explicit != null) return explicit;
    final h = _handle;
    if (h != null) return h.pid;
    final u = _wsUri;
    final port = u == null ? null : Uri.tryParse(u)?.port;
    if (port == null || port <= 0) return null;
    launcher.adoptRecords();
    return launcher.pidForPort(port);
  }

  List<Object?> _breakpointList() {
    final c = _client;
    if (c == null) return const <Object?>[];
    return <Object?>[
      for (final bp in c.breakpoints)
        debugBreakpointJson(
          bp,
          localPath: bp.scriptUri == null ? null : c.localPathOf(bp.scriptUri!),
        ),
    ];
  }

  /// 所有项目记住的断点（「已记住」总览）：当前项目排最前，其余按路径排序。
  Map<String, Object?> _savedAll() {
    final current = _projectRoot;
    final all = store.loadAll();
    final dirs = savedAllDirs(all.keys, current);
    return <String, Object?>{
      'current': current,
      'projects': <Object?>[
        for (final dir in dirs)
          <String, Object?>{
            'dir': dir,
            'current': dir == current,
            'items': <Object?>[
              for (final b in all[dir] ?? const <SavedBreakpoint>[])
                debugSavedBreakpointJson(dir, b),
            ],
          },
      ],
    };
  }

  String? _toLocal(String uri) {
    final c = _client;
    if (c != null) {
      final p = c.localPathOf(uri);
      if (p != null) return p;
    }
    return debugScriptUriToPath(uri,
        projectRoot: _projectRoot, packageName: _packageName);
  }

  void _onEvent(DebugEvent e) {
    if (e.kind == DebugEventKind.exit) {
      _message = '应用已退出';
    } else if (e.kind == DebugEventKind.disconnected) {
      _message = e.message ?? '调试连接已断开';
    } else if (e.kind == DebugEventKind.pause) {
      final line = e.pause?.line;
      final fn = e.pause?.topFrame?.function;
      _message = '已暂停${fn == null ? '' : '：$fn'}${line == null ? '' : '（第 $line 行）'}';
    } else if (e.kind == DebugEventKind.conditionMissed) {
      // 条件不命中不算用户可见的暂停，只在输出区留一行。
      _onOutput('[debug] 条件未命中，已自动继续：${e.condition ?? ''}');
    } else if (e.kind == DebugEventKind.logpointHit) {
      // 日志断点也不暂停，把求值结果按行写进输出区。
      for (final line in (e.message ?? '').split('\n')) {
        if (line.trim().isNotEmpty) _onOutput(line);
      }
    } else if (e.message != null) {
      _message = e.message;
    }
    push(<String, Object?>{
      'type': 'debug',
      'event': debugEventJson(e, toLocal: _toLocal),
      'state': status(),
    });
  }

  void _pushState() {
    push(<String, Object?>{'type': 'debugState', 'state': status()});
  }

  String _short(String? uri) {
    if (uri == null || uri.isEmpty) return '?';
    final p = _toLocal(uri) ?? uri;
    final root = _projectRoot;
    if (root != null && root.isNotEmpty && p.startsWith('$root/')) {
      return p.substring(root.length + 1);
    }
    return p;
  }

  // ---------------------------------------------------------------- 输出跟随

  void _startFollow(String path, {required bool fromStart}) {
    _stopFollow();
    if (path.isEmpty) return;
    final f = File(path);
    if (!f.existsSync()) return;
    _followPath = path;
    _followPending = '';
    _followOffset = fromStart ? 0 : f.lengthSync();
    if (!fromStart) _preloadTail(f);
    _followTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) => _pumpLog());
    if (fromStart) _pumpLog();
  }

  void _stopFollow() {
    _followTimer?.cancel();
    _followTimer = null;
    _followPath = null;
    _followOffset = 0;
    _followPending = '';
  }

  /// 复盘用：从日志尾部预读最近 200 行（接入复用会话时先有上下文）。
  void _preloadTail(File f) {
    try {
      final len = f.lengthSync();
      const window = 64 * 1024;
      final start = len > window ? len - window : 0;
      final raf = f.openSync();
      try {
        raf.setPositionSync(start);
        final text =
            utf8.decode(raf.readSync(len - start), allowMalformed: true);
        final lines = text.split('\n');
        if (lines.isNotEmpty) lines.removeLast();
        for (final line in lines) {
          _tail.add(line);
        }
        if (_tail.length > 300) {
          _tail.removeRange(0, _tail.length - 300);
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      // 读不到历史不影响后续增量。
    }
  }

  void _pumpLog() {
    final path = _followPath;
    if (path == null) return;
    final f = File(path);
    if (!f.existsSync()) return;
    try {
      final len = f.lengthSync();
      if (len < _followOffset) {
        _followOffset = 0; // 文件被截断 / 轮转
        _followPending = '';
      }
      if (len == _followOffset) return;
      final raf = f.openSync();
      try {
        raf.setPositionSync(_followOffset);
        final chunk =
            utf8.decode(raf.readSync(len - _followOffset), allowMalformed: true);
        _followOffset = len;
        _followPending += chunk;
        final parts = _followPending.split('\n');
        _followPending = parts.removeLast(); // 末尾可能是半行
        for (final line in parts) {
          _onOutput(line);
        }
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      // 日志暂时读不到（正在写入 / 被删）：下一轮再试。
    }
  }

  void _onOutput(String line) {
    _tail.add(line);
    if (_tail.length > 300) _tail.removeAt(0);
    _pendingOut.add(line);
    _flushTimer ??= Timer(const Duration(milliseconds: 120), _flushOut);
  }

  void _flushOut() {
    _flushTimer = null;
    if (_pendingOut.isEmpty) return;
    final lines = List<String>.of(_pendingOut);
    _pendingOut.clear();
    _outSeq += lines.length;
    push(<String, Object?>{
      'type': 'debugOutput',
      'lines': lines,
      'seq': _outSeq,
      'pid': _handle?.pid,
    });
  }
}
