// 服务控制：GUI 与守护进程的启停 / 重启 / 重新部署。
//
// 三处共用同一份实现：
//   1. GUI「服务」菜单 —— bin/ide_gui.dart 的 /api/svc/* 路由；
//   2. 命令行 —— bin/ide.dart 的 --svc / --ensure-daemon；
//   3. 工具箱启动脚本 —— 先 --ensure-daemon 再起 GUI。
// 本文件随 bin/src 树一起复制到 ~/.xb_ume_ide/src/control/，部署副本里的
// GUI 与 ide.dart 都能 import，避免两边各写一套进程管理（历史上已经因为
// 「kill -9 + detached 启动」和 LaunchAgent 的 KeepAlive 抢过实例）。
//
// 平台差异：
//   macOS  daemon 由 LaunchAgent（RunAtLoad + KeepAlive）托管：停止必须先
//          bootout（plist 保留，随时可再 bootstrap），重启用 kickstart -k
//          一步完成；直接 kill 会被 launchd 立刻复活。
//   其他    没有 KeepAlive 等价物，按命令行精确匹配结束进程后 detached 启动。
//   GUI    两端一致：GUI 没有进程守护者，重启只能由旧实例先 detach 一个
//          「接班人」（带 --restart-owner / --port），再优雅退出让出端口。
//
// 安全约束：所有进程匹配都先 ps 复核完整命令行，且只针对
// `~/.xb_ume_ide/ide.dart --daemon` / `ide_gui.dart`，绝不宽泛 pkill。

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// 与 bin/ide.dart、bin/ide_gui.dart 双端约定的常量
// ---------------------------------------------------------------------------

/// LaunchAgent 标签（与 bin/ide.dart 的 kLabel 一致）。
const String kDaemonLabel = 'com.xbume.ide';

/// LaunchAgent plist 文件名。
const String kDaemonPlistName = '$kDaemonLabel.plist';

/// daemon 单实例互斥端口与 status 协议令牌（双端约定一致）。
const int kDaemonLockPort = 46128;
const String kDaemonStatusToken = 'xbume-ide-status';

/// GUI 服务端口基数（被占用时向后顺延最多 10 个）。
const int kGuiPortBase = 46129;

/// 安装目录名。
const String kSvcInstallDirName = '.xb_ume_ide';

// ---------------------------------------------------------------------------
// 打包分发版（.app / 安装器）
// ---------------------------------------------------------------------------
//
// 分发版把各个入口分别 AOT 编译成同目录的兄弟可执行文件（xbume-ide /
// xbume-gui / xbume-mcp / xbume-hotkey），源目录部署（~/.xb_ume_ide）里没有
// 这些二进制。判定不看环境变量：Finder 双击拿不到启动器设的 env，而
// 「兄弟可执行文件就在旁边」是分发目录结构的自证事实，源码部署自然落回
// 原有分支。

const String kBundledIdeExe = 'xbume-ide';
const String kBundledGuiExe = 'xbume-gui';
const String kBundledMcpExe = 'xbume-mcp';
const String kBundledHotkeyExe = 'xbume-hotkey';

String _exeName(String name) => Platform.isWindows ? '$name.exe' : name;

/// 本进程可执行文件所在目录（打包版即 `XbUme.app/Contents/MacOS`）。
String bundledExeDir() => File(Platform.resolvedExecutable).parent.path;

/// 与自身同目录的兄弟可执行文件；不存在返回 null。
String? bundledExe(String name) {
  final f = File('${bundledExeDir()}$_sep${_exeName(name)}');
  return f.existsSync() ? f.path : null;
}

/// 是否打包分发版。
bool isBundledBuild() => bundledExe(kBundledGuiExe) != null;

/// 分发版自带的工具目录（adb / hdc / iproxy 及其 dylib）。
///
/// macOS: `Contents/Resources/bin`；Windows: 安装目录下的 `tools`。
/// 不为分发版或目录不存在时返回 null（回落到 PATH 与常见安装位置）。
String? bundledBinDir() {
  if (!isBundledBuild()) return null;
  final dir = bundledExeDir();
  final candidates = Platform.isWindows
      ? <String>['$dir${_sep}tools', '$dir$_sep..${_sep}tools']
      : <String>['$dir$_sep..${_sep}Resources${_sep}bin'];
  for (final c in candidates) {
    if (Directory(c).existsSync()) return c;
  }
  return null;
}

