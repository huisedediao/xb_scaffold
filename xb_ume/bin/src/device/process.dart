// 外部命令执行与可执行文件定位（设备层共用）。
//
// 设计约定：
//   - 只用 dart:io，不引入 shell 依赖；超时必须杀掉子进程，避免 MCP 工具
//     调用被 adb/hdc 无响应拖死；
//   - 失败不抛异常，统一回 [CmdResult]（code 非 0 / 超时 -1），
//     由各 Bridge 决定是「能力缺失」还是「命令报错」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../control/svc_control.dart' show bundledBinDir;
import 'bridge.dart';
import 'proxy_env.dart';

/// 一次命令执行结果。
class CmdResult {
  CmdResult(this.code, this.stdout, this.stderr, {this.timedOut = false});

  final int code;
  final String stdout;
  final String stderr;
  final bool timedOut;

  bool get ok => code == 0 && !timedOut;

  /// 错误摘要（命令失败时用于拼提示）。
  String get errorText {
    if (timedOut) return '命令超时';
    final e = stderr.trim();
    if (e.isNotEmpty) return e;
    final o = stdout.trim();
    return o.isNotEmpty ? o : '退出码 $code';
  }

  @override
  String toString() => 'CmdResult(code=$code, out=${stdout.length}B)';
}

/// Windows 上 `.bat` / `.cmd`（flutter.bat、npx.cmd 等）必须经 cmd 执行：
/// CreateProcess 不能直接跑批处理。其他可执行文件保持直启，避免多一层 shell
/// 把带空格/特殊字符的参数再拆一遍。
bool needsShellOnWindows(String exe) {
  if (!Platform.isWindows) return false;
  final lower = exe.toLowerCase();
  return lower.endsWith('.bat') || lower.endsWith('.cmd');
}

