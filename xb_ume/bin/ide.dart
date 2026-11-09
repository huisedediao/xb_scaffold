// xb_ume IDE 跳转守护脚本。
//
// 与被调试 App 内的 xb_ume 联动：App 中双击链条行会经 VM service
// Extension 流发出 `xb_ume:openSource` 事件，本脚本接收后在本机唤起
// IDE（VS Code / Android Studio）定位到对应源码行列。
//
// 用法（零新增依赖，运行于宿主机）：
//   dart run xb_ume:ide --install [--ide-order "qodercn,cursor,code"] [--ide ...]
//       一次性安装（macOS 注册 LaunchAgent 登录自启 + 崩溃自拉起；
//       Windows 写 HKCU 注册表 Run 键登录自启）；
//       有终端时交互选择 IDE 优先级并写入 ~/.xb_ume_ide/config.json（回车=默认顺序）。
//   dart run xb_ume:ide --configure [--ide-order "..."] [--show]
//       查看/修改 IDE 优先级（daemon 每次跳转时重读配置，改完即生效）。
//   dart run xb_ume:ide --uninstall
//       卸载守护进程与安装文件（含 config.json），并停止所有 daemon 实例。
//   dart run xb_ume:ide --daemon [--ide ...]
//       前台运行守护进程（不注册自启）；单实例锁：新实例自动接管，旧实例退出；
//   dart run xb_ume:ide --uri <ws-url> [--ide ...]
//       手动监听单个 VM service（自动发现不可用时的兜底）。
//
// 自动发现（daemon 模式）：
//   每 3s 轮询 lsof 列出本机回环监听端口，逐个 GET /getVM 探测，
//   返回 {"result":{"type":"VM",...}} 即 VM service，连后订阅 Extension 流。
// 同一台电脑可同时接入多台设备/多个会话；会话断开自动清理。
//
// ignore_for_file: avoid_print
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'src/session/discovery.dart';
import 'src/session/agent_forward.dart';
import 'src/session/capability.dart';
// 服务控制：GUI / daemon 的启停、重启与重新部署；与 bin/ide_gui.dart 共用
// 同一份实现（macOS 走 launchd，其他平台按命令行精确匹配进程）。
import 'src/control/svc_control.dart';
// GUI / MCP 拉起的 flutter run 记录（含带 token 的 VM 地址）。
import 'src/device/live_store.dart';
// 代理兜底：本机回环（VM Service / GUI API）不走 http_proxy。
import 'src/device/proxy_env.dart';
import 'src/scenario/vm_client.dart' show normalizeVmUri;

/// App 端 XBUmeIdeJump.eventId，双端约定一致。
const String kEventKind = 'xb_ume:openSource';

/// 事件过期窗口：DDS 重放缓冲事件时 Event.timestamp 保留原值（实测注入
/// 与重放完全相同），事件年龄超窗口即判定为重放丢弃，无需 app 升级即可
/// 精确拦住重放。真实事件从 app 发出到 daemon 收到通常 <1s，取 10s 留
/// 足余量。
const Duration _staleEventWindow = Duration(seconds: 10);

/// Event.timestamp → 事件年龄（ms）；无/非法字段返回 -1（不过滤）。
/// 文档标注 timestamp 为微秒，实测 Flutter 引擎给出毫秒，按量级自适应。
int _eventAgeMs(Object? ts) {
  final v = int.tryParse('$ts');
  if (v == null || v <= 0) return -1;
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final ms = v > 100000000000000
      ? v ~/ 1000 // 微秒级
      : (v > 100000000000 ? v : v * 1000); // 毫秒级 / 秒级
  return nowMs - ms;
}

/// LaunchAgent 标签 / 安装路径约定。
const String kLabel = 'com.xbume.ide';
const String kInstallDirName = '.xb_ume_ide';
const String kPlistName = '$kLabel.plist';
const String kConfigName = 'config.json';
const String kWinRunKeyPath =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const String kWinRunKeyName = 'XBumeIde';

const Duration kPollInterval = Duration(seconds: 3);

/// 单实例互斥：固定回环端口锁。
/// 新实例启动时先按命令行匹配停止其他 daemon 进程，再绑定本端口；
/// 持锁实例收到 [kEvictToken] 后自动退出（接管语义：只保留最新实例）。
const int kLockPort = 46128;
const String kEvictToken = 'xbume-ide-takeover';

/// GUI（ide_gui.dart）经互斥端口查询 daemon 状态的协议令牌。
const String kStatusToken = 'xbume-ide-status';
ServerSocket? _lockServer;

/// daemon 启动时间（供 status 协议上报运行时长）。
DateTime _daemonStartedAt = DateTime.now();

/// 用户主目录：Windows 用 USERPROFILE（HOME 通常不存在），其余用 HOME。
final String _home = svcHome();

void _printUsage() {
  print('''
用法:
  dart run xb_ume:ide --install [--ide-order "..."] [--ide ...] [--no-gui]  安装并重启守护进程与 GUI
  dart run xb_ume:ide --configure [--ide-order "..."] [--show]                   查看/修改 IDE 优先级
  dart run xb_ume:ide --uninstall                                卸载
  dart run xb_ume:ide --daemon [--ide ...]                       前台运行守护进程
  dart run xb_ume:ide --uri <ws-url> [--ide ...]                 手动监听单个 VM service
  dart run xb_ume:ide --gui                                      启动 GUI（先确保守护进程在跑）
  dart run xb_ume:ide --ensure-daemon                            确保守护进程在跑（已在则跳过）
  dart run xb_ume:ide --svc status                               查看 GUI / 守护进程状态
  dart run xb_ume:ide --svc start|stop|restart [gui|daemon|all]  启停 / 重启（GUI 需在运行才能优雅停止）
  dart run xb_ume:ide --svc redeploy                             从源码重新部署并重启（需 GUI 在跑）
  XbUme.app（分发版双击）                                     确保守护进程在跑并打开 GUI''');
}

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index >= 0 && index + 1 < args.length) {
    return args[index + 1];
  }
  return null;
}

void main(List<String> args) {
  // 必须在任何 WebSocket / HttpClient 之前：本机回环直连，避免继承了
  // http_proxy 时把 VM Service / GUI API 的请求发给代理而卡住。
  bypassProxyForLoopback();
  final proxyHint = proxyEnvHint();
  if (proxyHint != null) {
    print('[xbume-ide] 检测到代理环境（$proxyHint）：本机回环连接已自动绕过代理。');
  }
  // Zone 兑底：任何遗漏的未捕获异步异常（如各 socket 的 RST）只记录不退出
  // —— daemon 被杀 → launchd 拉起新实例 → DDS 重放缓冲跳转事件，用户
  // 实测每 30s~1min 全部位置重复跳转，宁吞勿崩。
  runZonedGuarded(
    () => _mainImpl(args),
    (Object e, StackTrace s) {
      // 锁端口的 RST 每秒都在发生（GUI 客户端快速断开），静默避免刷屏；
      // 其余异常仍记录（事后可查）。
      if (e is SocketException && e.port == kLockPort) return;
      print('[xbume-ide] $_logTs 未捕获异常已忽略: $e');
    },
  );
}

Future<void> _mainImpl(List<String> args) async {
  // 分发版（.app）：Finder 双击不带参数 —— 确保 daemon 在跑，起 GUI
  // （GUI 自己打开浏览器），本进程随即退出。
  if (args.isEmpty && isBundledBuild()) {
    await runBundledApp();
    return;
  }
  if (args.contains('--install')) {
    await install(args);
    return;
  }
  if (args.contains('--uninstall')) {
    await uninstall();
    return;
  }
  if (args.contains('--configure')) {
    await configure(
      orderArg: _argValue(args, '--ide-order'),
      show: args.contains('--show'),
    );
    return;
  }
  if (args.contains('--ensure-daemon')) {
    final r = await startDaemon();
    print('[xbume-ide] ${r['message'] ?? r}');
    if (r['ok'] != true) exitCode = 1;
    return;
  }
  if (args.contains('--svc')) {
    await svcCommand(args);
    return;
  }
  final ide = _argValue(args, '--ide') ?? 'auto';
  final uri = _argValue(args, '--uri');
  if (uri != null) {
    await _runSingleSession(uri, ide);
    return;
  }
  if (args.contains('--gui')) {
    final guiScript = File('${svcInstallDir()}/ide_gui.dart');
    if (!guiScript.existsSync()) {
      print('[xbume-ide] 未找到 GUI 脚本，请先执行 dart run xb_ume:ide --install');
      exitCode = 1;
      return;
    }
    // 工具箱入口是「一键开启」：先把守护进程确保起来（失败不拦 GUI）。
    final d = await startDaemon();
    if (d['ok'] != true) print('[xbume-ide] ${d['message']}');
    await Process.start(
      Platform.resolvedExecutable,
      <String>[guiScript.path],
      mode: ProcessStartMode.detached,
    );
    return;
  }
  if (args.contains('--daemon')) {
    _installShutdownHooks();
    await runDaemon(ide);
    return;
  }
  _printUsage();
}

// ---------------------------------------------------------------------------
// 分发版启动器
// ---------------------------------------------------------------------------

/// 双击入口：确保 daemon 在跑 → 起 GUI（GUI 自己打开浏览器）→ 退出。
///
/// 不注册 LaunchAgent：测试人员机器上不该留开机自启（也不该出现卸不干净）；
/// daemon 以 detached 子进程存活，GUI「服务」菜单仍可以停掉它。
Future<void> runBundledApp() async {
  final d = await startDaemon();
  print('[xbume-app] ${d['message'] ?? d}');
  final g = await spawnGuiDetached();
  print('[xbume-app] ${g['message'] ?? g}');
}

// ---------------------------------------------------------------------------
// 安装 / 卸载（macOS LaunchAgent）
// ---------------------------------------------------------------------------