/// 部署不完整时的修复提示：源码部署要重跑 --install，分发版重装应用。
String installHint() => isBundledBuild()
    ? '请重新安装 XbUme 应用'
    : '请重新执行 dart run xb_ume:ide --install';

// ---------------------------------------------------------------------------
// 路径
// ---------------------------------------------------------------------------

/// 用户主目录：Windows 用 USERPROFILE（HOME 通常不存在），其余用 HOME。
String svcHome() =>
    Platform.environment['USERPROFILE'] ??
    Platform.environment['HOME'] ??
    '.';

/// 数据目录：`XB_UME_HOME` 可覆盖（多实例 / 隔离验证），否则 `~/.xb_ume_ide`。
///
/// 必须与 `bin/src/paths.dart` 的 `xbUmeHome()` 口径一致：GUI 与 MCP 进程
/// 各写一份 token 到同一目录，两边才能互相握手。
String svcDataDir() {
  final override = Platform.environment['XB_UME_HOME']?.trim();
  if (override != null && override.isNotEmpty) return override;
  return '${svcHome()}$_sep$kSvcInstallDirName';
}

/// 部署目录（`~/.xb_ume_ide`）。
String svcInstallDir() => svcDataDir();

/// 部署副本里的守护脚本。
String daemonScriptPath() => '${svcInstallDir()}${_sep}ide.dart';

/// 部署副本里的 GUI 脚本。
String guiScriptPath() => '${svcInstallDir()}${_sep}ide_gui.dart';

/// LaunchAgent plist 路径（macOS）。
String daemonPlistPath() =>
    '${svcHome()}${_sep}Library${_sep}LaunchAgents$_sep$kDaemonPlistName';

/// daemon 日志（LaunchAgent 的 StandardOutPath）。
String daemonLogPath() =>
    '${svcHome()}${_sep}Library${_sep}Logs${_sep}xb_ume_ide.log';

/// 「重新部署」的输出日志。
String installLogPath() => '${svcInstallDir()}${_sep}install.log';

/// GUI 访问令牌文件（本地脚本 / CLI 调 /api/svc/* 用）。
String guiTokenPath() => '${svcInstallDir()}${_sep}gui.token';

/// 安装配置（IDE 优先级、sourceRoot、MCP 自启等）。
String svcConfigPath() => '${svcInstallDir()}${_sep}config.json';

String get _sep => Platform.pathSeparator;

// ---------------------------------------------------------------------------
// 纯函数（便于单测；不含任何进程/网络副作用）
// ---------------------------------------------------------------------------

/// 归一动作目标：gui / daemon / all；非法值返回 null。
String? normalizeSvcTarget(String? raw) {
  final t = (raw ?? '').trim().toLowerCase();
  if (t == 'gui' || t == 'daemon' || t == 'all') return t;
  return null;
}

/// 执行顺序：daemon 先于 GUI。
///
/// 重启全部时必须先把 daemon 拉起来并确认就绪，再切 GUI；反过来会出现
/// 新 GUI 起来后短暂读到「守护进程未运行」的空窗。
List<String> svcActionOrder(String target) {
  switch (target) {
    case 'gui':
      return const <String>['gui'];
    case 'daemon':
      return const <String>['daemon'];
    case 'all':
      return const <String>['daemon', 'gui'];
    default:
      return const <String>[];
  }
}

/// `launchctl kickstart -k gui/<uid>/<label>`：原地重启 LaunchAgent。
List<String> launchdKickstartArgs(String uid, [String label = kDaemonLabel]) =>
    <String>['kickstart', '-k', 'gui/$uid/$label'];

/// `launchctl bootstrap gui/<uid> <plist>`：注册并立即启动。
List<String> launchdBootstrapArgs(String uid, String plistPath) =>
    <String>['bootstrap', 'gui/$uid', plistPath];

/// `launchctl bootout gui/<uid> <plist>`：卸载本次登录的注册（plist 保留）。
///
/// KeepAlive 下这是唯一能真正停住 daemon 的方式；下次 bootstrap 即可恢复。
List<String> launchdBootoutArgs(String uid, String plistPath) =>
    <String>['bootout', 'gui/$uid', plistPath];

