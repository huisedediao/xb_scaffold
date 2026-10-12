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

/// App 端 XBUmeIdeJump.eventId，双端约定一致。
const String kEventKind = 'xb_ume:openSource';

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
ServerSocket? _lockServer;

/// 用户主目录：Windows 用 USERPROFILE（HOME 通常不存在），其余用 HOME。
final String _home =
    Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';

void _printUsage() {
  print('''
用法:
  dart run xb_ume:ide --install [--ide-order "qodercn,cursor,code"] [--ide ...]  安装并启动守护进程（macOS/Windows）
  dart run xb_ume:ide --configure [--ide-order "..."] [--show]                   查看/修改 IDE 优先级
  dart run xb_ume:ide --uninstall                                卸载
  dart run xb_ume:ide --daemon [--ide ...]                       前台运行守护进程
  dart run xb_ume:ide --uri <ws-url> [--ide ...]                 手动监听单个 VM service''');
}

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index >= 0 && index + 1 < args.length) {
    return args[index + 1];
  }
  return null;
}

Future<void> main(List<String> args) async {
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
  final ide = _argValue(args, '--ide') ?? 'auto';
  final uri = _argValue(args, '--uri');
  if (uri != null) {
    await _runSingleSession(uri, ide);
    return;
  }
  if (args.contains('--daemon')) {
    await runDaemon(ide);
    return;
  }
  _printUsage();
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
  final installDir = Directory('$_home/$kInstallDirName');
  await installDir.create(recursive: true);
  final deployedScript =
      '${installDir.path}${Platform.pathSeparator}ide.dart';
  await File(deployedScript).writeAsString(File(scriptPath).readAsStringSync());

  final dartBin = Platform.resolvedExecutable;
  final ide = _argValue(args, '--ide') ?? 'auto';

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
  print('[xbume-ide] 安装完成，守护进程已启动。');
  print('  注册: $detailPath');
  print('  脚本 : $deployedScript');
  print('  日志 : $logPath');
  print('卸载: dart run xb_ume:ide --uninstall');
}

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
  final dir = Directory('$_home/$kInstallDirName');
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

File _configFile() => File('$_home/$kInstallDirName/$kConfigName');

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
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'ideOrder': order,
      'updatedAt': DateTime.now().toIso8601String(),
    }),
  );
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
        if (other != null && other != pid) {
          await Process.run('kill', <String>['-9', '$other']);
        }
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
  server.listen(_onLockConnection);
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

/// 持锁侧：收到接管令牌即退出。
void _onLockConnection(Socket socket) {
  socket.listen((data) {
    if (utf8.decode(data, allowMalformed: true).contains(kEvictToken)) {
      print('[xbume-ide] 检测到新实例接管，本实例退出。');
      _lockServer?.close();
      exit(0);
    }
  });
}

Future<void> runDaemon(String ide) async {
  await _acquireSingletonLock();
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
  final session = _Session(wsUrl, 'manual', ide);
  _sessions[wsUrl] = session;
  await session.connect();
  print('[xbume-ide] 手动监听中，Ctrl-C 退出。');
  await Completer<void>().future;
}

Future<void> _poll(String ide) async {
  if (_polling) return;
  _polling = true;
  try {
    final discovered = await _discoverLocalVmServices();

    // 接入新会话。
    for (final entry in discovered.entries) {
      if (_sessions.containsKey(entry.key)) {
        continue;
      }
      final session = _Session(
        entry.key,
        entry.value.$1,
        ide,
        fingerprint: entry.value.$2,
      );
      _sessions[entry.key] = session;
      await session.connect();
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
// VM service 自动发现：扫描本机回环监听端口并探测 VM service 特征。
//
// flutter run / IDE 运行按钮启动的调试会话，其 VM service 总会以某种形式
// 在本机回环地址上可达：flutter 工具进程（dart）建立的主机端监听代理、
// adb forward / hdc fport 产生的监听端口、或桌面端 VM service 直接监听。
// 对每个监听端口请求 GET /getVM，返回 {"result":{"type":"VM",...}}
// 即判定为 VM service（DevTools 返回 HTML，adb/hdc 服务无此响应）。
// 以 isolates id 组合作为实例指纹，避免同一实例经多端口重复接入。
// ---------------------------------------------------------------------------

Future<Map<String, (String, String)>> _discoverLocalVmServices() async {
  final ports = await _loopbackListeningPorts();
  final found = <String, (String, String)>{};
  await Future.wait(ports.map((port) async {
    final fingerprint = await _probeVmServiceFingerprint(port);
    if (fingerprint == null) return;
    if (_knownFingerprints.contains(fingerprint)) return;
    found['ws://127.0.0.1:$port/ws'] = ('port:$port', fingerprint);
  }));
  return found;
}

/// 列出本机回环地址上的 TCP 监听端口。
Future<List<int>> _loopbackListeningPorts() async {
  final ports = <int>{};
  final String output;
  if (Platform.isWindows) {
    // Windows 无 lsof，用自带的 netstat：TCP 127.0.0.1:PORT ... LISTENING pid。
    output = await _runText('netstat', const <String>['-ano']);
  } else {
    output = await _runText(
      'lsof',
      const <String>['-nP', '-iTCP', '-sTCP:LISTEN'],
    );
  }
  final pattern = RegExp(r'(?:127\.0\.0\.1|\*|\[::1\]):(\d+)\s');
  for (final line in output.split('\n')) {
    if (Platform.isWindows && !line.contains('LISTENING')) {
      continue;
    }
    final match = pattern.firstMatch(line);
    if (match != null) {
      ports.add(int.parse(match.group(1)!));
    }
  }
  return ports.toList()..sort();
}

/// 探测端口是否为 VM service；命中时返回实例指纹（isolates id 组合）。
Future<String?> _probeVmServiceFingerprint(int port) async {
  HttpClient? client;
  try {
    client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 800);
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port/getVM'))
        .timeout(const Duration(seconds: 2));
    final response =
        await request.close().timeout(const Duration(seconds: 2));
    if (response.statusCode != 200) {
      return null;
    }
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 2));
    final parsed = jsonDecode(body);
    if (parsed is! Map<String, Object?>) {
      return null;
    }
    final result = parsed['result'];
    if (result is! Map<String, Object?> || result['type'] != 'VM') {
      return null;
    }
    final isolates = result['isolates'];
    if (isolates is List && isolates.isNotEmpty) {
      return isolates
          .map((e) => e is Map<String, Object?> ? '${e['id']}' : '')
          .join('|');
    }
    return 'vm:${result['name']}';
  } catch (_) {
    return null;
  } finally {
    client?.close(force: true);
  }
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
    _handle(data);
  }

  Future<void> _handle(Map<String, Object?> data) async {
    final file = data['file']?.toString();
    final line = int.tryParse('${data['line']}');
    final column = int.tryParse('${data['column']}');
    print('[xbume-ide] 收到跳转请求 ($source): $file:$line:$column');
    await openInIde(file: file, line: line, column: column, mode: ide);
  }

  void _close() {
    if (!alive) return;
    alive = false;
    try {
      _socket?.close();
    } catch (_) {
      // ignored
    }
    final fp = fingerprint;
    if (fp != null) {
      _knownFingerprints.remove(fp);
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
    return _runChecked(resolved, <String>['-g', location]);
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

Future<String> _runText(String command, List<String> args) async {
  try {
    final result = await Process.run(command, args);
    return '${result.stdout}';
  } catch (_) {
    return '';
  }
}