Future<void> install(List<String> args) async {
  if (!Platform.isMacOS && !Platform.isWindows) {
    print('[xbume-ide] --install 仅支持 macOS/Windows；Linux 请用 --daemon 前台运行。');
    exitCode = 1;
    return;
  }
  final scriptPath = _selfScriptPath();
  if (scriptPath == null) {
    print('[xbume-ide] 无法定位自身源码（请在依赖 xb_ume 的项目目录内运行）。');
    exitCode = 1;
    return;
  }
  final installDir = Directory(svcInstallDir());
  await installDir.create(recursive: true);
  final deployedScript =
      '${installDir.path}${Platform.pathSeparator}ide.dart';
  await File(deployedScript).writeAsString(File(scriptPath).readAsStringSync());
  // 部署副本在 ~/.xb_ume_ide 下独立运行，dart 只从脚本所在目录解析相对
  // import；依赖没一起复制时 daemon 启动即编译失败。
  await _deployRuntimeDeps(scriptPath, installDir.path);

  final dartBin = Platform.resolvedExecutable;
  final ide = _argValue(args, '--ide') ?? 'auto';

  // 部署 GUI 工具箱（bin/ide_gui.dart 与本文件同目录）。
  await _deployGui(scriptPath, installDir.path, dartBin);
  // 记录源码目录：GUI「重新部署并重启」要靠它跑源码里的 --install。
  await _writeSourceRoot(scriptPath, installDir.path);

  final bool ok;
  final String detailPath;
  final String logPath;
  if (Platform.isMacOS) {
    logPath = '$_home/Library/Logs/xb_ume_ide.log';
    detailPath = '$_home/Library/LaunchAgents/$kPlistName';
    ok = await _installMacosLaunchAgent(
      dartBin: dartBin,
      scriptPath: deployedScript,
      logPath: logPath,
      ide: ide,
    );
  } else {
    logPath = '$installDir${Platform.pathSeparator}daemon.log';
    detailPath = kWinRunKeyPath;
    ok = await _installWindowsRunKey(
      dartBin: dartBin,
      scriptPath: deployedScript,
      logPath: logPath,
      ide: ide,
    );
  }
  if (!ok) {
    exitCode = 1;
    return;
  }

  await _resolveAndSaveIdeOrder(
    orderArg: _argValue(args, '--ide-order'),
    ideArg: ide,
  );
  // 新副本已就位：把正在跑的 GUI 一并换掉，否则页面仍由旧进程提供旧代码。
  if (!args.contains('--no-gui')) {
    await _restartGui(installDir.path, dartBin);
  }
  print('[xbume-ide] 安装完成，守护进程已启动。');
  print('  注册: $detailPath');
  print('  脚本 : $deployedScript');
  print('  日志 : $logPath');
  print('  GUI  : ${installDir.path}${Platform.pathSeparator}ide_gui.dart（启动器见同目录，或 dart run xb_ume:ide --gui）');
  print('卸载: dart run xb_ume:ide --uninstall');
}

/// 把源码目录写进 config.json（读-改-写，保留 ideOrder 等其他键）。
///
/// 部署副本（~/.xb_ume_ide/ide.dart）运行时不带 package 依赖，无法自己
/// 定位仓库；GUI 的「重新部署并重启」需要这个路径去 detach 源码的
/// `bin/ide.dart --install`。
Future<void> _writeSourceRoot(String ideScriptPath, String installDir) async {
  final file = File('$installDir${Platform.pathSeparator}$kConfigName');
  Map<String, Object?> data = <String, Object?>{};
  try {
    if (file.existsSync()) {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) {
        data = <String, Object?>{
          for (final e in decoded.entries) e.key.toString(): e.value,
        };
      }
    }
  } catch (_) {
    // 旧配置坏了就直接重写，不阻塞安装。
  }
  data['sourceRoot'] = Directory(File(ideScriptPath).parent.path).parent.path;
  data['deployedAt'] = DateTime.now().toIso8601String();
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
}

// ---------------------------------------------------------------------------
// 服务控制（命令行入口）
// ---------------------------------------------------------------------------

/// `--svc status|start|stop|restart|redeploy [gui|daemon|all]`。
///
/// GUI 的停止 / 重启必须由 GUI 进程自己收尾（先关 VM 会话再 exit，否则
/// DDS 死锁），所以 GUI 在跑时一律经本地令牌调它的 `/api/svc/*`；GUI 不在
/// 时才直接操作 daemon。
Future<void> svcCommand(List<String> args) async {
  final i = args.indexOf('--svc');
  final action = (i >= 0 && i + 1 < args.length) ? args[i + 1] : 'status';
  final positional = <String>[];
  for (var j = 0; j < args.length; j++) {
    if (j == i || j == i + 1) continue;
    if (args[j].startsWith('--')) continue;
    positional.add(args[j]);
  }
  if (positional.isNotEmpty && normalizeSvcTarget(positional.first) == null) {
    print('[xbume-svc] 目标只能是 gui / daemon / all');
    exitCode = 1;
    return;
  }
  final target = normalizeSvcTarget(positional.isEmpty ? null : positional.first) ??
      'all';
  final guiPort = await discoverGuiPort();
  switch (action) {
    case 'status':
      await _printSvcStatus(guiPort);
      return;
    case 'start':
      if (target == 'daemon' || target == 'all') {
        final r = await startDaemon();
        print('[xbume-svc] ${r['message'] ?? r}');
        if (r['ok'] != true) exitCode = 1;
      }
      if (target == 'gui' || target == 'all') {
        final r = await spawnGuiDetached();
        print('[xbume-svc] ${r['message'] ?? r}');
        if (r['ok'] != true) exitCode = 1;
      }
      return;
    case 'stop':
      if (guiPort != null && (target == 'gui' || target == 'all')) {
        // target=all 时 GUI 会先把 daemon 停掉再退出，不用分两次调。
        final r = await callGuiSvc('stop', target: target);
        print('[xbume-svc] ${r['message'] ?? r}');
        if (r['ok'] != true) exitCode = 1;
        return;
      }
      final r = await stopDaemon();
      print('[xbume-svc] ${r['message'] ?? r}');
      if (r['ok'] != true) exitCode = 1;
      return;
    case 'restart':
      if (guiPort != null) {
        final r = await callGuiSvc('restart', target: target);
        print('[xbume-svc] ${r['message'] ?? r}');
        if (r['ok'] != true) exitCode = 1;
        return;
      }
      if (target != 'gui') {
        final d = await restartDaemon();
        print('[xbume-svc] ${d['message'] ?? d}');
        if (d['ok'] != true) exitCode = 1;
      }
      if (target == 'gui' || target == 'all') {
        final g = await spawnGuiDetached();
        print('[xbume-svc] ${g['message'] ?? g}');
        if (g['ok'] != true) exitCode = 1;
      }
      return;
    case 'redeploy':
      if (guiPort == null) {
        print('[xbume-svc] 重新部署需要 GUI 在跑（由它先优雅退出再执行 --install）；'
            '也可直接运行 dart run xb_ume:ide --install');
        exitCode = 1;
        return;
      }
      final r = await callGuiSvc('redeploy', target: 'all');
      print('[xbume-svc] ${r['message'] ?? r}');
      if (r['ok'] != true) exitCode = 1;
      return;
    default:
      print('[xbume-svc] 未知动作: $action'
          '（可用 status / start / stop / restart / redeploy）');
      exitCode = 1;
  }
}

Future<void> _printSvcStatus(int? guiPort) async {
  final daemon = await queryDaemonStatus();
  if (guiPort != null) {
    print('[xbume-svc] GUI    : 运行中 http://127.0.0.1:$guiPort');
  } else {
    print('[xbume-svc] GUI    : 未运行');
  }
  if (daemon != null) {
    final sessions = (daemon['sessions'] as List?)?.length ?? 0;
    print('[xbume-svc] daemon : 运行中 pid=${daemon['pid']} 会话=$sessions '
        '运行时长=${daemon['uptimeSec'] ?? '?'}s');
  } else {
    print('[xbume-svc] daemon : 未运行');
  }
  print('[xbume-svc] 源码   : ${readSourceRoot() ?? '未记录（重新部署不可用）'}');
}

/// GUI 桌面入口名称（macOS 应用包 / Windows 桌面快捷方式）。
const String kGuiAppName = 'xb_ume 工具箱';

/// 部署随 ide.dart 一起复制的运行时模块。
///
/// 部署副本在 ~/.xb_ume_ide 下独立运行，dart 只从脚本所在目录解析相对
/// import。bin/ 下没有任何 `package:` 依赖，所以整棵 src 树复制过去就能独立
/// 运行；按文件清单手工登记迟早会漏（daemon 与 MCP 各加一个模块就得改两处），
/// 这里直接递归，并额外带上 MCP 入口（GUI「启动 MCP」用它）。
///
/// `test/ide_deploy_deps_test.dart` 锁住「bin/ 无 package: 依赖」这个前提。
Future<void> _deployRuntimeDeps(String ideScriptPath, String installDir) async {
  final binDir = File(ideScriptPath).parent.path;
  final sep = Platform.pathSeparator;
  final src = Directory('$binDir${sep}src');
  if (src.existsSync()) {
    await _copyDartTree(src, Directory('$installDir${sep}src'));
  } else {
    print('[xbume-ide] 未找到 bin/src，部署副本可能无法启动。');
  }
  final mcp = File('$binDir${sep}mcp.dart');
  if (mcp.existsSync()) {
    await File('$installDir${sep}mcp.dart')
        .writeAsString(mcp.readAsStringSync());
  } else {
    print('[xbume-ide] 未找到 mcp.dart，GUI「启动 MCP 服务」将不可用。');
  }
  // 部署副本旁边没有 pubspec.yaml，MCP 的 --version / 握手 serverInfo 靠它报版本。
  try {
    final pubspec = File('$binDir$sep..${sep}pubspec.yaml');
    if (pubspec.existsSync()) {
      final m = RegExp(r'^version:\s*(\S+)', multiLine: true)
          .firstMatch(pubspec.readAsStringSync());
      if (m != null) {
        await File('$installDir${sep}version.txt').writeAsString(m.group(1)!);
      }
    }
  } catch (_) {
    // 版本号不影响功能。
  }
}

/// 递归复制目录下的 .dart 文件，保持相对结构。
Future<void> _copyDartTree(Directory from, Directory to) async {
  await to.create(recursive: true);
  final sep = Platform.pathSeparator;
  for (final e in from.listSync(recursive: true, followLinks: false)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final rel = e.path
        .substring(from.path.length)
        .replaceFirst(RegExp(r'^[/\\]'), '');
    final dest = File('${to.path}$sep$rel');
    await dest.parent.create(recursive: true);
    await dest.writeAsString(e.readAsStringSync());
  }
}