/// GUI 接班人的完整参数（不含 dart 可执行文件）。
///
/// [ownerPid] 让新实例先等旧实例彻底退出（释放端口、写完 token）再 bind；
/// [port] 固定端口，避免顺延后浏览器地址失效。
List<String> guiSuccessorArgs({
  required String script,
  required int ownerPid,
  required int port,
}) =>
    <String>[script, '--restart-owner', '$ownerPid', '--port', '$port'];

/// 等旧进程退出后执行 `--install` 的 shell 脚本（macOS / Linux）。
///
/// 部署器必须是「等 GUI 退出」而不是直接跑 install：install 内部的
/// _killGuiProcesses 是 kill -9，会在 GUI 持有 VM 会话时留下 DDS 死锁。
String redeployShellCommand({
  required int waitPid,
  required String dartBin,
  required String installScript,
  required String logPath,
}) =>
    'while kill -0 $waitPid 2>/dev/null; do sleep 0.2; done; '
    'exec "$dartBin" "$installScript" --install >> "$logPath" 2>&1';

/// 同上，Windows PowerShell 版本。
String redeployPowerShellCommand({
  required int waitPid,
  required String dartBin,
  required String installScript,
  required String logPath,
}) =>
    'Start-Sleep -Milliseconds 300; '
    'while (Get-Process -Id $waitPid -ErrorAction SilentlyContinue) '
    '{ Start-Sleep -Milliseconds 200 }; '
    '& "$dartBin" "$installScript" --install *>> "$logPath"';

/// 从 config.json 文本里取 `sourceRoot`（源码目录）；无/非法返回 null。
String? sourceRootFromConfig(String? configText) {
  if (configText == null || configText.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(configText);
    if (decoded is! Map) return null;
    final root = decoded['sourceRoot']?.toString().trim();
    if (root == null || root.isEmpty) return null;
    return root;
  } catch (_) {
    return null;
  }
}

/// 取日志尾部（部署失败时页面要能看到最后几行原因）。
String installLogTail(String content, {int maxLines = 30}) {
  if (content.isEmpty || maxLines <= 0) return '';
  final lines = const LineSplitter().convert(content);
  if (lines.length <= maxLines) return lines.join('\n');
  return lines.sublist(lines.length - maxLines).join('\n');
}

/// 部署副本是否完整：`import 'src/...'` 的相对依赖都得在安装目录里。
///
/// 升级后源码新增模块但没重新部署时，dart 会直接编译失败、进程秒退，
/// 页面只看到「守护进程未运行」；这里提前把缺失文件点出来。
List<String> missingDaemonDeps({String? scriptPath}) {
  // 分发版是单文件可执行，没有 `import 'src/...'` 需要核对。
  if (isBundledBuild()) return const <String>[];
  final script = File(scriptPath ?? daemonScriptPath());
  if (!script.existsSync()) {
    return <String>['ide.dart'];
  }
  final missing = <String>[];
  try {
    final re = RegExp(r'''^import\s+'(src/[^']+)';''', multiLine: true);
    final dir = script.parent.path;
    for (final m in re.allMatches(script.readAsStringSync())) {
      final rel = m.group(1)!;
      final f = File('$dir$_sep${rel.replaceAll('/', _sep)}');
      if (!f.existsSync()) missing.add(rel);
    }
  } catch (_) {
    // 读不了就不拦：让启动流程自己暴露真实错误。
  }
  return missing;
}

// ---------------------------------------------------------------------------
// 进程与端口探测
// ---------------------------------------------------------------------------

/// daemon 状态（经互斥端口 status 协议）；未运行返回 null。
Future<Map<String, Object?>?> queryDaemonStatus({
  Duration timeout = const Duration(milliseconds: 800),
}) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      kDaemonLockPort,
      timeout: timeout,
    );
    final completer = Completer<Map<String, Object?>?>();
    late StreamSubscription<List<int>> sub;
    sub = socket.listen((data) {
      if (!completer.isCompleted) {
        completer.complete(_decodeStatus(data));
      }
      unawaited(sub.cancel());
    }, onDone: () {
      if (!completer.isCompleted) completer.complete(null);
    }, onError: (dynamic _) {
      if (!completer.isCompleted) completer.complete(null);
    });
    socket.write(kDaemonStatusToken);
    await socket.flush();
    return await completer.future.timeout(
      timeout + const Duration(milliseconds: 200),
      onTimeout: () => null,
    );
  } catch (_) {
    return null;
  } finally {
    try {
      socket?.destroy();
    } catch (_) {}
  }
}

