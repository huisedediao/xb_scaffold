// xb_ume 电脑端 GUI 工具箱（本机 Web GUI）。
//
// 由 `dart run xb_ume:ide --install` 部署到 ~/.xb_ume_ide/ide_gui.dart，
// 与守护脚本 ide.dart 一样零新增依赖、单文件自包含。双击启动器
// （Windows: XBumeGui.bat / macOS: xb_ume_gui.command）或
// `dart run xb_ume:ide --gui` 启动后，本机 HTTP 服务自动打开浏览器页面。
//
// 模块划分（页面 Tab 切换）：
//   1. 设备管理：识别 adb（Android）/ hdc（鸿蒙）/ Xcode 模拟器（iOS 模拟器）
//      / idevice_id（iOS 真机，需 libimobiledevice）连接的设备，可选择；
//   2. 守护进程：状态查询（经 ide.dart 互斥端口 status 协议）、重启、IDE 优先级；
//   3. 日志：选中设备的全量设备日志（logcat / hilog / iOS log stream /
//      idevicesyslog）+ 全部调试会话的 stdout/stderr（flutter run 控制台
//      中 app 输出部分），实时推送、过滤、暂停、清屏、导出。
//
// 后续扩展预留：页面与服务端经 WebSocket 双向通信，消息按 type 区分，
// 可增加 App 消息/文件展示与反向控制（VM service callServiceExtension）。
//
// 用法：
//   dart run xb_ume:ide --install   # 部署本文件并生成启动器
//   dart run xb_ume:ide --gui       # 启动 GUI（等同双击启动器）
//   dart ~/.xb_ume_ide/ide_gui.dart # 直接运行
// ignore_for_file: avoid_print

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// ide.dart 守护进程的互斥端口与协议令牌（双端约定一致）。
const int kDaemonLockPort = 46128;
const String kDaemonStatusToken = 'xbume-ide-status';

/// GUI 服务端口基数（被占用时向后顺延最多 10 个）。
const int kGuiPortBase = 46129;

/// 日志环形缓冲上限（内存保护）。
const int kMaxBufferLines = 5000;

final String _home =
    Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';

Future<void> main(List<String> args) async {
  HttpServer? server;
  var port = kGuiPortBase;
  for (; port < kGuiPortBase + 10; port++) {
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      break;
    } on SocketException {
      // 端口被占用：若是已有 GUI 实例，打开浏览器后退出（单实例语义）。
      if (await pingGui(port)) {
        print('[xbume-gui] 已有实例运行于端口 $port，打开页面后退出。');
        await openBrowser(port);
        return;
      }
    }
  }
  if (server == null) {
    print('[xbume-gui] 端口 $kGuiPortBase 起 10 个均不可用，退出。');
    exitCode = 1;
    return;
  }
  print('[xbume-gui] GUI 服务已启动: http://127.0.0.1:$port （Ctrl-C 退出）');
  await openBrowser(port);
  final state = GuiState();
  state.start();
  try {
    await for (final req in server) {
      unawaited(handleRequest(state, req));
    }
  } finally {
    await state.dispose();
  }
}

// ---------------------------------------------------------------------------
// HTTP / WebSocket 路由
// ---------------------------------------------------------------------------

Future<void> handleRequest(GuiState state, HttpRequest req) async {
  final path = req.uri.path;
  try {
    if (path == '/ping') {
      req.response.write('xbume-gui');
      await req.response.close();
      return;
    }
    if (path == '/') {
      req.response.headers.contentType = ContentType.html;
      req.response.write(guiHtml);
      await req.response.close();
      return;
    }
    if (path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      state.addClient(ws);
      return;
    }
    if (path == '/api/daemon') {
      final status = await queryDaemonStatus();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{
        'running': status != null,
        'pid': status?['pid'],
        'uptimeSec': status?['uptimeSec'],
        'sessions': status?['sessions'] ?? <Object?>[],
        'config': readGuiIdeOrder(),
      }));
      await req.response.close();
      return;
    }
    if (path == '/api/daemon/restart' && req.method == 'POST') {
      final result = await restartDaemon();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(result));
      await req.response.close();
      return;
    }
    if (path == '/api/openconfig' && req.method == 'POST') {
      await openWithSystemApp('$_home/.xb_ume_ide/config.json');
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();
      return;
    }
    if (path == '/api/logs.txt') {
      req.response.headers.contentType = ContentType.text;
      req.response.headers.set(
        'Content-Disposition',
        'attachment; filename="xbume-logs.txt"',
      );
      for (final entry in state.buffer) {
        req.response.write(
          '${entry['ts'] ?? entry['rcv']} [${entry['source']}] '
          '${entry['level']}/${entry['tag']}: ${entry['msg']}\n',
        );
      }
      await req.response.close();
      return;
    }
    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  } catch (e) {
    print('[xbume-gui] 请求处理异常 $path: $e');
    try {
      req.response.statusCode = HttpStatus.internalServerError;
      await req.response.close();
    } catch (_) {
      // ignored
    }
  }
}