/// 部署 GUI 工具箱脚本并生成可双击的启动器（best-effort，失败不影响 daemon 安装）。
Future<void> _deployGui(String ideScriptPath, String installDir, String dartBin) async {
  try {
    final binDir = File(ideScriptPath).parent.path;
    final guiSource = File('$binDir${Platform.pathSeparator}ide_gui.dart');
    if (!guiSource.existsSync()) {
      print('[xbume-ide] 未找到 ide_gui.dart，跳过 GUI 部署。');
      return;
    }
    final sep = Platform.pathSeparator;
    await File('$installDir${sep}ide_gui.dart')
        .writeAsString(guiSource.readAsStringSync());
    if (Platform.isWindows) {
      // 一键开启：先确保守护进程（--ensure-daemon 幂等），再起 GUI。
      await File('$installDir${sep}XBumeGui.bat').writeAsString(
        '@echo off\r\n'
        // 本机回环（VM Service / GUI API / 守护端口）不走代理；其余地址仍按
        // 启动它的环境里的代理设置。dart:io 的 HttpClient 默认读 no_proxy。
        'set "_xb_np=%NO_PROXY%"\r\n'
        'if not defined _xb_np set "_xb_np=%no_proxy%"\r\n'
        'set "NO_PROXY=127.0.0.1,localhost,::1,%_xb_np%"\r\n'
        'set "no_proxy=%NO_PROXY%"\r\n'
        'start "xbume-daemon" /min "$dartBin" "$installDir${sep}ide.dart" --ensure-daemon\r\n'
        'start "xbume-gui" /min "$dartBin" "$installDir${sep}ide_gui.dart"\r\n',
      );
    } else {
      final launcher = File('$installDir${sep}xb_ume_gui.command');
      await launcher.writeAsString(
        '#!/bin/bash\n'
        // 本机回环（VM Service / GUI API / 守护端口）不走代理；其余地址仍按
        // 启动它的 shell 里的代理设置。dart:io 的 HttpClient 默认读 no_proxy。
        '_xb_np="\${no_proxy:-\${NO_PROXY:-}}"\n'
        'export NO_PROXY="127.0.0.1,localhost,::1\${_xb_np:+,\$_xb_np}"\n'
        'export no_proxy="\$NO_PROXY"\n'
        // 双击启动 = 一键开启：守护进程不在就拉起来（幂等，失败不拦 GUI）。
        '"$dartBin" "$installDir/ide.dart" --ensure-daemon >/dev/null 2>&1\n'
        'exec "$dartBin" "$installDir/ide_gui.dart"\n',
      );
      try {
        await Process.run('chmod', <String>['+x', launcher.path]);
      } catch (_) {
        // ignored
      }
    }
    await _installGuiDesktopEntry(installDir, dartBin);
    print('[xbume-ide] GUI 工具箱已部署。');
  } catch (e) {
    print('[xbume-ide] GUI 部署失败（不影响守护进程）: $e');
  }
}

/// 安装 GUI 桌面入口：macOS 在应用程序文件夹创建 .app（Launchpad/Spotlight 可搜），
/// Windows 在桌面创建快捷方式（最小化运行）。
Future<void> _installGuiDesktopEntry(String installDir, String dartBin) async {
  if (Platform.isMacOS) {
    final guiScript = '$installDir/ide_gui.dart';
    for (final root in <String>['/Applications', '$_home/Applications']) {
      final appDir = Directory('$root/$kGuiAppName.app');
      try {
        await appDir.create(recursive: true);
      } catch (_) {
        continue; // 无写权限则尝试下一个位置
      }
      final contents = '${appDir.path}/Contents';
      await Directory('$contents/MacOS').create(recursive: true);
      await Directory('$contents/Resources').create(recursive: true);
      await File('$contents/Info.plist').writeAsString(_guiAppPlist);
      final exec = File('$contents/MacOS/xbumegui');
      await exec.writeAsString(
        '#!/bin/bash\n'
        // 双击工具箱 = 一键开启：先把守护进程确保起来（KeepAlive 的 plist
        // 可能被「停止守护进程」bootout 过），再启动 GUI。
        '"$dartBin" "$installDir/ide.dart" --ensure-daemon >/dev/null 2>&1\n'
        'exec "$dartBin" "$guiScript"\n',
      );
      try {
        await Process.run('chmod', <String>['+x', exec.path]);
      } catch (_) {
        // ignored
      }
      // 图标：复制系统通用应用图标（best-effort）。
      const systemIcon =
          '/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns';
      final icon = File(systemIcon);
      if (icon.existsSync()) {
        try {
          await icon.copy('$contents/Resources/xbumegui.icns');
        } catch (_) {
          // ignored
        }
      }
      print('[xbume-ide] GUI 应用已安装: ${appDir.path}（可从 Launchpad/Spotlight 启动）');
      return;
    }
    print('[xbume-ide] GUI 应用安装失败（应用程序文件夹无写权限），仍可用启动器 .command 或 --gui 启动。');
  } else if (Platform.isWindows) {
    // 快捷方式指向 .bat：它内部先 --ensure-daemon 再起 GUI（一键开启）。
    final ps = '\$ws = New-Object -ComObject WScript.Shell; '
        "\$desktop = [Environment]::GetFolderPath('Desktop'); "
        '\$s = \$ws.CreateShortcut("\$desktop\\$kGuiAppName.lnk"); '
        "\$s.TargetPath = '$installDir\\XBumeGui.bat'; "
        "\$s.WorkingDirectory = '$installDir'; "
        "\$s.IconLocation = '$dartBin,0'; "
        '\$s.WindowStyle = 7; '
        '\$s.Save()';
    final result = await Process.run(
      'powershell',
      <String>['-NoProfile', '-Command', ps],
      runInShell: true,
    );
    if (result.exitCode == 0) {
      print('[xbume-ide] 桌面快捷方式已创建: $kGuiAppName.lnk');
    } else {
      print('[xbume-ide] 桌面快捷方式创建失败: ${result.stderr}');
    }
  }
}

/// GUI 默认起始端口（与 ide_gui.dart 的 kGuiPortBase 保持一致）。
const int _kGuiPortBase = 46129;

/// 命令行里的 dart 可执行文件（排除 xxx.dart 里的「dart」后缀误判）。
final RegExp _dartExecutablePattern =
    RegExp(r'(^|[/\\\s"])dart(\.exe)?(["\s]|$)', caseSensitive: false);

/// 命令行是否指向 GUI 脚本（同时含 dart 可执行文件与 ide_gui.dart）。
/// install 自身与 daemon 的命令行都不含该脚本名，可安全用于结束旧 GUI。
bool isGuiProcessCommandLine(String cmdline) =>
    cmdline.contains('ide_gui.dart') &&
    _dartExecutablePattern.hasMatch(cmdline);