Map<String, Object?>? _decodeStatus(List<int> data) {
  try {
    final decoded = jsonDecode(utf8.decode(data, allowMalformed: true));
    if (decoded is! Map) return null;
    return <String, Object?>{
      for (final e in decoded.entries) e.key.toString(): e.value,
    };
  } catch (_) {
    return null;
  }
}

/// GUI 是否在该端口应答（/ping 在令牌校验之前）。
Future<bool> pingGui(int port, {Duration timeout = const Duration(seconds: 1)}) async {
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(milliseconds: 500);
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port/ping'))
        .timeout(timeout);
    final response = await request.close().timeout(timeout);
    final body = await response
        .transform(const Utf8Codec(allowMalformed: true).decoder)
        .join()
        .timeout(timeout);
    return body.trim() == 'xbume-gui';
  } catch (_) {
    return false;
  } finally {
    client?.close(force: true);
  }
}

/// 探测正在运行的 GUI 端口（46129 起 10 个）；没有返回 null。
Future<int?> discoverGuiPort() async {
  for (var i = 0; i < 10; i++) {
    final port = kGuiPortBase + i;
    if (await pingGui(port)) return port;
  }
  return null;
}

Future<String> currentUid() async {
  try {
    final r = await Process.run('id', <String>['-u']);
    return r.stdout.toString().trim();
  } catch (_) {
    return '';
  }
}

// ---------------------------------------------------------------------------
// daemon：启动 / 停止 / 重启
// ---------------------------------------------------------------------------

/// 结束本机所有部署目录下的 `ide.dart --daemon` 进程（排除 [excludePid]）。
///
/// 只用于 launchd 不可用时的兜底，以及 Windows 的停止路径；每杀一个都先
/// ps 复核命令行，避免误伤本机其他带 ide.dart 字样的调试进程。
Future<int> killDaemonProcesses({int? excludePid}) async {
  final self = excludePid ?? pid;
  var killed = 0;
  try {
    if (Platform.isWindows) {
      final ps = "Get-CimInstance Win32_Process | Where-Object { "
          "\$_.CommandLine -match 'ide\\.dart' -and "
          "\$_.CommandLine -match '--daemon' -and \$_.ProcessId -ne $self } | "
          "ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }";
      await Process.run('powershell', <String>['-NoProfile', '-Command', ps]);
      return 1;
    }
    final targets = <int>{};
    final status = await queryDaemonStatus();
    final statusPid = int.tryParse('${status?['pid'] ?? ''}');
    if (statusPid != null && statusPid > 0 && statusPid != self) {
      targets.add(statusPid);
    }
    final pgrep = await Process.run('pgrep', <String>['-f', r'ide\.dart.*--daemon']);
    for (final line in pgrep.stdout.toString().split('\n')) {
      final other = int.tryParse(line.trim());
      if (other == null || other == self || targets.contains(other)) continue;
      final ps = await Process.run('ps', <String>['-p', '$other', '-o', 'command=']);
      final cmdline = ps.stdout.toString().trim();
      if (!cmdline.contains('${svcInstallDir()}${_sep}ide.dart')) continue;
      if (!cmdline.contains('--daemon')) continue;
      targets.add(other);
    }
    for (final target in targets) {
      final r = await Process.run('kill', <String>['-9', '$target']);
      if (r.exitCode == 0) killed++;
    }
  } catch (_) {
    // 清理失败不阻塞调用方。
  }
  return killed;
}

Future<bool> _waitDaemonUp(Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (await queryDaemonStatus() != null) return true;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return false;
}

Future<bool> _waitDaemonDown(Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (await queryDaemonStatus() == null) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return false;
}

Future<ProcessResult?> _run(String cmd, List<String> args) async {
  try {
    return await Process.run(cmd, args);
  } catch (_) {
    return null;
  }
}

/// detached 启动部署副本的 daemon（launchd 不可用时的兜底）。
Future<void> _spawnDaemonDetached() async {
  final exe = bundledExe(kBundledIdeExe);
  if (exe != null) {
    await Process.start(
      exe,
      <String>['--daemon'],
      mode: ProcessStartMode.detached,
      workingDirectory: bundledExeDir(),
    );
    return;
  }
  await Process.start(
    Platform.resolvedExecutable,
    <String>[daemonScriptPath(), '--daemon'],
    mode: ProcessStartMode.detached,
    workingDirectory: svcInstallDir(),
  );
}