/// 执行命令；超时自动 kill，返回 code=-1。
Future<CmdResult> runCmd(
  String exe,
  List<String> args, {
  Duration timeout = const Duration(seconds: 20),
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  Process proc;
  try {
    proc = await Process.start(
      exe,
      args,
      workingDirectory: workingDirectory,
      environment: execEnvironment(environment),
      runInShell: needsShellOnWindows(exe),
    );
  } on ProcessException catch (e) {
    return CmdResult(127, '', '${e.message}${e.errorCode == 0 ? '' : '(${e.errorCode})'}');
  }
  final out = StringBuffer();
  final err = StringBuffer();
  final done = Completer<void>();
  // 输出流各自的完成信号：进程退出不等于管道已读完（高负载下最后几行
  // 还在事件队列里，直接 cancel 会把它们丢掉，如 `echo one` 读成空串）。
  final outDone = Completer<void>();
  final errDone = Completer<void>();
  void finish(Completer<void> c) {
    if (!c.isCompleted) c.complete();
  }

  final subOut = proc.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((String line) => out.writeln(line),
          onError: (_) => finish(outDone), onDone: () => finish(outDone));
  final subErr = proc.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((String line) => err.writeln(line),
          onError: (_) => finish(errDone), onDone: () => finish(errDone));
  unawaited(proc.exitCode.then((_) {
    if (!done.isCompleted) done.complete();
  }));
  var timedOut = false;
  try {
    await done.future.timeout(timeout);
  } on TimeoutException {
    timedOut = true;
    proc.kill(ProcessSignal.sigkill);
  }
  // 先等两个输出流读完（最多 2 秒）：子进程把管道留给孙进程时流不会关，
  // 这时不再等，直接取消。
  try {
    await Future.wait(<Future<void>>[outDone.future, errDone.future])
        .timeout(const Duration(seconds: 2));
  } on TimeoutException {
    // 有残留孙进程握着管道：不阻塞调用方，拿到已收到的部分。
  }
  await subOut.cancel();
  await subErr.cancel();
  final code = timedOut ? -1 : await proc.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
  return CmdResult(code, out.toString(), err.toString(), timedOut: timedOut);
}

String? _envOf(String key) {
  final v = Platform.environment[key];
  if (v == null || v.trim().isEmpty) return null;
  return v.trim();
}

List<String>? _fallbackDirsCache;

/// 兜底搜索目录（只回本机真实存在的，PATH 仍然优先）。
///
/// GUI 与 daemon 常由 Finder、launchd 或 IDE 的图形界面拉起，PATH 往往只有
/// `/usr/bin:/bin:/usr/sbin:/sbin`：这时 flutter / adb / hdc 全都定位不到，
/// 用户看到的就是「未找到 flutter 可执行文件（检查 PATH）」。这里按
/// 「能自证的位置优先」补齐：当前进程的 dart 所在的 SDK → 环境变量声明的
/// SDK → 常见安装位置。
List<String> fallbackBinDirs() {
  final cached = _fallbackDirsCache;
  if (cached != null) return cached;
  final dirs = <String>[];
  final seen = <String>{};
  void add(String? dir) {
    final t = dir?.trim();
    if (t == null || t.isEmpty) return;
    final norm = (t.length > 1 && (t.endsWith('/') || t.endsWith(r'\')))
        ? t.substring(0, t.length - 1)
        : t;
    if (!seen.add(norm)) return;
    if (Directory(norm).existsSync()) dirs.add(norm);
  }

  final home = _envOf('HOME') ?? _envOf('USERPROFILE');
  final sep = Platform.pathSeparator;

  // 1) flutter SDK：GUI/daemon 自己就是被 SDK 里的 dart 拉起来的，这是最可靠
  //    的自证信号；其次是 FLUTTER_ROOT 与常见安装位置。
  var probe = File(Platform.resolvedExecutable).parent;
  // Windows 的 flutter 是 flutter.bat（没有无后缀的可执行体）。
  final flutterNames = Platform.isWindows
      ? <String>['flutter.bat', 'flutter']
      : <String>['flutter'];
  for (var i = 0; i < 6; i++) {
    final binDir = '${probe.path}${sep}bin';
    if (flutterNames.any((n) => File('$binDir$sep$n').existsSync())) {
      add(binDir);
      break;
    }
    final parent = probe.parent;
    if (parent.path == probe.path) break;
    probe = parent;
  }
  final flutterRoot = _envOf('FLUTTER_ROOT');
  if (flutterRoot != null) add('$flutterRoot${sep}bin');
  if (home != null) {
    add('$home/flutter/bin');
    add('$home/development/flutter/bin');
    add('$home/fvm/default/bin');
    add('$home/.pub-cache/bin');
    add('$home/.local/bin');
  }
  if (!Platform.isWindows) {
    add('/opt/homebrew/bin');
    add('/usr/local/bin');
  }

  // 2) Android platform-tools。Windows 默认在 %LOCALAPPDATA%\Android\Sdk，
  //    macOS 在 ~/Library/Android/sdk。
  final localAppData =
      _envOf('LOCALAPPDATA') ?? (home == null ? null : '$home/AppData/Local');
  final androidSdks = <String?>[
    _envOf('ANDROID_HOME'),
    _envOf('ANDROID_SDK_ROOT'),
    if (home != null) '$home/Library/Android/sdk',
    if (localAppData != null) '$localAppData/Android/Sdk',
  ];
  for (final sdk in androidSdks) {
    if (sdk != null) add('$sdk/platform-tools');
  }

  // 3) DevEco：hdc 在各 SDK 版本的 toolchains 下（version 目录要先列举）。
  //    默认安装位置：macOS /Applications/DevEco-Studio.app/Contents/sdk
  //                 Windows C:\Program Files\Huawei\DevEco Studio\sdk
  const devecoMac = '/Applications/DevEco-Studio.app/Contents/sdk';
  const devecoWin = r'C:\Program Files\Huawei\DevEco Studio\sdk';
  final deveco = _envOf('DEVECO_SDK_HOME') ??
      (Platform.isWindows ? devecoWin : devecoMac);
  final sdkDir = Directory(deveco);
  if (sdkDir.existsSync()) {
    for (final e in sdkDir.listSync(followLinks: false)) {
      if (e is Directory) add('${e.path}${sep}openharmony${sep}toolchains');
    }
  }
  add('$deveco/openharmony/toolchains');
  // node / ohpm / hvigor 在 SDK 上一级目录的 tools 下（mac 与 Windows 同一布局）。
  final devecoRoot = File(deveco).parent.path;
  for (final tool in <String>['node', 'ohpm', 'hvigor']) {
    add('$devecoRoot/tools/$tool/bin');
  }

  _fallbackDirsCache = dirs;
  return dirs;
}

/// 子进程用的 PATH：内嵌工具目录 + 原 PATH + [fallbackBinDirs]，去重保序。
String execSearchPath() {
  final sep = Platform.isWindows ? ';' : ':';
  final out = <String>{};
  out.addAll(preferredBinDirs());
  for (final dir in (Platform.environment['PATH'] ?? '').split(sep)) {
    if (dir.trim().isNotEmpty) out.add(dir.trim());
  }
  out.addAll(fallbackBinDirs());
  return out.join(sep);
}

/// 子进程完整环境：默认继承本进程环境，只把 PATH 换成 [execSearchPath]。
///
/// `Process.start` 的 environment 是「整体替换」而非合并，所以必须带上
/// 完整环境；补 PATH 是为了让 flutter run 这类子进程自己也能找到 adb / hdc。
Map<String, String> execEnvironment([Map<String, String>? extra]) {
  final map = <String, String>{...Platform.environment};
  map.removeWhere((k, _) => k.toUpperCase() == 'PATH');
  map['PATH'] = execSearchPath();
  if (extra != null) map.addAll(extra);
  // 子进程（flutter run 等）连本机 VM Service 也是回环：即使本进程继承了
  // http_proxy，也要让回环绕过代理。放在 extra 之后，配置里的 no_proxy 只会
  // 被补充、不会被丢掉回环地址。
  return withLoopbackNoProxy(map);
}

/// 定位也可显式指定：`XB_UME_FLUTTER` 给 flutter 可执行文件或 SDK 根目录。
String? resolveFlutter() {
  final explicit = _envOf('XB_UME_FLUTTER');
  if (explicit != null) {
    if (File(explicit).existsSync()) return explicit;
    final inner =
        '$explicit${Platform.pathSeparator}bin${Platform.pathSeparator}flutter';
    if (File(inner).existsSync()) return inner;
  }
  return findExecutable('flutter');
}

/// 分发版自带的工具目录（adb / hdc / iproxy），排在 PATH 之前。
///
/// 测试人员机器上的 adb / hdc 版本不可控（有的根本没装），内嵌那一份才是
/// 我们验证过的；源码部署没有这个目录，行为不变。
List<String> preferredBinDirs() {
  final dir = bundledBinDir();
  return dir == null ? const <String>[] : <String>[dir];
}

/// 在 PATH 中定位可执行文件，找不到再走 [fallbackBinDirs]；都没有返回 null
/// （不调用 which，跨平台一致）。
String? findExecutable(String name) {
  if (name.contains('/') || name.contains(r'\')) {
    return File(name).existsSync() ? name : null;
  }
  final path = Platform.environment['PATH'] ?? '';
  final sep = Platform.isWindows ? ';' : ':';
  final exts = Platform.isWindows
      ? <String>['.exe', '.bat', '.cmd', '']
      : <String>[''];
  final dirs = <String>[
    ...preferredBinDirs(),
    ...path.split(sep).where((d) => d.trim().isNotEmpty),
    ...fallbackBinDirs(),
  ];
  for (final dir in dirs) {
    for (final ext in exts) {
      final f = File('$dir${Platform.pathSeparator}$name$ext');
      if (f.existsSync()) return f.path;
    }
  }
  return null;
}

/// 把命令行结果压成一行（日志/错误提示用）。
String oneLine(String s, {int max = 200}) {
  final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length <= max ? t : '${t.substring(0, max)}…';
}

/// 命令必须成功，否则抛 [DeviceCommandError]（由各 Bridge 调用）。
void requireOk(CmdResult r, String backend, String command) {
  if (r.ok) return;
  throw DeviceCommandError(backend, command, oneLine(r.errorText));
}
