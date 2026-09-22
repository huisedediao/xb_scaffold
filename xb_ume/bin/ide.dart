// xb_ume IDE 跳转守护脚本。
//
// 与被调试 App 内的 xb_ume 联动：App 中双击链条行会经 VM service
// Extension 流发出 `xb_ume:openSource` 事件，本脚本接收后在本机唤起
// IDE（VS Code / Android Studio）定位到对应源码行列。
//
// 用法（零新增依赖，运行于宿主机）：
//   dart run xb_ume:ide --install [--ide auto|qodercn|cursor|trae|windsurf|code|androidStudio]
//       一次性安装：注册 macOS LaunchAgent（登录自启 + 崩溃自拉起）并立即启动；
//   dart run xb_ume:ide --uninstall
//       卸载守护进程与安装文件；
//   dart run xb_ume:ide --daemon [--ide ...]
//       前台运行守护进程（不注册自启）；
//   dart run xb_ume:ide --uri <ws-url> [--ide ...]
//       手动监听单个 VM service（自动发现不可用时的兜底）。
//
// 自动发现（daemon 模式）：
//   - adb / hdc 设备：轮询设备日志中 Flutter 标准输出
//     "A Dart VM Service on ... is available at: http://127.0.0.1:PORT/.../"
//     并做端口转发（adb forward / hdc fport）后连接；
//   - macOS 桌面会话：dns-sd 浏览 _dartvmService._tcp（best-effort）。
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

const Duration kPollInterval = Duration(seconds: 3);

final String _home = Platform.environment['HOME'] ?? '.';

void _printUsage() {
  print('''
用法:
  dart run xb_ume:ide --install [--ide auto|qodercn|cursor|trae|windsurf|code|androidStudio]  安装并启动守护进程（仅一次）
  dart run xb_ume:ide --uninstall                                  卸载
  dart run xb_ume:ide --daemon [--ide ...]                         前台运行守护进程
  dart run xb_ume:ide --uri <ws-url> [--ide ...]                   手动监听单个 VM service''');
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
  if (!Platform.isMacOS) {
    print('[xbume-ide] --install 仅支持 macOS；其他平台请用 --daemon 前台运行。');
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
      '${installDir.path}/ide.dart';
  await File(deployedScript).writeAsString(File(scriptPath).readAsStringSync());

  final dartBin = Platform.resolvedExecutable;
  final logPath = '$_home/Library/Logs/xb_ume_ide.log';
  final ide = _argValue(args, '--ide') ?? 'auto';
  final plistPath = '$_home/Library/LaunchAgents/$kPlistName';
  await Directory('$_home/Library/LaunchAgents').create(recursive: true);
  await File(plistPath).writeAsString(_buildPlist(
    dartBin: dartBin,
    scriptPath: deployedScript,
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
      exitCode = 1;
      return;
    }
  }
  print('[xbume-ide] 安装完成，守护进程已启动。');
  print('  plist: $plistPath');
  print('  脚本 : $deployedScript');
  print('  日志 : $logPath');
  print('卸载: dart run xb_ume:ide --uninstall');
}

Future<void> uninstall() async {
  final uid = (await Process.run('id', <String>['-u'])).stdout.toString().trim();
  final plistPath = '$_home/Library/LaunchAgents/$kPlistName';
  await Process.run('launchctl', <String>['bootout', 'gui/$uid', plistPath]);
  await Process.run('launchctl', <String>['remove', kLabel]);
  final plist = File(plistPath);
  if (plist.existsSync()) {
    await plist.delete();
  }
  final dir = Directory('$_home/$kInstallDirName');
  if (dir.existsSync()) {
    await dir.delete(recursive: true);
  }
  print('[xbume-ide] 已卸载。');
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
// 守护进程
// ---------------------------------------------------------------------------

final Map<String, _Session> _sessions = <String, _Session>{};

/// 已接入 VM service 实例的指纹（isolates id 组合）。
/// 同一调试实例可能经多个端口可达（如 adb forward 与 flutter 工具代理），
/// 以指纹去重避免重复接入。
final Set<String> _knownFingerprints = <String>{};
bool _polling = false;

Future<void> runDaemon(String ide) async {
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
  final output = await _runText(
    'lsof',
    const <String>['-nP', '-iTCP', '-sTCP:LISTEN'],
  );
  final pattern = RegExp(r'(?:127\.0\.0\.1|\*|\[::1\]):(\d+)\s');
  for (final line in output.split('\n')) {
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
    final cli = await _firstAvailable(_vscodeLikeClis);
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

/// macOS 上未安装 shell 命令时，按 app 内置 CLI 兜底查找。
const Map<String, List<String>> _vscodeLikeAppClis =
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

/// 解析 CLI 实际可执行路径：优先 PATH，macOS 下回退 app 内置 CLI。
Future<String?> _resolveCliPath(String cli) async {
  if (await _hasCommand(cli)) {
    return cli;
  }
  if (!Platform.isMacOS) {
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

Future<String?> _detectIde() async {
  for (final cli in _vscodeLikeClis) {
    if (await _hasIdeCli(cli)) {
      return 'vscode:$cli';
    }
  }
  if (await _hasCommand('studio')) {
    return 'androidStudio';
  }
  if (Platform.isMacOS) {
    for (final bin in _androidStudioBinaries()) {
      if (File(bin).existsSync()) {
        return 'androidStudio';
      }
    }
  }
  return null;
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
  return Platform.isMacOS
      ? <String>[
          '/Applications/Android Studio.app/Contents/MacOS/studio',
          '/Applications/Android Studio Preview.app/Contents/MacOS/studio',
        ]
      : <String>['studio', 'android-studio'];
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
    if (Platform.isMacOS) {
      final deepLink =
          'jetbrains://Android-Studio/open?file=$path&line=$line'
          '${column != null ? '&column=$column' : ''}';
      if (await _runChecked('open', <String>[deepLink])) {
        return true;
      }
    }
    for (final bin in _androidStudioBinaries()) {
      final exists = await _hasCommand(bin) || File(bin).existsSync();
      if (exists) {
        final cmd = bin.contains('/') ? bin : bin;
        return _runChecked(
          cmd,
          <String>[path, '--line', '$line'],
        );
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
    final result = await Process.run('which', <String>[command]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<bool> _runChecked(String command, List<String> args) async {
  try {
    final result = await Process.run(command, args);
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