/// 启动 daemon：已运行则直接返回；macOS 优先 launchd，其余 detached。
Future<Map<String, Object?>> startDaemon() async {
  final running = await queryDaemonStatus();
  if (running != null) {
    return <String, Object?>{
      'ok': true,
      'message': '守护进程已在运行（pid=${running['pid']}）',
    };
  }
  final missing = missingDaemonDeps();
  if (missing.isNotEmpty) {
    return <String, Object?>{
      'ok': false,
      'message': '守护脚本缺少依赖 ${missing.join('、')}（部署不完整）：'
          '${installHint()}',
    };
  }
  // 分发版不注册 LaunchAgent（不在测试人员机器上留开机自启），直接 detach。
  if (Platform.isMacOS && !isBundledBuild()) {
    final uid = await currentUid();
    final plist = daemonPlistPath();
    if (uid.isNotEmpty && File(plist).existsSync()) {
      var r = await _run('launchctl', launchdBootstrapArgs(uid, plist));
      if (r == null || r.exitCode != 0) {
        r = await _run('launchctl', <String>['load', '-w', plist]);
      }
      if (await _waitDaemonUp(const Duration(seconds: 5))) {
        return <String, Object?>{'ok': true, 'message': '守护进程已启动'};
      }
    }
  }
  try {
    await _spawnDaemonDetached();
  } catch (e) {
    return <String, Object?>{'ok': false, 'message': '启动失败: $e'};
  }
  if (await _waitDaemonUp(const Duration(seconds: 5))) {
    return <String, Object?>{'ok': true, 'message': '守护进程已启动'};
  }
  return <String, Object?>{
    'ok': false,
    'message': '启动后未检测到 daemon（可查看 ${daemonLogPath()}）',
  };
}

/// 停止 daemon。
///
/// macOS 必须 bootout：KeepAlive 会把被 kill 的实例立刻拉回来，表现为
/// 「点了停止却还在跑」。bootout 只卸载本次登录的注册，plist 保留，
/// 之后 startDaemon 能再 bootstrap 起来。
Future<Map<String, Object?>> stopDaemon() async {
  final before = await queryDaemonStatus();
  if (before == null) {
    return <String, Object?>{'ok': true, 'message': '守护进程未在运行'};
  }
  var bootedOut = false;
  if (Platform.isMacOS) {
    final uid = await currentUid();
    final plist = daemonPlistPath();
    if (uid.isNotEmpty && File(plist).existsSync()) {
      final r = await _run('launchctl', launchdBootoutArgs(uid, plist));
      bootedOut = r != null && r.exitCode == 0;
    }
  }
  if (!bootedOut) {
    await killDaemonProcesses();
  }
  final gone = await _waitDaemonDown(const Duration(seconds: 4));
  if (!gone) {
    await killDaemonProcesses();
  }
  final ok = gone || await _waitDaemonDown(const Duration(seconds: 2));
  return <String, Object?>{
    'ok': ok,
    'message': ok
        ? '守护进程已停止${bootedOut ? '（已从 launchd 卸载，可随时重新开启）' : ''}'
        : '守护进程仍在运行（可能有权限更高的实例，请用 launchctl 检查）',
  };
}

/// 重启 daemon：macOS 优先 kickstart -k（不产生双实例空窗），其余杀后启。
Future<Map<String, Object?>> restartDaemon() async {
  if (Platform.isMacOS) {
    final uid = await currentUid();
    if (uid.isNotEmpty) {
      final r = await _run('launchctl', launchdKickstartArgs(uid));
      if (r != null && r.exitCode == 0) {
        if (await _waitDaemonUp(const Duration(seconds: 6))) {
          return <String, Object?>{'ok': true, 'message': '守护进程已重启'};
        }
      }
    }
  }
  await killDaemonProcesses();
  await _waitDaemonDown(const Duration(seconds: 3));
  final started = await startDaemon();
  if (started['ok'] == true) {
    return <String, Object?>{'ok': true, 'message': '守护进程已重启'};
  }
  return started;
}

// ---------------------------------------------------------------------------
// GUI：接班人 / 直接启动 / HTTP 调用
// ---------------------------------------------------------------------------