// ---------------------------------------------------------------------------
// GUI 状态与模块逻辑
// ---------------------------------------------------------------------------

class GuiState {
  GuiState() : startedAt = DateTime.now();

  final DateTime startedAt;
  final Set<WebSocket> _clients = <WebSocket>{};
  final List<Map<String, Object?>> _buffer = <Map<String, Object?>>[];
  final List<Map<String, Object?>> _pending = <Map<String, Object?>>[];
  final Map<String, _VmSession> _vmSessions = <String, _VmSession>{};
  Timer? _pollTimer;
  Timer? _flushTimer;
  Process? _deviceLogProcess;
  String? _deviceLogKey;
  bool _deviceLogStartFailed = false;
  List<Map<String, String>> devices = <Map<String, String>>[];
  String? selectedId;

  /// 日志环形缓冲（供 HTTP 导出接口读取）。
  List<Map<String, Object?>> get buffer => _buffer;

  void start() {
    unawaited(poll());
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(poll()),
    );
    _flushTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _flush();
    });
  }

  Future<void> dispose() async {
    _pollTimer?.cancel();
    _flushTimer?.cancel();
    _deviceLogProcess?.kill();
    for (final session in _vmSessions.values) {
      session.close();
    }
    for (final ws in List<WebSocket>.of(_clients)) {
      try {
        await ws.close();
      } catch (_) {
        // ignored
      }
    }
  }

  // -- 设备管理模块 ----------------------------------------------------------

  /// 轮询设备列表并维护日志源生命周期。
  Future<void> poll() async {
    try {
      devices = await discoverDevices();
    } catch (e) {
      print('[xbume-gui] 设备发现异常: $e');
    }
    broadcast(<String, Object?>{'type': 'devices', 'devices': devices});
    Map<String, String>? selected;
    for (final device in devices) {
      if (device['id'] == selectedId) {
        selected = device;
      }
    }
    if (selected == null) {
      await _stopDeviceLogSource();
    } else {
      await _ensureDeviceLogSource(selected);
    }
    await _syncVmSessions();
  }

  Future<void> selectDevice(String? id) async {
    if (selectedId == id) {
      return;
    }
    selectedId = id;
    _buffer.clear();
    _pending.clear();
    await _stopDeviceLogSource();
    for (final device in devices) {
      if (device['id'] == id) {
        await _ensureDeviceLogSource(device);
      }
    }
    broadcast(<String, Object?>{'type': 'cleared'});
    broadcast(<String, Object?>{'type': 'devices', 'devices': devices});
  }

  // -- 日志模块 --------------------------------------------------------------

  String _sourceForPlatform(String platform) {
    switch (platform) {
      case 'android':
        return 'logcat';
      case 'ohos':
        return 'hilog';
      default:
        return 'ios';
    }
  }

  List<String>? _deviceLogCommand(Map<String, String> device) {
    final id = device['id'] ?? '';
    switch (device['platform']) {
      case 'android':
        return <String>['adb', '-s', id, 'logcat', '-v', 'time'];
      case 'ohos':
        return <String>['hdc', '-t', id, 'hilog'];
      case 'ios-sim':
        return <String>[
          'xcrun',
          'simctl',
          'spawn',
          id,
          'log',
          'stream',
          '--style',
          'compact',
        ];
      case 'ios-real':
        return <String>['idevicesyslog', '-u', id];
      default:
        return null;
    }
  }

  Future<void> _ensureDeviceLogSource(Map<String, String> device) async {
    final key = '${device['id']}@${device['platform']}';
    if (_deviceLogKey == key && _deviceLogProcess != null) {
      return;
    }
    await _stopDeviceLogSource();
    final command = _deviceLogCommand(device);
    if (command == null) {
      return;
    }
    final source = _sourceForPlatform(device['platform'] ?? '');
    try {
      final process = await Process.start(command.first, command.sublist(1));
      _deviceLogProcess = process;
      _deviceLogKey = key;
      _deviceLogStartFailed = false;
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => addLog(line, source));
      unawaited(process.exitCode.then((_) {
        if (_deviceLogProcess == process) {
          _deviceLogProcess = null;
          _deviceLogKey = null;
        }
      }));
    } catch (e) {
      // 避免每 3s 轮询刷屏：同一设备只提示一次。
      if (!_deviceLogStartFailed) {
        _deviceLogStartFailed = true;
        addLog('[GUI] 无法启动 ${command.first}（未安装或不在 PATH）: $e', source);
      }
    }
  }

  Future<void> _stopDeviceLogSource() async {
    _deviceLogProcess?.kill();
    _deviceLogProcess = null;
    _deviceLogKey = null;
  }

  /// 同步 VM service stdout 会话（flutter run 控制台输出来源）。
  Future<void> _syncVmSessions() async {
    final status = await queryDaemonStatus();
    final uris = <String>{};
    if (status != null) {
      final sessions = status['sessions'];
      if (sessions is List) {
        for (final session in sessions) {
          if (session is Map) {
            final uri = session['uri']?.toString();
            if (uri != null && uri.isNotEmpty) {
              uris.add(uri);
            }
          }
        }
      }
    }
    for (final uri in uris) {
      if (!_vmSessions.containsKey(uri)) {
        final session = _VmSession(uri, _addFlutterLine);
        _vmSessions[uri] = session;
        unawaited(session.connect());
      }
    }
    for (final key in _vmSessions.keys.toList()) {
      if (!uris.contains(key)) {
        _vmSessions.remove(key)!.close();
      }
    }
  }

  void _addFlutterLine(String line, bool isStderr) {
    final entry = makeLogEntry(line, isStderr ? 'flutter-stderr' : 'flutter');
    entry['tag'] = isStderr ? 'stderr' : 'stdout';
    addEntry(entry);
  }

  void addLog(String raw, String source) {
    addEntry(makeLogEntry(raw, source));
  }

  void addEntry(Map<String, Object?> entry) {
    entry['rcv'] = _clock();
    _buffer.add(entry);
    if (_buffer.length > kMaxBufferLines) {
      _buffer.removeRange(0, _buffer.length - kMaxBufferLines);
    }
    _pending.add(entry);
  }

  void _flush() {
    if (_pending.isEmpty) {
      return;
    }
    final items = List<Map<String, Object?>>.of(_pending);
    _pending.clear();
    broadcast(<String, Object?>{'type': 'logs', 'items': items});
  }

  // -- 客户端与广播 ----------------------------------------------------------

  void addClient(WebSocket ws) {
    _clients.add(ws);
    // 新客户端立即全量同步（设备 + 已缓冲日志 + 当前选中）。
    ws.add(jsonEncode(<String, Object?>{
      'type': 'snapshot',
      'devices': devices,
      'selected': selectedId,
      'items': _buffer,
    }));
    ws.listen((dynamic message) {
      if (message is! String) {
        return;
      }
      Object? parsed;
      try {
        parsed = jsonDecode(message);
      } catch (_) {
        return;
      }
      if (parsed is! Map) {
        return;
      }
      if (parsed['type'] == 'select') {
        unawaited(selectDevice(parsed['id']?.toString()));
      } else if (parsed['type'] == 'refresh') {
        unawaited(poll());
      }
    }, onDone: () => _clients.remove(ws), onError: (_) => _clients.remove(ws));
  }

  void broadcast(Map<String, Object?> message) {
    if (_clients.isEmpty) {
      return;
    }
    final text = jsonEncode(message);
    for (final ws in _clients.toList()) {
      try {
        ws.add(text);
      } catch (_) {
        _clients.remove(ws);
      }
    }
  }
}