/// 结束本机正在运行的 GUI（按命令行精确匹配，不碰 daemon 与其他 dart 进程）。
/// 先 SIGTERM：GUI 收到后走优雅退出，顺手收掉自己拉起的设备日志流（hdc
/// hilog / adb logcat / simctl log stream）——这些子进程不随父进程退出，
/// 硬杀会一直留在后台，攒几天把 hdc 的连接占满，表现为 flutter run 在
/// fport 阶段报 `Connect server failed`。等不到退出再 SIGKILL 兜底。
Future<void> _killGuiProcesses() async {
  try {
    if (Platform.isWindows) {
      // 只查 dart.exe：PowerShell 自身命令行也带匹配串，不能扫全表。
      const ps = "Get-CimInstance Win32_Process -Filter \"Name='dart.exe'\" | "
          "Where-Object { \$_.CommandLine -like '*ide_gui.dart*' } | "
          "ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }";
      await Process.run('powershell', <String>['-NoProfile', '-Command', ps]);
      return;
    }
    final targets = <int>[];
    final pgrep = await Process.run('pgrep', <String>['-f', r'ide_gui\.dart']);
    for (final line in pgrep.stdout.toString().split('\n')) {
      final other = int.tryParse(line.trim());
      if (other == null || other == pid) continue;
      // 严格复核命令行，避免误伤编辑器、grep 等同样带脚本名的进程。
      final ps = await Process.run(
        'ps',
        <String>['-p', '$other', '-o', 'command='],
      );
      if (!isGuiProcessCommandLine(ps.stdout.toString())) continue;
      targets.add(other);
    }
    if (targets.isEmpty) return;
    for (final other in targets) {
      await Process.run('kill', <String>['-TERM', '$other']);
    }
    for (var attempt = 0; attempt < 12; attempt++) {
      if (!await _anyPidAlive(targets)) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    for (final other in targets) {
      if (await _pidRunning(other)) {
        await Process.run('kill', <String>['-9', '$other']);
      }
    }
  } catch (_) {
    // 结束旧 GUI 失败不阻塞安装；新进程启动时会走单实例语义。
  }
}

/// 进程是否还活着（kill -0 不发信号，只探测）。
Future<bool> _pidRunning(int target) async {
  try {
    final r = await Process.run('kill', <String>['-0', '$target']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<bool> _anyPidAlive(List<int> targets) async {
  for (final p in targets) {
    if (await _pidRunning(p)) return true;
  }
  return false;
}

/// 探测某端口是否已有 GUI 在应答（/ping 返回 xbume-gui 指纹）。
Future<bool> _pingGuiPort(int port) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 400);
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/ping'));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return body.contains('xbume-gui');
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<bool> _anyGuiAlive() async {
  for (var p = _kGuiPortBase; p < _kGuiPortBase + 10; p++) {
    if (await _pingGuiPort(p)) return true;
  }
  return false;
}

/// 重启 GUI：停旧实例 → 等端口释放 → detached 启动新副本。
Future<void> _restartGui(String installDir, String dartBin) async {
  final sep = Platform.pathSeparator;
  final script = '$installDir${sep}ide_gui.dart';
  if (!File(script).existsSync()) {
    print('[xbume-ide] 未找到 $script，跳过 GUI 重启。');
    return;
  }
  // 先请正在跑的 GUI 自己退出：它会先关掉全部 VM 会话再 exit，直接
  // kill -9 会让 DDS 永久死锁（该调试会话此后对所有客户端无响应）。
  // GUI 不在 / 没有令牌 / 卡死无响应时才退回下面的精确 kill。
  final graceful = await callGuiSvc('stop', target: 'gui');
  if (graceful['ok'] == true) {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!await _anyGuiAlive()) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  await _killGuiProcesses();
  // 必须确认旧实例真的不响应了再拉起：否则新进程探测到旧实例后
  // 只会打开浏览器就退出，页面仍是旧代码。
  for (var attempt = 0; attempt < 15; attempt++) {
    if (!await _anyGuiAlive()) break;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  try {
    if (Platform.isWindows) {
      // dart.exe 是控制台程序，走 cmd start /min 避免弹出一个黑窗。
      await Process.start(
        'cmd',
        <String>['/c', 'start', '', '/min', dartBin, script],
        mode: ProcessStartMode.detached,
      );
    } else {
      await Process.start(
        dartBin,
        <String>[script],
        mode: ProcessStartMode.detached,
      );
    }
    print('[xbume-ide] GUI 已重启（浏览器页面会自动打开）。');
  } catch (e) {
    print('[xbume-ide] GUI 重启失败（可双击桌面图标手动启动）: $e');
  }
}

const String _guiAppPlist = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>XBume Toolbox</string>
  <key>CFBundleDisplayName</key>
  <string>xb_ume 工具箱</string>
  <key>CFBundleIdentifier</key>
  <string>com.xbume.gui</string>
  <key>CFBundleExecutable</key>
  <string>xbumegui</string>
  <key>CFBundleIconFile</key>
  <string>xbumegui</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
''';

/// macOS：写 LaunchAgent plist 并注册立即启动。返回是否成功。
Future<bool> _installMacosLaunchAgent({
  required String dartBin,
  required String scriptPath,
  required String logPath,
  required String ide,
}) async {
  final plistPath = '$_home/Library/LaunchAgents/$kPlistName';
  await Directory('$_home/Library/LaunchAgents').create(recursive: true);
  await File(plistPath).writeAsString(_buildPlist(
    dartBin: dartBin,
    scriptPath: scriptPath,
    logPath: logPath,
    ide: ide,
  ));

  final uid = (await Process.run('id', <String>['-u'])).stdout.toString().trim();
  // 先卸载旧实例（如有），再注册并立即启动。
  await Process.run(
    'launchctl',
    <String>['bootout', 'gui/$uid', plistPath],
  );
  final bootstrap = await Process.run(
    'launchctl',
    <String>['bootstrap', 'gui/$uid', plistPath],
  );
  if (bootstrap.exitCode != 0) {
    final loaded = await Process.run(
      'launchctl',
      <String>['load', '-w', plistPath],
    );
    if (loaded.exitCode != 0) {
      print('[xbume-ide] launchctl 注册失败: ${loaded.stderr}');
      return false;
    }
  }
  return true;
}

/// Windows：写 HKCU 注册表 Run 键实现登录自启（等效 macOS LaunchAgent）。
/// Run 键由 explorer 在登录时启动，无 KeepAlive 等效物（崩溃不自拉起）；
/// 如需查看日志可手动 `dart bin/ide.dart --daemon` 前台运行。
/// 返回是否成功。
Future<bool> _installWindowsRunKey({
  required String dartBin,
  required String scriptPath,
  required String logPath,
  required String ide,
}) async {
  final ideArgs = ide == 'auto' ? '' : ' --ide $ide';
  // 通过 cmd 包装实现输出重定向到日志（Run 键自身不支持重定向）。
  final value = 'cmd /c ""$dartBin" "$scriptPath" --daemon$ideArgs'
      ' >> "$logPath" 2>&1"';
  final result = await Process.run(
    'reg',
    <String>[
      'add', kWinRunKeyPath, '/v', kWinRunKeyName,
      '/t', 'REG_SZ', '/d', value, '/f',
    ],
  );
  if (result.exitCode != 0) {
    print('[xbume-ide] 注册表写入失败: ${result.stderr}');
    return false;
  }
  // 立即启动一次（不等下次登录）。
  final start = await Process.start(
    'cmd',
    <String>['/c', 'start', '/b', '', dartBin, scriptPath, '--daemon'],
    runInShell: true,
  );
  unawaited(start.exitCode);
  return true;
}

Future<void> uninstall() async {
  if (Platform.isMacOS) {
    final uid =
        (await Process.run('id', <String>['-u'])).stdout.toString().trim();
    final plistPath = '$_home/Library/LaunchAgents/$kPlistName';
    await Process.run('launchctl', <String>['bootout', 'gui/$uid', plistPath]);
    await Process.run('launchctl', <String>['remove', kLabel]);
    final plist = File(plistPath);
    if (plist.existsSync()) {
      await plist.delete();
    }
  } else if (Platform.isWindows) {
    await Process.run(
      'reg',
      <String>['delete', kWinRunKeyPath, '/v', kWinRunKeyName, '/f'],
    );
  }
  // 停止所有仍在运行的 daemon 实例（含手动 --daemon 启动的）。
  await _killOtherDaemons();
  // 移除 GUI 桌面入口。
  if (Platform.isMacOS) {
    for (final root in <String>['/Applications', '$_home/Applications']) {
      final appDir = Directory('$root/$kGuiAppName.app');
      if (appDir.existsSync()) {
        await appDir.delete(recursive: true);
      }
    }
  } else if (Platform.isWindows) {
    await Process.run(
      'powershell',
      <String>[
        '-NoProfile',
        '-Command',
        "\$desktop = [Environment]::GetFolderPath('Desktop'); "
            'Remove-Item -Force -ErrorAction SilentlyContinue '
            '"\$desktop\\$kGuiAppName.lnk"',
      ],
      runInShell: true,
    );
  }
  final dir = Directory(svcInstallDir());
  if (dir.existsSync()) {
    await dir.delete(recursive: true);
  }
  print('[xbume-ide] 已停止守护进程并卸载。');
}

String _buildPlist({
  required String dartBin,
  required String scriptPath,
  required String logPath,
  required String ide,
}) {
  final ideArgs =
      ide == 'auto' ? '' : '\n    <string>--ide</string>\n    <string>$ide</string>';
  return '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$kLabel</string>
  <key>ProgramArguments</key>
  <array>
    <string>$dartBin</string>
    <string>$scriptPath</string>
    <string>--daemon</string>$ideArgs
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$logPath</string>
  <key>StandardErrorPath</key>
  <string>$logPath</string>
</dict>
</plist>
''';
}

/// 定位本脚本源码：优先从当前项目 package_config.json 找 xb_ume 包，
/// 兜底 Platform.script（直接运行 dart ide.dart 时）。
String? _selfScriptPath() {
  try {
    final config = File('.dart_tool/package_config.json');
    if (config.existsSync()) {
      final json = jsonDecode(config.readAsStringSync());
      if (json is Map<String, Object?> && json['packages'] is List<Object?>) {
        for (final pkg in json['packages']! as List<Object?>) {
          if (pkg is! Map<String, Object?> || pkg['name'] != 'xb_ume') {
            continue;
          }
          final rootUri = pkg['rootUri']?.toString();
          if (rootUri == null) {
            continue;
          }
          // rootUri 可为相对路径或 file: URI，按 package_config 规范
          // 相对于 .dart_tool/ 目录解析。
          final rootUriObj = Directory.current.uri
              .resolve('.dart_tool/')
              .resolve(rootUri);
          final root = rootUriObj.scheme == 'file'
              ? rootUriObj.toFilePath()
              : rootUriObj.toString();
          final candidate =
              '$root/bin/ide.dart';
          if (File(candidate).existsSync()) {
            return candidate;
          }
        }
      }
    }
  } catch (_) {
    // 回退到 Platform.script。
  }
  try {
    final script = Platform.script.toFilePath();
    if (script.endsWith('ide.dart')) {
      return script;
    }
  } catch (_) {
    // ignored
  }
  return null;
}

// ---------------------------------------------------------------------------
// IDE 优先级配置（~/.xb_ume_ide/config.json）
//
// daemon 在每次唤起 IDE 时重新读取，修改配置立即生效，无需重启。
// 配置缺失/损坏时回退内置默认顺序；--ide 显式参数优先级最高。
// ---------------------------------------------------------------------------

File _configFile() => File('${svcInstallDir()}/$kConfigName');

/// 全部合法的 IDE 名称（供 --ide-order 校验）。
Set<String> get _knownIdeNames => <String>{..._vscodeLikeClis, 'androidStudio'};

/// 读取 IDE 优先级配置；缺失/损坏时返回 null（回退内置默认顺序）。
List<String>? loadIdeOrder() {
  try {
    final file = _configFile();
    if (!file.existsSync()) {
      return null;
    }
    final parsed = jsonDecode(file.readAsStringSync());
    if (parsed is! Map<String, Object?>) {
      return null;
    }
    final order = parsed['ideOrder'];
    if (order is! List) {
      return null;
    }
    final names =
        order.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    return names.isEmpty ? null : names;
  } catch (e) {
    print('[xbume-ide] 配置读取失败，回退默认顺序: $e');
    return null;
  }
}

Future<void> saveIdeOrder(List<String> order) async {
  final file = _configFile();
  await file.parent.create(recursive: true);
  // 读-改-写：config.json 里还存着 sourceRoot / MCP 自启等键，整体覆盖
  // 会把 GUI「重新部署」依赖的源码目录抹掉。
  Map<String, Object?> data = <String, Object?>{};
  try {
    if (file.existsSync()) {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) {
        data = <String, Object?>{
          for (final e in decoded.entries) e.key.toString(): e.value,
        };
      }
    }
  } catch (_) {
    // 旧配置坏了就重写。
  }
  data['ideOrder'] = order;
  data['updatedAt'] = DateTime.now().toIso8601String();
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
}

/// 安装时确定 IDE 顺序：--ide-order > 交互选择 > 不写配置（保持默认）。
/// 显式 --ide（非 auto）保持旧行为，不写配置。
Future<void> _resolveAndSaveIdeOrder({
  String? orderArg,
  required String ideArg,
}) async {
  if (ideArg != 'auto') {
    print('[xbume-ide] 已显式指定 IDE=$ideArg，跳过顺序配置。');
    return;
  }
  if (orderArg != null) {
    final order = _parseIdeOrder(orderArg);
    if (order == null) {
      exitCode = 1;
      return;
    }
    await saveIdeOrder(order);
    print('[xbume-ide] IDE 顺序已写入 ${_configFile().path}');
    await _printEffectiveOrder();
    return;
  }
  if (!stdin.hasTerminal) {
    print('[xbume-ide] 非交互环境，未写 IDE 顺序配置（可用 --configure 配置）。');
    return;
  }
  await _interactiveIdeSetup();
}

/// 交互式选择 IDE 优先级并写配置；用户回车跳过则不写。
Future<void> _interactiveIdeSetup() async {
  final candidates = await _availableIdeCandidates();
  if (candidates.isEmpty) {
    print('[xbume-ide] 未检测到可用 IDE，未写顺序配置（保持默认顺序）。');
    return;
  }
  print('检测到可用的 IDE：');
  for (var i = 0; i < candidates.length; i++) {
    print('  [${i + 1}] ${candidates[i].label} (${candidates[i].name})');
  }
  stdout.write(
    '请按优先级输入编号（如 "2 1 3"，空格/逗号分隔；直接回车=默认顺序）: ',
  );
  final line = (stdin.readLineSync() ?? '').trim();
  if (line.isEmpty) {
    print('[xbume-ide] 保持默认顺序，未写配置（可随时 --configure 修改）。');
    return;
  }
  final order = _orderFromIndexes(line, candidates);
  if (order == null) {
    print('[xbume-ide] 输入无效，保持默认顺序（可随时 --configure 修改）。');
    return;
  }
  await saveIdeOrder(order);
  print('[xbume-ide] IDE 顺序已写入 ${_configFile().path}');
  await _printEffectiveOrder();
}

Future<void> configure({String? orderArg, bool show = false}) async {
  if (orderArg != null) {
    final order = _parseIdeOrder(orderArg);
    if (order == null) {
      exitCode = 1;
      return;
    }
    await saveIdeOrder(order);
    print('[xbume-ide] IDE 顺序已写入 ${_configFile().path}');
  } else if (!show && stdin.hasTerminal) {
    await _interactiveIdeSetup();
    return;
  }
  await _printEffectiveOrder();
}

Future<void> _printEffectiveOrder() async {
  final configured = loadIdeOrder();
  final names = configured ?? _defaultIdeOrder;
  stdout.writeln(
    '配置文件: ${_configFile().path}${configured == null ? '（不存在，使用默认顺序）' : ''}',
  );
  stdout.writeln('当前生效顺序:');
  for (final name in names) {
    if (name == 'androidStudio') {
      final ok = await _hasAndroidStudio();
      stdout.writeln('  - androidStudio ${ok ? '✓ 可用' : '✗ 未检测到'}');
    } else {
      final path = await _resolveCliPath(name);
      stdout.writeln('  - $name ${path == null ? '✗ 未检测到' : '✓ $path'}');
    }
  }
  stdout
      .writeln('修改: dart run xb_ume:ide --configure [--ide-order "qodercn,cursor,code"]');
}

/// 解析 "2 1 3" / "2,1,3" 形式的编号输入为 IDE 名称列表。
List<String>? _orderFromIndexes(String line, List<_IdeCandidate> candidates) {
  final tokens =
      line.split(RegExp(r'[,\s]+')).where((e) => e.isNotEmpty).toList();
  final order = <String>[];
  for (final token in tokens) {
    final index = int.tryParse(token);
    if (index == null || index < 1 || index > candidates.length) {
      print('无效编号: $token');
      return null;
    }
    final name = candidates[index - 1].name;
    if (!order.contains(name)) {
      order.add(name);
    }
  }
  return order.isEmpty ? null : order;
}

/// 校验并解析 --ide-order 参数；非法名称返回 null 并打印可选值。
List<String>? _parseIdeOrder(String arg) {
  final tokens =
      arg.split(RegExp(r'[,\s]+')).where((e) => e.isNotEmpty).toList();
  if (tokens.isEmpty) {
    print('[xbume-ide] --ide-order 为空（可选: ${_knownIdeNames.join(', ')}）。');
    return null;
  }
  final order = <String>[];
  for (final token in tokens) {
    if (!_knownIdeNames.contains(token)) {
      print(
        '[xbume-ide] 未知的 IDE 名称: $token（可选: ${_knownIdeNames.join(', ')}）。',
      );
      return null;
    }
    if (!order.contains(token)) {
      order.add(token);
    }
  }
  return order;
}

class _IdeCandidate {
  const _IdeCandidate(this.name, this.label);

  final String name;
  final String label;
}

/// 探测本机实际可用的 IDE（供交互选择列表）；同名别名去重。
Future<List<_IdeCandidate>> _availableIdeCandidates() async {
  final result = <_IdeCandidate>[];
  for (final cli in _vscodeLikeClis) {
    // qodercn 与 qoder-cn 为同一 IDE 的别名，仅展示一次。
    if (cli == 'qoder-cn' && result.any((c) => c.name == 'qodercn')) {
      continue;
    }
    if (await _hasIdeCli(cli)) {
      result.add(_IdeCandidate(cli, _ideLabel(cli)));
    }
  }
  if (await _hasAndroidStudio()) {
    result.add(const _IdeCandidate('androidStudio', 'Android Studio'));
  }
  return result;
}

String _ideLabel(String cli) {
  switch (cli) {
    case 'qodercn':
    case 'qoder-cn':
      return 'Qoder';
    case 'cursor':
      return 'Cursor';
    case 'trae':
      return 'Trae';
    case 'windsurf':
      return 'Windsurf';
    case 'code':
      return 'VS Code';
    default:
      return cli;
  }
}

// ---------------------------------------------------------------------------
// 守护进程
// ---------------------------------------------------------------------------

final Map<String, _Session> _sessions = <String, _Session>{};

/// 本轮直连（app 内 Agent）探测结果：只用于状态列表，不参与 IDE 跳转。
List<DiscoveredAgent> _agents = <DiscoveredAgent>[];

/// 本轮 VM 探测结果：与 [_agents] 合并后输出 transport / caps。
List<DiscoveredSession> _lastDiscovered = <DiscoveredSession>[];

/// 日志时间前缀（daemon 日志无时间戳曾严重阻碍排障：无法对齐「重启→重
/// 放」时间线）。
String get _logTs => DateTime.now().toIso8601String().substring(11, 19);

/// 已处理事件去重表（key → 首见时间），防 DDS 重连/重启重放。
final Map<String, DateTime> _seenEvents = <String, DateTime>{};

/// 已处理事件里最大的 app 端 ts（毫秒）。用于区分「新事件」与「重放」：
/// 事件 ts 与 Event.timestamp 都来自手机时钟，手机时钟慢于本机超过
/// _staleEventWindow 时，真实新事件会被年龄过滤误杀；而比历史最大值
/// 更新的 ts 只可能是新事件（重放事件 ts 必然更旧）。
int _newestEventTs = 0;

/// 无 ts 签名的去重窗口：窗口内相同 位置 的真实重复点击也会被吞，
/// 取 90s 平衡防重放（重连后立即重放）与误杀。实测重放与原事件相隔
/// 62s（崩溃周期 30s~1min），窗口必须覆盖。
const Duration _eventDedupWindow = Duration(seconds: 90);

/// 带 ts 事件的去重窗口：ts 是 app 端发事件时刻的毫秒时间戳，重放事件
/// 与原事件 ts 完全相同，可长窗口精确去重——手动重启 daemon 后的重放
/// 也能拦住（签名窗口拦不住超过 90s 的重放）。窗口长于典型开发日即可。
const Duration _tsDedupWindow = Duration(hours: 24);

/// 按 key 前缀取对应去重窗口。
Duration _dedupWindowOf(String key) =>
    key.startsWith('ts:') ? _tsDedupWindow : _eventDedupWindow;

/// 去重表持久化：daemon 若再被杀重启，内存表清空会导致重启后第一轮
/// 重放全部放行（实测如此），落盘后跨重启仍可拦截窗口内重放。
String get _seenPath => '${svcInstallDir()}/seen_events.json';

void _seenLoad() {
  try {
    final j = jsonDecode(File(_seenPath).readAsStringSync());
    if (j is! Map) return;
    final now = DateTime.now();
    j.forEach((Object? k, Object? v) {
      final ms = int.tryParse('$v');
      if (k == null || ms == null) return;
      final t = DateTime.fromMillisecondsSinceEpoch(ms);
      if (now.difference(t) > _dedupWindowOf('$k')) return;
      _seenEvents['$k'] = t;
      final key = '$k';
      if (key.startsWith('ts:')) {
        final ts = int.tryParse(key.substring(3));
        if (ts != null && ts > _newestEventTs) _newestEventTs = ts;
      }
    });
  } catch (_) {
    // 无文件/损坏：空表起步。
  }
}

void _seenSave() {
  try {
    final f = File(_seenPath);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode(<String, Object?>{
      for (final e in _seenEvents.entries)
        e.key: e.value.millisecondsSinceEpoch,
    }));
  } catch (_) {
    // 持久化失败不影响去重（仅影响跨重启）。
  }
}

/// 已接入 VM service 实例的指纹（isolates id 组合）。
/// 同一调试实例可能经多个端口可达（如 adb forward 与 flutter 工具代理），
/// 以指纹去重避免重复接入。
final Set<String> _knownFingerprints = <String>{};
bool _polling = false;

/// 停止本机上其他 `ide.dart --daemon` 进程（排除自身）。
/// 旧版本脚本没有端口锁，只能按命令行匹配兕底。
Future<void> _killOtherDaemons() async {
  try {
    if (Platform.isWindows) {
      // 命令行同时含 ide.dart 与 --daemon 的进程，排除自身后强制结束。
      final ps = "Get-CimInstance Win32_Process | Where-Object { "
          "\$_.CommandLine -match 'ide\\.dart' -and "
          "\$_.CommandLine -match '--daemon' -and \$_.ProcessId -ne $pid } | "
          "ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }";
      await Process.run(
        'powershell',
        <String>['-NoProfile', '-Command', ps],
      );
    } else {
      // macOS/Linux：pgrep 按完整命令行匹配，排除自身后 kill。
      final pgrep = await Process.run(
        'pgrep',
        <String>['-f', r'ide\.dart.*--daemon'],
      );
      for (final line in pgrep.stdout.toString().split('\n')) {
        final other = int.tryParse(line.trim());
        if (other == null || other == pid) continue;
        // 严格校验命令行：只停部署目录下的 ide.dart --daemon，避免模糊
        // 模式误伤本机其他调试进程。
        final ps = await Process.run(
          'ps',
          <String>['-p', '$other', '-o', 'command='],
        );
        final cmdline = ps.stdout.toString().trim();
        if (!cmdline.contains('${svcInstallDir()}/ide.dart') ||
            !cmdline.contains('--daemon')) {
          continue;
        }
        await Process.run('kill', <String>['-9', '$other']);
      }
    }
  } catch (_) {
    // 清理失败不阻塞启动。
  }
}

/// 获取单实例锁：停止旧实例 → 绑定互斥端口 → 监听接管请求。
Future<void> _acquireSingletonLock() async {
  await _killOtherDaemons();
  // 最多等 3s 让被停进程释放端口。
  for (var attempt = 0; attempt < 10; attempt++) {
    try {
      _lockServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        kLockPort,
      );
      break;
    } on SocketException {
      // 端口仍被占用（如被杀进程未完全退出或锁被外部占用）：
      // 通知持有者退出后重试。
      await _requestEviction();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
  final server = _lockServer;
  if (server == null) {
    print('[xbume-ide] 警告：互斥端口 $kLockPort 被占用，本次运行无单实例保护。');
    return;
  }
  // onError 必须吞：客户端（GUI 状态轮询）收到响应后立即 destroy，若 RST
  // 到达时机在 accept 前/中，错误走 ServerSocket 的 onError 而非已接受
  // socket 的 onError——此处不吞会未捕获异常杀死 daemon（实测）。
  server.listen(_onLockConnection, onError: (Object _) {
    // accept/底层错误：正常现象，忽略。
  });
}

/// daemon 退出时收掉自己拉起的 iproxy（iOS 真机转发）。
///
/// 按句柄 kill，不按进程名匹配：本机可能还有用户自己开的 iproxy / 别的工具，
/// 宽泛匹配会误杀。注册失败（平台不支持该信号）时直接跳过。
void _installShutdownHooks() {
  Future<void> onSignal() async {
    await stopAgentForwardProcesses();
    exit(0);
  }

  for (final signal in <ProcessSignal>[
    ProcessSignal.sigterm,
    ProcessSignal.sigint,
    ProcessSignal.sighup,
  ]) {
    try {
      signal.watch().first.then((_) => onSignal()).catchError((_) {});
    } catch (_) {
      // 当前平台不支持该信号：跳过。
    }
  }
}

/// 通知当前持锁实例退出（接管协议）。
Future<void> _requestEviction() async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      kLockPort,
      timeout: const Duration(milliseconds: 500),
    );
    socket.write(kEvictToken);
    await socket.flush();
    socket.destroy();
  } catch (_) {
    // 持有者可能已退出或非本脚本占用，忽略。
  }
}