/// detach 一个 GUI 接班人：等 [ownerPid] 退出后按固定 [port] 启动。
///
/// 由 GUI 自己在退出前调用；新实例带 `--restart-owner`，会跳过「已有实例
/// 就打开浏览器退出」的分支，改为等旧进程彻底退出再 bind。
Future<Map<String, Object?>> spawnGuiSuccessor({
  required int ownerPid,
  required int port,
  String? script,
}) async {
  // 分发版：GUI 是旁边的 xbume-gui，接班人只需重启自己（不带脚本参数）。
  final bundled = bundledExe(kBundledGuiExe);
  if (bundled != null) {
    try {
      await Process.start(
        bundled,
        <String>['--restart-owner', '$ownerPid', '--port', '$port'],
        mode: ProcessStartMode.detached,
        workingDirectory: bundledExeDir(),
      );
    } catch (e) {
      return <String, Object?>{'ok': false, 'message': '接班人启动失败: $e'};
    }
    return <String, Object?>{
      'ok': true,
      'message': 'GUI 正在重启（新实例等旧进程退出后接管端口 $port）',
    };
  }
  final gui = script ?? guiScriptPath();
  if (!File(gui).existsSync()) {
    return <String, Object?>{
      'ok': false,
      'message': '未找到 $gui，${installHint()}',
    };
  }
  try {
    await Process.start(
      Platform.resolvedExecutable,
      guiSuccessorArgs(script: gui, ownerPid: ownerPid, port: port),
      mode: ProcessStartMode.detached,
      workingDirectory: svcInstallDir(),
    );
  } catch (e) {
    return <String, Object?>{'ok': false, 'message': '接班人启动失败: $e'};
  }
  return <String, Object?>{
    'ok': true,
    'message': 'GUI 正在重启（新实例等旧进程退出后接管端口 $port）',
  };
}

/// 用系统默认浏览器打开 GUI 页面（分发版双击后的「看到界面」）。
///
/// `XBUME_NO_OPEN=1` 可关闭（自动化验证 / 无头环境）。
Future<void> openGuiUrl(int port) async {
  if ((Platform.environment['XBUME_NO_OPEN'] ?? '') == '1') return;
  final url = 'http://127.0.0.1:$port';
  try {
    if (Platform.isMacOS) {
      await Process.start('open', <String>[url]);
    } else if (Platform.isWindows) {
      await Process.start('cmd', <String>['/c', 'start', '', url]);
    } else {
      await Process.start('xdg-open', <String>[url]);
    }
  } catch (_) {
    // 打不开浏览器不影响服务（用户可手动访问）。
  }
}

/// 直接起一个 GUI（CLI `--svc start gui` 用；已在运行则只打开浏览器）。
Future<Map<String, Object?>> spawnGuiDetached() async {
  final port = await discoverGuiPort();
  if (port != null) {
    // 已在跑：直接打开页面（双击 app 的期望就是「看到界面」）。
    await openGuiUrl(port);
    return <String, Object?>{'ok': true, 'message': 'GUI 已在 $port 运行'};
  }
  final bundled = bundledExe(kBundledGuiExe);
  if (bundled != null) {
    try {
      await Process.start(
        bundled,
        const <String>[],
        mode: ProcessStartMode.detached,
        workingDirectory: bundledExeDir(),
      );
    } catch (e) {
      return <String, Object?>{'ok': false, 'message': '启动失败: $e'};
    }
    return <String, Object?>{'ok': true, 'message': 'GUI 正在启动'};
  }
  final gui = guiScriptPath();
  if (!File(gui).existsSync()) {
    return <String, Object?>{
      'ok': false,
      'message': '未找到 $gui，${installHint()}',
    };
  }
  try {
    await Process.start(
      Platform.resolvedExecutable,
      <String>[gui],
      mode: ProcessStartMode.detached,
      workingDirectory: svcInstallDir(),
    );
  } catch (e) {
    return <String, Object?>{'ok': false, 'message': '启动失败: $e'};
  }
  return <String, Object?>{'ok': true, 'message': 'GUI 正在启动'};
}