class _VmSession {
  _VmSession(this.uri, this.onLine);

  final String uri;
  final void Function(String line, bool isStderr) onLine;
  WebSocket? _socket;
  String _remainder = '';

  Future<void> connect() async {
    try {
      final socket = await WebSocket.connect(uri);
      _socket = socket;
      socket.listen(
        _onData,
        onDone: () => _socket = null,
        onError: (dynamic _) => _socket = null,
      );
      socket.add(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': '1',
        'method': 'streamListen',
        'params': <String>['Stdout'],
      }));
    } catch (e) {
      print('[xbume-gui] VM service 连接失败 $uri: $e');
      _socket = null;
    }
  }

  void _onData(dynamic message) {
    if (message is! String) {
      return;
    }
    Object? parsed;
    try {
      parsed = jsonDecode(message);
    } catch (_) {
      return;
    }
    if (parsed is! Map) {
      return;
    }
    final params = parsed['params'];
    if (params is! Map) {
      return;
    }
    final event = params['event'];
    if (event is! Map || event['kind'] != 'Stdout') {
      return;
    }
    final bytes = event['bytes'];
    if (bytes is! String) {
      return;
    }
    final isStderr = event['source'] == 'Stderr';
    final text = utf8.decode(base64.decode(bytes), allowMalformed: true);
    final lines = (_remainder + text).split('\n');
    _remainder = lines.removeLast();
    for (final line in lines) {
      final trimmed = line.trimRight();
      if (trimmed.isNotEmpty) {
        onLine(trimmed, isStderr);
      }
    }
  }

  void close() {
    try {
      _socket?.close();
    } catch (_) {
      // ignored
    }
    _socket = null;
  }
}