/// 持锁侧：接管令牌即退出；status 查询令牌则应答 JSON 后保持连接。
void _onLockConnection(Socket socket) {
  // onError 必须吞掉：GUI 状态轮询等客户端断开时可能产生 RST，
  // 未捕获的 SocketException 会杀死整个 daemon（launchd 拉起新实例
  // → 重连 VM → DDS 重放缓冲事件 → 全部跳转重复执行，实测每
  // 30s~1min 循环一次）。
  socket.listen((data) {
    final text = utf8.decode(data, allowMalformed: true);
    if (text.contains(kEvictToken)) {
      print('[xbume-ide] 检测到新实例接管，本实例退出。');
      _lockServer?.close();
      // 先收掉自己拉起的 iproxy，再把端口交出去。
      unawaited(stopAgentForwardProcesses().whenComplete(() => exit(0)));
      return;
    }
    if (text.contains(kStatusToken)) {
      socket.write(jsonEncode(<String, Object?>{
        'type': 'status',
        'pid': pid,
        'uptimeSec': DateTime.now().difference(_daemonStartedAt).inSeconds,
        'sessions': _statusSessions(),
      }));
    }
  }, onError: (Object _) {
    // 客户端 RST（Connection reset by peer）：正常现象，忽略。
  }, onDone: () {
    // 客户端正常断开，忽略。
  });
}