/// 用本地令牌调用 GUI 的 /api/svc/<action>（命令行入口用）。
///
/// GUI 停止 / 重启的优雅退出逻辑（关 VM 会话、防 DDS 死锁）只能在 GUI
/// 进程内执行，所以 CLI 不自己 kill，而是让它自己收尾。
Future<Map<String, Object?>> callGuiSvc(
  String action, {
  String target = 'gui',
  Duration timeout = const Duration(seconds: 10),
}) async {
  final port = await discoverGuiPort();
  if (port == null) {
    return <String, Object?>{'ok': false, 'message': 'GUI 未在运行'};
  }
  String token = '';
  try {
    token = File(guiTokenPath()).readAsStringSync().trim();
  } catch (_) {
    return <String, Object?>{
      'ok': false,
      'message': '读不到访问令牌 ${guiTokenPath()}（GUI 可能刚启动）',
    };
  }
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/api/svc/$action?target=$target'),
    );
    req.headers.set('X-XBUME-Token', token);
    req.headers.contentLength = 0;
    final resp = await req.close().timeout(timeout);
    final body = await resp
        .transform(const Utf8Codec(allowMalformed: true).decoder)
        .join()
        .timeout(timeout);
    if (resp.statusCode != 200) {
      return <String, Object?>{
        'ok': false,
        'message': 'GUI 返回 ${resp.statusCode}: ${installLogTail(body, maxLines: 3)}',
      };
    }
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      return <String, Object?>{
        for (final e in decoded.entries) e.key.toString(): e.value,
      };
    }
    return <String, Object?>{'ok': false, 'message': 'GUI 返回格式异常'};
  } catch (e) {
    return <String, Object?>{'ok': false, 'message': '调用 GUI 失败: $e'};
  } finally {
    client?.close(force: true);
  }
}

// ---------------------------------------------------------------------------
// 重新部署（源码 --install）
// ---------------------------------------------------------------------------

/// 读 config.json 里记录的源码目录。
String? readSourceRoot() {
  try {
    final f = File(svcConfigPath());
    if (!f.existsSync()) return null;
    return sourceRootFromConfig(f.readAsStringSync());
  } catch (_) {
    return null;
  }
}

/// 部署并重启：等当前 GUI 退出（[waitPid]）后跑源码的 `--install`。
///
/// 不能直接 detach `--install`：它的 _killGuiProcesses 是 kill -9，会在
/// GUI 持有 VM 会话时留下 DDS 死锁；必须让 GUI 先优雅退出（关会话）。
Future<Map<String, Object?>> redeployAndRestart({required int waitPid}) async {
  // 分发版没有源码可部署：更新靠重装应用。
  if (isBundledBuild()) {
    return <String, Object?>{
      'ok': false,
      'message': '分发版不支持从源码重新部署；请安装新版本的 XbUme 应用',
    };
  }
  final root = readSourceRoot();
  if (root == null || root.isEmpty) {
    return <String, Object?>{
      'ok': false,
      'message': '未记录源码目录：请在项目里执行 dart run xb_ume:ide --install',
    };
  }
  final script = '$root${_sep}bin${_sep}ide.dart';
  if (!File(script).existsSync()) {
    return <String, Object?>{
      'ok': false,
      'message': '源码目录已失效（$script 不存在），请手动执行 --install',
    };
  }
  final log = installLogPath();
  try {
    File(log).parent.createSync(recursive: true);
    File(log).writeAsStringSync(
      '[${DateTime.now().toIso8601String()}] 开始重新部署（源码：$root）\n',
      mode: FileMode.append,
    );
  } catch (_) {}
  final dartBin = Platform.resolvedExecutable;
  try {
    if (Platform.isWindows) {
      await Process.start(
        'powershell',
        <String>[
          '-NoProfile',
          '-WindowStyle',
          'Hidden',
          '-Command',
          redeployPowerShellCommand(
            waitPid: waitPid,
            dartBin: dartBin,
            installScript: script,
            logPath: log,
          ),
        ],
        mode: ProcessStartMode.detached,
      );
    } else {
      await Process.start(
        '/bin/sh',
        <String>[
          '-c',
          redeployShellCommand(
            waitPid: waitPid,
            dartBin: dartBin,
            installScript: script,
            logPath: log,
          ),
        ],
        mode: ProcessStartMode.detached,
      );
    }
  } catch (e) {
    return <String, Object?>{'ok': false, 'message': '部署器启动失败: $e'};
  }
  return <String, Object?>{
    'ok': true,
    'message': 'GUI 退出后将重新部署并重启（日志：$log）',
    'log': log,
  };
}