// ---------------------------------------------------------------------------
// 守护进程控制模块
// ---------------------------------------------------------------------------

/// 查询 daemon 状态（经互斥端口 status 协议）。未运行返回 null。
Future<Map<String, Object?>?> queryDaemonStatus() async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      kDaemonLockPort,
      timeout: const Duration(milliseconds: 800),
    );
    final completer = Completer<Map<String, Object?>?>();
    late StreamSubscription<List<int>> sub;
    sub = socket.listen((data) {
      if (!completer.isCompleted) {
        try {
          final decoded = jsonDecode(utf8.decode(data));
          completer.complete(decoded is Map
              ? <String, Object?>{
                  for (final entry in decoded.entries)
                    entry.key.toString(): entry.value,
                }
              : null);
        } catch (_) {
          completer.complete(null);
        }
      }
      unawaited(sub.cancel());
    }, onDone: () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }, onError: (dynamic _) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });
    socket.write(kDaemonStatusToken);
    await socket.flush();
    final result = await completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => null,
    );
    return result;
  } catch (_) {
    return null;
  } finally {
    socket?.destroy();
  }
}

/// 重启守护进程：杀掉所有实例 → detached 启动部署副本 → 等待就绪。
/// 依赖 ide.dart 单实例接管锁：新实例自动成为唯一实例。
Future<Map<String, Object?>> restartDaemon() async {
  final script = File('$_home/.xb_ume_ide/ide.dart');
  if (!script.existsSync()) {
    return <String, Object?>{
      'ok': false,
      'message': '未找到守护脚本，请先执行 dart run xb_ume:ide --install',
    };
  }
  await killOtherDaemons();
  try {
    await Process.start(
      Platform.resolvedExecutable,
      <String>[script.path, '--daemon'],
      mode: ProcessStartMode.detached,
    );
  } catch (e) {
    return <String, Object?>{'ok': false, 'message': '启动失败: $e'};
  }
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (await queryDaemonStatus() != null) {
      return <String, Object?>{'ok': true, 'message': '守护进程已重启'};
    }
  }
  return <String, Object?>{
    'ok': false,
    'message': '重启后未检测到 daemon（可查看 ~/.xb_ume_ide/daemon.log）',
  };
}

/// 停止本机上其他 `ide.dart --daemon` 进程（排除自身）。
/// 复制自 bin/ide.dart 的 _killOtherDaemons（单文件部署无法共享代码）。
Future<void> killOtherDaemons() async {
  try {
    if (Platform.isWindows) {
      final ps = "Get-CimInstance Win32_Process | Where-Object { "
          "\$_.CommandLine -match 'ide\\.dart' -and "
          "\$_.CommandLine -match '--daemon' -and \$_.ProcessId -ne $pid } | "
          "ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }";
      await Process.run('powershell', <String>['-NoProfile', '-Command', ps]);
    } else {
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
    // 清理失败不阻塞。
  }
}

/// 读取 daemon 配置中的 IDE 顺序（供页面展示）。
Map<String, Object?> readGuiIdeOrder() {
  try {
    final file = File('$_home/.xb_ume_ide/config.json');
    if (!file.existsSync()) {
      return const <String, Object?>{};
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map && decoded['ideOrder'] is List) {
      return <String, Object?>{'ideOrder': decoded['ideOrder']};
    }
  } catch (_) {
    // ignored
  }
  return const <String, Object?>{};
}

// ---------------------------------------------------------------------------
// 设备发现与日志行解析（纯函数，供单测覆盖）
// ---------------------------------------------------------------------------

/// 发现本机连接的设备：Android（adb）/ 鸿蒙（hdc）/ iOS（仅 macOS）。
Future<List<Map<String, String>>> discoverDevices() async {
  final devices = <Map<String, String>>[];
  try {
    final result = await Process.run('adb', <String>['devices', '-l']);
    devices.addAll(parseAdbDevices(result.stdout.toString()));
  } catch (_) {
    // adb 未安装或不在 PATH。
  }
  try {
    final result = await Process.run('hdc', <String>['list', 'targets']);
    for (final id in parseHdcTargets(result.stdout.toString())) {
      devices.add(<String, String>{
        'id': id,
        'platform': 'ohos',
        'name': id,
        'state': 'device',
      });
    }
  } catch (_) {
    // hdc 未安装或不在 PATH。
  }
  if (Platform.isMacOS) {
    try {
      final result = await Process.run(
        'xcrun',
        <String>['simctl', 'list', 'devices', 'booted'],
      );
      for (final sim in parseBootedSimulators(result.stdout.toString())) {
        devices.add(<String, String>{
          'id': sim['udid']!,
          'platform': 'ios-sim',
          'name': sim['name']!,
          'state': 'device',
        });
      }
    } catch (_) {
      // Xcode 命令行工具不可用。
    }
    try {
      final result = await Process.run('idevice_id', <String>['-l']);
      for (final udid in parseIdeviceIds(result.stdout.toString())) {
        devices.add(<String, String>{
          'id': udid,
          'platform': 'ios-real',
          'name': udid,
          'state': 'device',
        });
      }
    } catch (_) {
      // libimobiledevice 未安装（iOS 真机日志为 best-effort 能力）。
    }
  }
  return devices;
}

/// 解析 `adb devices -l` 输出。
List<Map<String, String>> parseAdbDevices(String out) {
  final devices = <Map<String, String>>[];
  for (var line in out.split('\n')) {
    line = line.trim();
    if (line.isEmpty ||
        line.startsWith('List of devices') ||
        line.startsWith('*')) {
      continue;
    }
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      continue;
    }
    var name = parts[0];
    for (final part in parts.skip(2)) {
      if (part.startsWith('model:')) {
        name = part.substring(6);
      }
    }
    devices.add(<String, String>{
      'id': parts[0],
      'platform': 'android',
      'name': name,
      'state': parts[1],
    });
  }
  return devices;
}