Future<void> runDaemon(String ide) async {
  _seenLoad();
  await _acquireSingletonLock();
  _daemonStartedAt = DateTime.now();
  print(
    '[xbume-ide] daemon 启动 (pid=$pid)，每 ${kPollInterval.inSeconds}s 轮询，'
    'IDE=$ide。Ctrl-C 退出。',
  );
  Future<void> loop() async {
    while (true) {
      await _poll(ide);
      await Future<void>.delayed(kPollInterval);
    }
  }

  await loop();
}

Future<void> _runSingleSession(String wsUrl, String ide) async {
  // 连接失败/掉线后自动重连，避免 `--uri` 模式断一次就永久挂起。
  while (true) {
    final session = _Session(wsUrl, 'manual', ide);
    _sessions[wsUrl] = session;
    await session.connect();
    if (!session.alive) {
      _sessions.remove(wsUrl);
      print('[xbume-ide] 连接失败，3s 后重试：$wsUrl');
      await Future<void>.delayed(const Duration(seconds: 3));
      continue;
    }
    print('[xbume-ide] 手动监听中，Ctrl-C 退出。');
    await session.closed;
    _sessions.remove(wsUrl);
    print('[xbume-ide] 会话断开，3s 后重连：$wsUrl');
    await Future<void>.delayed(const Duration(seconds: 3));
  }
}

/// 接入本工具（GUI / MCP）拉起的 flutter run 会话。
///
/// VM service 默认要求 auth code：不带 token 的 `GET /getVM` 返回 403，
/// 端口扫描因此发现不了它们。启动记录 `launch/live/<pid>.json` 里的
/// `wsUri` 已经带 token，归一化后直接接入；只认 pid 存活且命令行仍是
/// flutter run 的记录，避免接入无关进程。
Future<void> _adoptLaunchRecords(String ide) async {
  for (final record in readLaunchRecords()) {
    final raw = (record.wsUri ?? '').trim();
    if (raw.isEmpty || !recordStillValid(record)) continue;
    final wsUrl = normalizeVmUri(raw);
    if (wsUrl.isEmpty) continue;
    final port = Uri.tryParse(wsUrl)?.port ?? 0;
    // 端口扫描命中同一实例时地址不含 token，按端口去重。
    final exists = _sessions.values.any((s) {
      if (s.wsUrl == wsUrl) return true;
      return port > 0 && (Uri.tryParse(s.wsUrl)?.port ?? 0) == port;
    });
    if (exists) continue;
    final session = _Session(wsUrl, '${record.owner}:${record.pid}', ide);
    _sessions[wsUrl] = session;
    await session.connect();
    if (!session.alive) _sessions.remove(wsUrl);
  }
}

Future<void> _poll(String ide) async {
  if (_polling) return;
  _polling = true;
  try {
    // GUI / MCP 拉起的会话：启动记录里已经有带 auth code 的完整地址，
    // 直接接入。端口扫描拿不到 token（VM service 对无 token 的 /getVM
    // 返回 403），所以不能只靠它。
    await _adoptLaunchRecords(ide);
    final discovered = await discoverLocalVmServices(
      knownFingerprints: _knownFingerprints,
    );
    _lastDiscovered = discovered;

    // 直连通道（P0 先只做发现与展示，不改跳转链路）。
    await _pollAgents();

    // 接入新会话。
    for (final s in discovered) {
      if (_sessions.containsKey(s.wsUrl)) {
        continue;
      }
      final session = _Session(
        s.wsUrl,
        s.source,
        ide,
        fingerprint: s.fingerprint,
      );
      _sessions[s.wsUrl] = session;
      await session.connect();
      if (session.alive) {
        // 只有接成功才记指纹；失败从会话表移除，下一轮重试。
        _knownFingerprints.add(s.fingerprint);
      } else {
        _sessions.remove(s.wsUrl);
      }
    }
    // 清理已断开会话。
    final dead = _sessions.values.where((s) => !s.alive).toList();
    for (final session in dead) {
      _sessions.remove(session.wsUrl);
    }
  } catch (e) {
    print('[xbume-ide] 轮询异常: $e');
  } finally {
    _polling = false;
  }
}

// ---------------------------------------------------------------------------
// 直连（app 内 Agent）发现：P0 只做探测 + 列表展示，能力由 caps 驱动 GUI 置灰。
// ---------------------------------------------------------------------------

/// daemon 自身与 GUI/MCP 常驻服务的端口，探测时跳过（避免把自己当 app）。
Set<int> get _selfPorts => <int>{
      kLockPort,
      for (var p = 46129; p <= 46149; p++) p,
    };

Future<void> _pollAgents() async {
  try {
    final skip = <int>{
      // 自己 + GUI/MCP 端口，以及已经确认是 VM service 的端口都跳过。
      ..._selfPorts,
      for (final d in _lastDiscovered) d.port,
    };
    final scanned = await discoverLocalAgents(skipPorts: skip);
    // app 的 Agent 只监听设备本机回环，必须先 adb forward / hdc fport 才能读到。
    // 转发已存在时直接复用（端口按序列号稳定分配，不抢用户的转发）。
    final forwarded = await ensureAgentForwards();
    // 转发来源带设备标识（adb:SERIAL#port:N），优先于裸端口扫描结果。
    final byFingerprint = <String, DiscoveredAgent>{};
    for (final a in <DiscoveredAgent>[...forwarded, ...scanned]) {
      byFingerprint.putIfAbsent(a.fingerprint, () => a);
    }
    _agents = byFingerprint.values.toList()
      ..sort((a, b) => a.port.compareTo(b.port));
  } catch (e) {
    // 探测失败不影响 VM 会话（直连只是辅助通道）。
    print('[xbume-ide] 直连探测异常: $e');
  }
}