/// 解析 `hdc list targets` 输出（每行一个设备 key）。
List<String> parseHdcTargets(String out) {
  final targets = <String>[];
  for (var line in out.split('\n')) {
    line = line.trim();
    if (line.isEmpty || line.contains('error') || line.startsWith('[')) {
      continue;
    }
    targets.add(line);
  }
  return targets;
}

/// 解析 `xcrun simctl list devices booted` 输出中的已启动模拟器。
List<Map<String, String>> parseBootedSimulators(String out) {
  final result = <Map<String, String>>[];
  final re = RegExp(r'^\s*(.+?)\s+\(([0-9A-Fa-f-]{36})\)\s+\(Booted\)');
  for (final line in out.split('\n')) {
    final match = re.firstMatch(line);
    if (match != null) {
      result.add(<String, String>{
        'name': match.group(1)!.trim(),
        'udid': match.group(2)!,
      });
    }
  }
  return result;
}

/// 解析 `idevice_id -l` 输出（每行一个 UDID；新式 25 位或旧式 40 位 hex）。
List<String> parseIdeviceIds(String out) {
  final ids = <String>[];
  final re = RegExp(r'^[0-9A-Fa-f-]{20,}$');
  for (var line in out.split('\n')) {
    line = line.trim();
    if (line.isNotEmpty && re.hasMatch(line)) {
      ids.add(line);
    }
  }
  return ids;
}

Map<String, String>? parseLogcatLine(String line) {
  // `logcat -v time`：10-12 14:23:01.123 D/Flutter( 1234): message
  final re = RegExp(
    r'^(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+([VDIWEF])/(.+?)\s*\(\s*(\d+)\):\s?(.*)$',
  );
  final match = re.firstMatch(line);
  if (match == null) {
    return null;
  }
  return <String, String>{
    'ts': match.group(1)!,
    'level': match.group(2)!,
    'tag': match.group(3)!,
    'msg': match.group(5)!,
  };
}

Map<String, String>? parseHilogLine(String line) {
  // hilog：01-01 08:00:00.000  1234  5678 I C01800/MyTag: message
  final re = RegExp(
    r'^(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+(\d+)\s+(\d+)\s+([VDIWEF])\s+(\S+):\s?(.*)$',
  );
  final match = re.firstMatch(line);
  if (match == null) {
    return null;
  }
  return <String, String>{
    'ts': match.group(1)!,
    'level': match.group(4)!,
    'tag': match.group(5)!,
    'msg': match.group(6)!,
  };
}

Map<String, String>? parseIosLogLine(String line) {
  // idevicesyslog：Oct 12 14:23:01  MyApp[1234] <Notice>: message
  final syslog = RegExp(
    r'^(\w{3}\s+\d+\s+[\d:]+)\s+(\S+?)\[(\d+)\]\s+<(\w+)>:\s?(.*)$',
  );
  var match = syslog.firstMatch(line);
  if (match != null) {
    return <String, String>{
      'ts': match.group(1)!,
      'level': _iosLevel(match.group(4)!),
      'tag': match.group(2)!,
      'msg': match.group(5)!,
    };
  }
  // simctl log stream --style compact：
  // 2026-10-12 14:23:01.123-0700  MyApp[1234:5678] [Notice] message
  final compact = RegExp(
    r'^(\d{4}-\d{2}-\d{2}\s+[\d:.]+(?:[+-]\d{4})?)\s+(?:\S+\s+)?(\S+?)\[(\d+)[^\]]*\]\s*(?:\[(\w+)\]\s*)?(.*)$',
  );
  match = compact.firstMatch(line);
  if (match != null) {
    final levelWord = match.group(4);
    return <String, String>{
      'ts': match.group(1)!,
      'level': levelWord == null ? 'I' : _iosLevel(levelWord),
      'tag': match.group(2)!,
      'msg': match.group(5)!,
    };
  }
  return null;
}

String _iosLevel(String word) {
  switch (word.toLowerCase()) {
    case 'error':
    case 'fault':
      return 'E';
    case 'warning':
      return 'W';
    case 'debug':
      return 'D';
    case 'notice':
    case 'info':
    case 'default':
      return 'I';
    default:
      return 'I';
  }
}

/// 任意来源的日志行 → 结构化条目（解析失败时保留原文兜底）。
Map<String, Object?> makeLogEntry(String raw, String source) {
  Map<String, String>? parsed;
  if (source == 'logcat') {
    parsed = parseLogcatLine(raw);
  } else if (source == 'hilog') {
    parsed = parseHilogLine(raw);
  } else if (source == 'ios') {
    parsed = parseIosLogLine(raw);
  }
  final entry = parsed ?? <String, String>{
    'ts': '',
    'level': 'I',
    'tag': source,
    'msg': raw,
  };
  return <String, Object?>{
    'ts': entry['ts'],
    'level': entry['level'],
    'tag': entry['tag'],
    'msg': entry['msg'],
    'source': source,
  };
}

String _clock() {
  final now = DateTime.now();
  return '${now.hour.toString().padLeft(2, '0')}:'
      '${now.minute.toString().padLeft(2, '0')}:'
      '${now.second.toString().padLeft(2, '0')}';
}

// ---------------------------------------------------------------------------
// 系统辅助
// ---------------------------------------------------------------------------

Future<bool> pingGui(int port) async {
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(milliseconds: 500);
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port/ping'))
        .timeout(const Duration(seconds: 1));
    final response = await request.close().timeout(const Duration(seconds: 1));
    final body = await response.transform(utf8.decoder).join();
    return body.trim() == 'xbume-gui';
  } catch (_) {
    return false;
  } finally {
    client?.close();
  }
}

Future<void> openBrowser(int port) async {
  final url = 'http://127.0.0.1:$port';
  try {
    if (Platform.isWindows) {
      await Process.start('cmd', <String>['/c', 'start', '', url],
          runInShell: true);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[url]);
    } else {
      await Process.run('xdg-open', <String>[url]);
    }
  } catch (e) {
    print('[xbume-gui] 无法自动打开浏览器，请手动访问: $url ($e)');
  }
}

Future<void> openWithSystemApp(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.start('cmd', <String>['/c', 'start', '', path],
          runInShell: true);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[path]);
    } else {
      await Process.run('xdg-open', <String>[path]);
    }
  } catch (e) {
    print('[xbume-gui] 无法打开文件 $path: $e');
  }
}

// ---------------------------------------------------------------------------
// 内嵌 Web UI
// ---------------------------------------------------------------------------