/// 当前会话列表（VM + 直连合并），带 transport / caps 供 GUI 置灰使用。
List<Map<String, Object?>> _statusSessions() {
  final vmAlive = <String, _Session>{
    for (final s in _sessions.values)
      if (s.alive) s.wsUrl: s,
  };
  final logical = mergeLogicalSessions(
    vmSessions: _lastDiscovered,
    agents: _agents,
  );
  final out = <Map<String, Object?>>[];
  for (final l in logical) {
    if (l.vm != null && !vmAlive.containsKey(l.vm!.wsUrl)) continue;
    out.add(<String, Object?>{
      'source': l.source,
      'uri': l.uri,
      // 实例指纹（端口无关）：同一实例重连后端口可能变化，
      // GUI 前端据此恢复用户选中的会话。
      'fp': l.fingerprint,
      'transport': sessionTransportName(l.transport),
      if (l.vmPort != null) 'vmPort': l.vmPort,
      if (l.agentPort != null) 'agentPort': l.agentPort,
      if ((l.agent?.baseUrl ?? '').isNotEmpty) 'agentUrl': l.agent!.baseUrl,
      // Flutter 的 getVM.name 恒为 'vm'，无信息量：透传给 GUI 会把下拉
      // 变成「vm · adb:…」，直连包名才是真正可用的 app 标识。
      if (l.appName.isNotEmpty && l.appName != 'vm') 'app': l.appName,
      if (l.obfuscated) 'obfuscated': true,
      'caps': l.caps().toList()..sort(),
    });
  }
  // --uri 手工注入的会话不在扫描结果里，单独补上（transport=vm，能力全开）。
  for (final s in _sessions.values) {
    if (!s.alive) continue;
    final manual = s.source.startsWith('manual:');
    if (!manual) continue;
    out.add(<String, Object?>{
      'source': s.source,
      'uri': s.wsUrl,
      if (s.fingerprint != null) 'fp': s.fingerprint,
      'transport': kTransportVm,
      'caps': kVmCaps.toList()..sort(),
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// VM service 客户端（手写 JSON-RPC over WebSocket）
// ---------------------------------------------------------------------------

class _Session {
  _Session(this.wsUrl, this.source, this.ide, {this.fingerprint});

  final String wsUrl;
  final String source;

  /// IDE 选择策略：auto / 具体_cli / androidStudio。
  final String ide;

  /// 探测阶段得到的实例指纹，断开时从全局去重集合移除。
  final String? fingerprint;

  WebSocket? _socket;
  bool alive = true;
  int _nextId = 1;

  /// JSON-RPC 请求等待表：daemon 平时只被动收事件，解析 package: 源引用时
  /// 需要临时向该会话的 VM service 发 getVM / getIsolate。
  final Map<String, Completer<Map<String, Object?>>> _pending =
      <String, Completer<Map<String, Object?>>>{};

  /// 包名 → 包根路径缓存（来自被调试项目的 package_config.json）。
  Map<String, String>? _pkgRoots;

  /// 会话断开时完成（连接失败也会先走 _close），供 --uri 模式等待重连。
  final Completer<void> _closed = Completer<void>();
  Future<void> get closed => _closed.future;

  Future<void> connect() async {
    try {
      final WebSocket socket =
          await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 5));
      _socket = socket;
      socket.listen(
        _onData,
        onDone: _close,
        onError: (Object error) => _close(),
      );
      socket.add(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': '${_nextId++}',
          'method': 'streamListen',
          'params': <String, Object?>{'streamId': 'Extension'},
        }),
      );
      print('[xbume-ide] 已连接 $source');
    } catch (e) {
      print('[xbume-ide] 连接失败 $source: $e');
      _close();
    }
  }

  /// 向该会话的 VM service 发 JSON-RPC 请求并等待结果；失败/超时返回 null。
  Future<Map<String, Object?>?> _vmCall(
    String method, [
    Map<String, Object?>? params,
  ]) async {
    final socket = _socket;
    if (socket == null) return null;
    final id = '${_nextId++}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    try {
      socket.add(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params ?? const <String, Object?>{},
      }));
      final response =
          await completer.future.timeout(const Duration(seconds: 3));
      final result = response['result'];
      return result is Map<String, Object?> ? result : null;
    } catch (_) {
      return null;
    } finally {
      _pending.remove(id);
    }
  }

  void _onData(dynamic message) {
    final String text;
    if (message is String) {
      text = message;
    } else if (message is List<int>) {
      text = utf8.decode(message);
    } else {
      return;
    }
    Object? parsed;
    try {
      parsed = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (parsed is! Map<String, Object?>) return;
    // JSON-RPC 响应（daemon 主动发起的 getVM / getIsolate 等）。
    final responseId = parsed['id'];
    if (responseId != null) {
      final completer = _pending.remove('$responseId');
      if (completer != null && !completer.isCompleted) {
        completer.complete(parsed);
      }
      return;
    }
    // JSON-RPC 错误响应（如 streamListen 失败）便于排查。
    final error = parsed['error'];
    if (error != null) {
      print('[xbume-ide] VM service 响应异常 ($source): $error');
      return;
    }
    // 事件以 streamNotify 通知投递：params.event 为事件本体。
    final params = parsed['params'];
    if (params is! Map<String, Object?>) return;
    if (params['streamId'] != 'Extension') return;
    final event = params['event'];
    if (event is! Map<String, Object?>) return;
    // developer.postEvent(eventKind, data) →
    // event.extensionKind + event.extensionData（实测 wire 格式）。
    if (event['extensionKind'] != kEventKind) return;
    final data = event['extensionData'];
    if (data is! Map<String, Object?>) return;
    // 事件年龄过滤：DDS 重放保留原始 timestamp，过期即重放丢弃。
    // 事件 ts 与 timestamp 都来自手机时钟，手机时钟慢于本机超过窗口时
    // 真实新事件也会被误杀；比历史最大 ts 更新的只可能是新事件，跳过年龄
    // 判断（重放事件 ts 必然更旧）。
    final payloadTs = int.tryParse('${data['ts']}');
    final newerThanSeen =
        payloadTs != null && _newestEventTs > 0 && payloadTs > _newestEventTs;
    if (!newerThanSeen) {
      final age = _eventAgeMs(event['timestamp']);
      if (age >= 0 && age > _staleEventWindow.inMilliseconds) {
        print('[xbume-ide] $_logTs 过期事件已忽略 ($source): '
            'age=${age}ms event=$data');
        return;
      }
    }
    _handle(data);
  }

  Future<void> _handle(Map<String, Object?> data) async {
    final file = data['file']?.toString();
    final line = int.tryParse('${data['line']}');
    final column = int.tryParse('${data['column']}');
    // 去重：DDS/VM 会把缓冲的 postEvent 事件重放给新订阅者（daemon 重启
    // / 会话重连时实测全部重放），不加去重会导致已处理过的跳转全部重复
    // 执行。优先用 app 端 payload 的 ts（重放事件 ts 完全相同，可精确
    // 识别且不误杀真实重复点击）；旧版 app 无 ts 时退化为 签名+时间窗。
    final ts = int.tryParse('${data['ts']}');
    final key = ts != null
        ? 'ts:$ts'
        : 'sig:$file:$line:$column';
    final now = DateTime.now();
    _seenEvents
        .removeWhere((k, t) => now.difference(t) > _dedupWindowOf(k));
    final firstSeen = _seenEvents[key];
    if (firstSeen != null) {
      print('[xbume-ide] $_logTs 重放事件已忽略 ($source): $file:$line:$column');
      return;
    }
    _seenEvents[key] = now;
    if (ts != null && ts > _newestEventTs) {
      _newestEventTs = ts;
    }
    _seenSave();
    print('[xbume-ide] $_logTs 收到跳转请求 ($source): $file:$line:$column');
    final target = await _resolveSourceFile(file);
    if (target != null && target != file) {
      print('[xbume-ide] package 源引用已解析: $file → $target');
    }
    await openInIde(file: target, line: line, column: column, mode: ide);
  }

  /// 把 package: 源引用解析为本机文件路径（file:/dart: 等原样返回）。
  ///
  /// daemon 不知道被调试项目的路径，借用会话自身的 VM service：
  /// getIsolate 的 file:/// 库（含 .dart_tool/flutter_build 注册文件）
  /// 反推项目根，再读该项目的 package_config.json 做包名映射。
  Future<String?> _resolveSourceFile(String? file) async {
    if (file == null || file.isEmpty || !file.startsWith('package:')) {
      return file;
    }
    final roots = await _packageRoots();
    if (roots == null) return file;
    final rest = file.substring('package:'.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return file;
    final pkg = rest.substring(0, slash);
    final rel = rest.substring(slash + 1);
    final root = roots[pkg];
    if (root == null) return file;
    final path = '$root/lib/$rel';
    return File(path).existsSync() ? path : file;
  }

  /// 解析并缓存当前会话所属项目的包根表；失败返回 null。
  Future<Map<String, String>?> _packageRoots() async {
    final cached = _pkgRoots;
    if (cached != null) return cached;
    try {
      final vm = await _vmCall('getVM');
      final isolates = vm?['isolates'];
      if (isolates is! List) return null;
      for (final iso in isolates) {
        if (iso is! Map || iso['id'] == null) continue;
        final info = await _vmCall('getIsolate', <String, Object?>{
          'isolateId': '${iso['id']}',
        });
        final libraries = info?['libraries'];
        if (libraries is! List) continue;
        final fileUris = <String>[];
        for (final lib in libraries) {
          if (lib is! Map) continue;
          final uri = lib['uri']?.toString();
          if (uri != null && uri.startsWith('file:///')) fileUris.add(uri);
        }
        final projectRoot = _projectRootFor(fileUris);
        if (projectRoot == null) continue;
        final roots = _readPackageRoots(projectRoot);
        if (roots != null) {
          _pkgRoots = roots;
          return roots;
        }
      }
    } catch (e) {
      print('[xbume-ide] 解析 package 源引用失败 ($source): $e');
    }
    return null;
  }

  void _close() {
    if (!alive) return;
    alive = false;
    // 唤醒仍在等待 RPC 响应的调用，避免会话断开后挂到超时。
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('session closed'));
      }
    }
    _pending.clear();
    try {
      _socket?.close();
    } catch (_) {
      // ignored
    }
    final fp = fingerprint;
    if (fp != null) {
      _knownFingerprints.remove(fp);
    }
    if (!_closed.isCompleted) {
      _closed.complete();
    }
    print('[xbume-ide] 会话断开 $source');
  }
}

// ---------------------------------------------------------------------------
// IDE 唤起
// ---------------------------------------------------------------------------

Future<void> openInIde({
  required String? file,
  required int? line,
  required int? column,
  required String mode,
}) async {
  if (file == null || file.isEmpty || line == null) {
    print('[xbume-ide] 位置无效，跳过。');
    return;
  }
  final path = _toFilePath(file);
  final location =
      column != null ? '$path:$line:$column' : '$path:$line';

  String? ide = mode;
  if (ide == 'auto') {
    ide = await _detectIde();
  } else if (_vscodeLikeClis.contains(ide)) {
    // 显式指定了具体 CLI（如 qodercn），映射为 vscode 系。
    ide = 'vscode:$ide';
  } else if (ide == 'vscode') {
    // 未指定具体 CLI：按配置顺序（无配置时用内置默认）找第一个可用。
    final cli = await _firstAvailable(_configuredClis());
    ide = cli == null ? null : 'vscode:$cli';
  }
  if (ide != null && await _launchIde(ide, path, line, column)) {
    print('[xbume-ide] 已在 $ide 打开: $location');
    return;
  }
  await _copyToClipboard(location);
  print('[xbume-ide] 未找到可用 IDE，已复制到剪贴板: $location');
}

/// VS Code 系 IDE 的 CLI 候选（同参数约定：-g file:line:col），
/// 排在前面的优先（均为 VS Code fork，CLI 用法与 code 一致）。
const List<String> _vscodeLikeClis = <String>[
  'qodercn',
  'qoder-cn',
  'cursor',
  'trae',
  'windsurf',
  'code',
];

/// qodercn/qoder-cn 的 CLI 实为 dispatcher：`-g` 直传会被路由给独立安装的
/// QoderCN CLI（qoderclicn，未装则 exit 127）而非 IDE，导致优先级检测失败
/// 静默落到下一个 IDE（实测打开成 VSCode）。必须加 `ide` 子命令（走
/// _run_ide → IDE 原生 launcher）；只装 CLI 未装 IDE 时同样 exit 127，
/// 正确落到下一优先级。
const Map<String, List<String>> _ideCliSubcommands = <String, List<String>>{
  'qodercn': <String>['ide'],
  'qoder-cn': <String>['ide'],
};

/// 未配置时的默认检测顺序（兼容旧行为：CLI 全部不可用时兜底 Android Studio）。
const List<String> _defaultIdeOrder = <String>[..._vscodeLikeClis, 'androidStudio'];

/// macOS 上未安装 shell 命令时，按 app 内置 CLI 兜底查找。
const Map<String, List<String>> _macosVscodeLikeAppClis =
    <String, List<String>>{
  'qoder-cn': <String>[
    '/Applications/Qoder CN IDE.app/Contents/Resources/app/bin/qoder-cn',
    '/Applications/Qoder.app/Contents/Resources/app/bin/qoder-cn',
  ],
  'qodercn': <String>[
    '/Applications/Qoder CN IDE.app/Contents/Resources/app/bin/qodercn',
    '/Applications/Qoder.app/Contents/Resources/app/bin/qodercn',
  ],
  'cursor': <String>[
    '/Applications/Cursor.app/Contents/Resources/app/bin/cursor',
  ],
  'trae': <String>[
    '/Applications/Trae.app/Contents/Resources/app/bin/trae',
    '/Applications/Trae CN.app/Contents/Resources/app/bin/trae',
  ],
  'windsurf': <String>[
    '/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf',
  ],
  'code': <String>[
    '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code',
  ],
};