const String guiHtml = r'''
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>xb_ume 工具箱</title>
<style>
  :root { --bg:#0b0f14; --panel:#131a23; --line:#223041; --fg:#dbe6f0; --dim:#8aa0b4; --acc:#00e5ff; }
  * { box-sizing:border-box; margin:0; padding:0; }
  body { background:var(--bg); color:var(--fg); font:14px/1.5 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif; height:100vh; display:flex; flex-direction:column; }
  header { display:flex; align-items:center; gap:12px; padding:10px 16px; border-bottom:1px solid var(--line); }
  header h1 { font-size:15px; font-weight:600; color:var(--acc); margin-right:12px; }
  .tab { padding:6px 14px; border:1px solid var(--line); border-radius:6px; cursor:pointer; color:var(--dim); }
  .tab.active { color:var(--acc); border-color:var(--acc); }
  #wsdot { width:8px; height:8px; border-radius:50%; background:#e5484d; margin-left:auto; }
  #wsdot.on { background:#46d68c; }
  main { flex:1; overflow:auto; padding:16px; }
  .page { display:none; } .page.active { display:block; }
  table { width:100%; border-collapse:collapse; }
  th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); }
  th { color:var(--dim); font-weight:500; }
  button, select, input { background:var(--panel); color:var(--fg); border:1px solid var(--line); border-radius:6px; padding:6px 12px; font:inherit; }
  button { cursor:pointer; } button:hover { border-color:var(--acc); }
  button.primary { border-color:var(--acc); color:var(--acc); }
  .card { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:16px; margin-bottom:16px; }
  .row { display:flex; align-items:center; gap:10px; flex-wrap:wrap; margin-bottom:10px; }
  .muted { color:var(--dim); }
  .ok { color:#46d68c; } .bad { color:#e5484d; }
  #logview { font:12px/1.45 ui-monospace,Menlo,Consolas,monospace; background:#070b10; border:1px solid var(--line); border-radius:8px; padding:8px; height:calc(100vh - 210px); overflow-y:auto; white-space:pre-wrap; word-break:break-all; }
  .lv-V { color:#8aa0b4; } .lv-D { color:#6fa8dc; } .lv-I { color:#dbe6f0; } .lv-W { color:#f5c451; } .lv-E { color:#ef6a6a; }
  .tag { color:var(--acc); }
  .src { color:#b07de8; }
  label.chk { margin-right:6px; color:var(--dim); cursor:pointer; }
</style>
</head>
<body>
<header>
  <h1>xb_ume 工具箱</h1>
  <div class="tab active" data-tab="devices">设备</div>
  <div class="tab" data-tab="daemon">守护进程</div>
  <div class="tab" data-tab="logs">日志</div>
  <div id="wsdot" title="连接状态"></div>
</header>
<main>
  <section class="page active" id="page-devices">
    <div class="row">
      <button class="primary" onclick="refreshDevices()">刷新设备</button>
      <span class="muted">选中设备将作为「日志」页的设备日志来源</span>
    </div>
    <table>
      <thead><tr><th>选择</th><th>平台</th><th>名称</th><th>设备 ID</th><th>状态</th></tr></thead>
      <tbody id="devrows"><tr><td colspan="5" class="muted">扫描中…</td></tr></tbody>
    </table>
  </section>
  <section class="page" id="page-daemon">
    <div class="card">
      <div class="row"><b>守护进程状态</b><button onclick="refreshDaemon()">刷新</button><button class="primary" onclick="restartDaemon()">重启守护进程</button></div>
      <div id="daemon-status" class="muted">查询中…</div>
    </div>
    <div class="card">
      <div class="row"><b>IDE 优先级</b><button onclick="openConfig()">打开配置文件</button></div>
      <div id="ide-order" class="muted">-</div>
    </div>
  </section>
  <section class="page" id="page-logs">
    <div class="row">
      <label>设备 <select id="logdev" onchange="selectDevice(this.value)"></select></label>
      <label class="chk"><input type="checkbox" id="f-src-device" checked onchange="renderLogs()">设备日志</label>
      <label class="chk"><input type="checkbox" id="f-src-flutter" checked onchange="renderLogs()">Flutter 输出</label>
      <label class="chk"><input type="checkbox" class="f-lv" value="V" checked onchange="renderLogs()">V</label>
      <label class="chk"><input type="checkbox" class="f-lv" value="D" checked onchange="renderLogs()">D</label>
      <label class="chk"><input type="checkbox" class="f-lv" value="I" checked onchange="renderLogs()">I</label>
      <label class="chk"><input type="checkbox" class="f-lv" value="W" checked onchange="renderLogs()">W</label>
      <label class="chk"><input type="checkbox" class="f-lv" value="E" checked onchange="renderLogs()">E</label>
      <input id="f-kw" placeholder="关键字过滤" oninput="renderLogs()">
      <button onclick="togglePause(this)">暂停</button>
      <button onclick="clearLogs()">清屏</button>
      <a href="/api/logs.txt" target="_blank"><button>导出</button></a>
    </div>
    <div id="logview"><span class="muted">暂无日志</span></div>
    <div class="muted" style="margin-top:6px">「Flutter 输出」= 全部调试会话的 stdout/stderr（flutter run 控制台中 app 输出的部分）；「设备日志」= 选中设备的全量系统日志（logcat/hilog/iOS log），包含控制台不打印的内容。</div>
  </section>
</main>
<script>
var ws = null, devices = [], selected = null, logs = [], paused = false;
var platformNames = { android: 'Android', ohos: '鸿蒙', 'ios-sim': 'iOS 模拟器', 'ios-real': 'iOS 真机' };
function connect() {
  ws = new WebSocket('ws://' + location.host + '/ws');
  ws.onopen = function(){ document.getElementById('wsdot').classList.add('on'); };
  ws.onclose = function(){ document.getElementById('wsdot').classList.remove('on'); setTimeout(connect, 1500); };
  ws.onmessage = function(e){
    var msg = JSON.parse(e.data);
    if (msg.type === 'snapshot') { devices = msg.devices; selected = msg.selected; logs = msg.items; renderDevices(); renderLogdev(); renderLogs(); refreshDaemon(); }
    else if (msg.type === 'devices') { devices = msg.devices; renderDevices(); renderLogdev(); }
    else if (msg.type === 'logs') { logs = logs.concat(msg.items); if (logs.length > 5000) logs = logs.slice(-5000); if (!paused) renderLogs(); }
    else if (msg.type === 'cleared') { logs = []; renderLogs(); }
  };
}
connect();
document.querySelectorAll('.tab').forEach(function(t){
  t.onclick = function(){
    document.querySelectorAll('.tab').forEach(function(x){ x.classList.remove('active'); });
    document.querySelectorAll('.page').forEach(function(x){ x.classList.remove('active'); });
    t.classList.add('active');
    document.getElementById('page-' + t.dataset.tab).classList.add('active');
    if (t.dataset.tab === 'daemon') refreshDaemon();
  };
});
function esc(s){ var d = document.createElement('div'); d.textContent = s == null ? '' : String(s); return d.innerHTML; }
function renderDevices() {
  var rows = document.getElementById('devrows');
  if (!devices.length) { rows.innerHTML = '<tr><td colspan="5" class="muted">未发现设备（确认 adb / hdc / Xcode 工具可用且设备已连接）</td></tr>'; return; }
  var html = '';
  devices.forEach(function(d){
    html += '<tr><td><input type="radio" name="dev" ' + (d.id === selected ? 'checked' : '') + ' onchange="selectDevice(\'' + d.id + '\')"></td>'
      + '<td>' + (platformNames[d.platform] || d.platform) + '</td><td>' + esc(d.name) + '</td><td>' + esc(d.id) + '</td>'
      + '<td class="' + (d.state === 'device' || d.state === 'ok' ? 'ok' : 'bad') + '">' + esc(d.state) + '</td></tr>';
  });
  rows.innerHTML = html;
}
function renderLogdev() {
  var html = '<option value="">未选择</option>';
  devices.forEach(function(d){
    html += '<option value="' + esc(d.id) + '" ' + (d.id === selected ? 'selected' : '') + '>' + (platformNames[d.platform] || d.platform) + ' · ' + esc(d.name) + '</option>';
  });
  document.getElementById('logdev').innerHTML = html;
}
function refreshDevices(){ ws.send(JSON.stringify({type:'refresh'})); }
function selectDevice(id){ selected = id; ws.send(JSON.stringify({type:'select', id: id})); logs = []; renderLogs(); renderDevices(); }
function renderLogs() {
  var view = document.getElementById('logview');
  var wantDevice = document.getElementById('f-src-device').checked;
  var wantFlutter = document.getElementById('f-src-flutter').checked;
  var lv = {}; document.querySelectorAll('.f-lv').forEach(function(c){ lv[c.value] = c.checked; });
  var kw = document.getElementById('f-kw').value.toLowerCase();
  var html = '';
  logs.forEach(function(l){
    var isFlutter = l.source && l.source.indexOf('flutter') === 0;
    if (isFlutter && !wantFlutter) return;
    if (!isFlutter && !wantDevice) return;
    if (!lv[l.level]) return;
    if (kw && ((l.msg || '') + ' ' + (l.tag || '')).toLowerCase().indexOf(kw) < 0) return;
    var t = l.ts || l.rcv || '';
    html += '<div class="lv-' + (l.level || 'I') + '"><span class="muted">' + esc(t) + '</span> <span class="src">[' + esc(l.source) + ']</span> <span class="tag">' + esc(l.tag || '') + '</span> ' + esc(l.msg) + '</div>';
  });
  view.innerHTML = html || '<span class="muted">暂无日志</span>';
  if (!paused) view.scrollTop = view.scrollHeight;
}
function togglePause(btn){ paused = !paused; btn.textContent = paused ? '继续' : '暂停'; if (!paused) renderLogs(); }
function clearLogs(){ logs = []; renderLogs(); }
function refreshDaemon(){
  fetch('/api/daemon').then(function(r){ return r.json(); }).then(function(d){
    var el = document.getElementById('daemon-status');
    if (!d.running) { el.innerHTML = '<span class="bad">未运行</span>（启动：dart run xb_ume:ide --install）'; }
    else {
      var sess = (d.sessions || []).map(function(s){ return esc(s.source) + ' → ' + esc(s.uri); }).join('<br>') || '<span class="muted">无已接入的调试会话</span>';
      el.innerHTML = '<span class="ok">运行中</span> pid=' + d.pid + '，已运行 ' + Math.floor(d.uptimeSec / 60) + ' 分 ' + (d.uptimeSec % 60) + ' 秒<br>调试会话：<br>' + sess;
    }
    var order = d.config && d.config.ideOrder;
    document.getElementById('ide-order').textContent = (order && order.length) ? order.join(' → ') : '（默认顺序）';
  }).catch(function(){ document.getElementById('daemon-status').textContent = '查询失败（GUI 服务异常）'; });
}
function restartDaemon(){
  if (!confirm('重启守护进程？正在进行的调试会话会自动重连。')) return;
  fetch('/api/daemon/restart', {method: 'POST'}).then(function(r){ return r.json(); }).then(function(d){ alert(d.message); refreshDaemon(); });
}
function openConfig(){ fetch('/api/openconfig', {method: 'POST'}); }
</script>
</body>
</html>
''';