/// 未安装 shell 命令时按 app 内置 CLI 兜底查找。
/// Windows 常见安装路径（Electron 应用结构，发行渠道众多，未逐一实测）。
Map<String, List<String>> get _vscodeLikeAppClis {
  if (Platform.isMacOS) {
    return _macosVscodeLikeAppClis;
  }
  if (Platform.isWindows) {
    final lad = Platform.environment['LOCALAPPDATA'];
    if (lad == null) {
      return const <String, List<String>>{};
    }
    String user(String app) => '$lad\\Programs\\$app\\resources\\app\\bin';
    String system(String app) => 'C:\\Program Files\\$app\\resources\\app\\bin';
    return <String, List<String>>{
      'qoder-cn': <String>[
        '${user('Qoder CN')}\\qoder-cn.cmd',
        '${user('Qoder')}\\qoder-cn.cmd',
        '${system('Qoder CN')}\\qoder-cn.cmd',
      ],
      'qodercn': <String>[
        '${user('Qoder CN')}\\qodercn.cmd',
        '${user('Qoder')}\\qodercn.cmd',
        '${system('Qoder CN')}\\qodercn.cmd',
      ],
      'cursor': <String>[
        '${user('Cursor')}\\cursor.cmd',
        '${system('Cursor')}\\cursor.cmd',
      ],
      'trae': <String>[
        '${user('Trae')}\\trae.cmd',
        '${user('Trae CN')}\\trae.cmd',
        '${system('Trae')}\\trae.cmd',
      ],
      'windsurf': <String>[
        '${user('Windsurf')}\\windsurf.cmd',
        '${system('Windsurf')}\\windsurf.cmd',
      ],
      'code': <String>[
        '$lad\\Programs\\Microsoft VS Code\\bin\\code.cmd',
        'C:\\Program Files\\Microsoft VS Code\\bin\\code.cmd',
      ],
    };
  }
  return const <String, List<String>>{};
}

/// 解析 CLI 实际可执行路径：优先 PATH，macOS/Windows 下回退 app 内置 CLI。
Future<String?> _resolveCliPath(String cli) async {
  if (await _hasCommand(cli)) {
    return cli;
  }
  if (!Platform.isMacOS && !Platform.isWindows) {
    return null;
  }
  for (final path in _vscodeLikeAppClis[cli] ?? const <String>[]) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  return null;
}

Future<bool> _hasIdeCli(String cli) async {
  return await _resolveCliPath(cli) != null;
}

/// 生效的 vscode 系 CLI 顺序：配置文件优先，无配置时用内置默认。
List<String> _configuredClis() {
  final order = loadIdeOrder() ?? _vscodeLikeClis;
  final clis = order.where((name) => name != 'androidStudio').toList();
  return clis.isEmpty ? _vscodeLikeClis : clis;
}

Future<String?> _detectIde() async {
  // 优先级顺序：配置文件（~/.xb_ume_ide/config.json）优先，
  // 无配置时回退内置默认；列表内未安装的自动跳过。
  for (final name in loadIdeOrder() ?? _defaultIdeOrder) {
    if (name == 'androidStudio') {
      if (await _hasAndroidStudio()) {
        return 'androidStudio';
      }
    } else if (await _hasIdeCli(name)) {
      return 'vscode:$name';
    }
  }
  return null;
}

Future<bool> _hasAndroidStudio() async {
  if (await _hasCommand('studio')) {
    return true;
  }
  for (final bin in _androidStudioBinaries()) {
    // macOS/Windows 条目为绝对路径；Linux 条目为命令名（如 studio）。
    final isPath = bin.contains('/') || bin.contains('\\');
    if (isPath ? File(bin).existsSync() : await _hasCommand(bin)) {
      return true;
    }
  }
  return false;
}

Future<String?> _firstAvailable(List<String> commands) async {
  for (final command in commands) {
    if (await _hasIdeCli(command)) {
      return command;
    }
  }
  return null;
}

List<String> _androidStudioBinaries() {
  if (Platform.isMacOS) {
    return <String>[
      '/Applications/Android Studio.app/Contents/MacOS/studio',
      '/Applications/Android Studio Preview.app/Contents/MacOS/studio',
    ];
  }
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    return <String>[
      r'C:\Program Files\Android\Android Studio\bin\studio64.exe',
      r'C:\Program Files\Android\Android Studio Preview\bin\studio64.exe',
      if (localAppData != null)
        '$localAppData\\Programs\\Android Studio\\bin\\studio64.exe',
    ];
  }
  return <String>['studio', 'android-studio'];
}

Future<bool> _launchIde(
  String ide,
  String path,
  int line,
  int? column,
) async {
  final location =
      column != null ? '$path:$line:$column' : '$path:$line';
  if (ide.startsWith('vscode')) {
    final cli = ide.contains(':') ? ide.split(':')[1] : null;
    if (cli == null || cli.isEmpty) {
      return false;
    }
    final resolved = await _resolveCliPath(cli);
    if (resolved == null) {
      return false;
    }
    return _runChecked(resolved, <String>[
      ...(_ideCliSubcommands[cli] ?? const <String>[]),
      '-g', location,
    ]);
  }
  if (ide == 'androidStudio') {
    // macOS：AS 注册的是 idea:// 协议（未注册 jetbrains://，深链无人处理；
    // 已运行实例经原生 launcher 转发时 --line/--column 被丢弃）。
    // idea://open 对 AS 已打开项目内的文件可精确定位行列；项目外文件
    // JetBrains 仅能打开、无法定位（平台限制，需在 AS 中打开该项目才能定位）。
    if (Platform.isMacOS) {
      final query = 'file=${Uri.encodeComponent(path)}&line=$line'
          '${column != null ? '&column=$column' : ''}';
      if (await _runChecked('open', <String>['idea://open?$query'])) {
        return true;
      }
    }
    // 非 macOS：命令行启动器，官方参数为 --line/--column，
    // 且选项必须位于文件路径之前。
    for (final bin in _androidStudioBinaries()) {
      if (await _hasCommand(bin) || File(bin).existsSync()) {
        final args = <String>[
          '--line',
          '$line',
          if (column != null) ...<String>['--column', '$column'],
          path,
        ];
        if (await _runChecked(bin, args)) {
          return true;
        }
        // 旧版本不识别 --column 时退化为仅 --line 重试。
        if (column != null) {
          if (await _runChecked(
            bin,
            <String>['--line', '$line', path],
          )) {
            return true;
          }
        }
      }
    }
    return false;
  }
  return false;
}

Future<void> _copyToClipboard(String text) async {
  try {
    if (Platform.isMacOS) {
      final process = await Process.start('pbcopy', const <String>[]);
      process.stdin.write(text);
      await process.stdin.close();
      await process.exitCode;
    } else if (Platform.isLinux) {
      var process = await Process.start(
        'xclip',
        const <String>['-selection', 'clipboard'],
      );
      process.stdin.write(text);
      await process.stdin.close();
      await process.exitCode;
    } else if (Platform.isWindows) {
      final process = await Process.start(
        'clip',
        const <String>[],
        runInShell: true,
      );
      process.stdin.write(text);
      await process.stdin.close();
      await process.exitCode;
    }
  } catch (_) {
    // 剪贴板不可用时忽略。
  }
}

String _toFilePath(String uri) {
  try {
    final parsed = Uri.parse(uri);
    if (parsed.scheme == 'file') {
      return parsed.toFilePath();
    }
  } catch (_) {
    // 非 URI 格式，原样返回。
  }
  return uri;
}

/// 从 isolate 的 file:/// 库 uri 提取 Flutter 项目根目录。
/// 优先用 flutter_build 目录标记；退而用 /lib/ 前缀。
String? _projectRootFor(List<String> fileUris) {
  final paths = <String>[];
  for (final uri in fileUris) {
    try {
      final parsed = Uri.parse(uri);
      if (parsed.scheme != 'file') continue;
      // Windows 统一为正斜杠，后续标记匹配与 File 均可直接使用。
      paths.add(parsed.toFilePath().replaceAll('\\', '/'));
    } catch (_) {
      // 跳过非法 URI。
    }
  }
  for (final path in paths) {
    const marker = '/.dart_tool/flutter_build/';
    final idx = path.indexOf(marker);
    if (idx > 0) return path.substring(0, idx);
  }
  for (final path in paths) {
    final idx = path.indexOf('/lib/');
    if (idx > 0) return path.substring(0, idx);
  }
  return null;
}

/// 读取项目的 .dart_tool/package_config.json，返回 包名 → 包根路径。
Map<String, String>? _readPackageRoots(String projectRoot) {
  try {
    final file = File('$projectRoot/.dart_tool/package_config.json');
    if (!file.existsSync()) return null;
    final parsed = jsonDecode(file.readAsStringSync());
    if (parsed is! Map<String, Object?>) return null;
    final packages = parsed['packages'];
    if (packages is! List) return null;
    final roots = <String, String>{};
    for (final pkg in packages) {
      if (pkg is! Map) continue;
      final name = pkg['name']?.toString();
      final rootUri = pkg['rootUri']?.toString();
      if (name == null || rootUri == null) continue;
      var root = rootUri.startsWith('file://')
          ? _toFilePath(rootUri)
          : _normalizeLocalPath('$projectRoot/.dart_tool/$rootUri');
      root = root.replaceAll('\\', '/');
      while (root.endsWith('/')) {
        root = root.substring(0, root.length - 1);
      }
      roots[name] = root;
    }
    return roots;
  } catch (_) {
    return null;
  }
}

/// 归一化本机路径（处理 ../ 与 ./，package_config 的相对 rootUri 用）。
String _normalizeLocalPath(String p) {
  final abs = p.startsWith('/');
  final out = <String>[];
  for (final seg in p.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return (abs ? '/' : '') + out.join('/');
}

// ---------------------------------------------------------------------------
// 进程执行辅助
// ---------------------------------------------------------------------------

Future<bool> _hasCommand(String command) async {
  try {
    // Windows 无 which，用自带的 where。
    final result = Platform.isWindows
        ? await Process.run('where', <String>[command])
        : await Process.run('which', <String>[command]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<bool> _runChecked(String command, List<String> args) async {
  try {
    // Windows：CLI 多为 .cmd 批处理（code/cursor 等），CreateProcess
    // 不会解析 .cmd，须走 shell。
    final result = await Process.run(
      command,
      args,
      runInShell: Platform.isWindows,
    );
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
