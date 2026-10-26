// Android 设备后端：adb。
//
// 覆盖 install / uninstall / launch / terminate / pressKey / tapNative /
// crashList / crashGet。crashList 走 `logcat -b crash -d`，解析出
// FATAL EXCEPTION 块；crashGet 从内存缓存回读原始日志（同一次 MCP 进程内）。
library;

import 'bridge.dart';
import 'process.dart';

/// Android keyevent 键码（frameworks/base core/java/android/view/KeyEvent.java）。
const Map<DeviceKey, int> _androidKeyCodes = <DeviceKey, int>{
  DeviceKey.back: 4,
  DeviceKey.home: 3,
  DeviceKey.enter: 66,
  DeviceKey.delete: 67,
  DeviceKey.tab: 61,
  DeviceKey.escape: 111,
  DeviceKey.menu: 82,
  DeviceKey.appSwitch: 187,
  DeviceKey.volumeUp: 24,
  DeviceKey.volumeDown: 25,
  DeviceKey.power: 26,
};

class AdbBridge extends DeviceBridge {
  AdbBridge() {
    _exe = findExecutable('adb');
  }

  String? _exe;

  /// crashId → 原始日志（同一进程内有效；列表刷新会重建）。
  final Map<String, String> _crashCache = <String, String>{};
  List<CrashReport> _lastCrashes = <CrashReport>[];

  @override
  String get backend => 'adb';

  @override
  bool get available => _exe != null;

  @override
  String? get unavailableReason =>
      _exe == null ? '未找到 adb（安装 Android platform-tools 并加入 PATH）' : null;

  @override
  Set<DeviceCapability> get capabilities => available
      ? <DeviceCapability>{
          DeviceCapability.install,
          DeviceCapability.uninstall,
          DeviceCapability.launch,
          DeviceCapability.terminate,
          DeviceCapability.pressKey,
          DeviceCapability.tapNative,
          DeviceCapability.crashList,
          DeviceCapability.crashGet,
        }
      : <DeviceCapability>{};

  List<String> _base(String? deviceId) =>
      <String>[if (deviceId != null && deviceId.isNotEmpty) ...<String>['-s', deviceId]];

  Future<CmdResult> _run(String? deviceId, List<String> args,
          {Duration timeout = const Duration(seconds: 30)}) =>
      runCmd(_exe ?? 'adb', <String>[..._base(deviceId), ...args], timeout: timeout);

  @override
  Future<List<DeviceInfo>> listDevices() async {
    if (!available) return <DeviceInfo>[];
    final r = await _run(null, <String>['devices', '-l']);
    requireOk(r, backend, 'adb devices -l');
    return parseAdbDevices(r.stdout);
  }

  @override
  Future<void> install(String deviceId, String artifact) async {
    final r = await _run(deviceId, <String>['install', '-r', artifact],
        timeout: const Duration(minutes: 5));
    requireOk(r, backend, 'adb install');
    if (r.stdout.contains('Failure')) {
      throw DeviceCommandError(backend, 'adb install', oneLine(r.stdout));
    }
  }

  @override
  Future<void> uninstall(String deviceId, String packageId) async {
    final r = await _run(deviceId, <String>['uninstall', packageId],
        timeout: const Duration(minutes: 2));
    requireOk(r, backend, 'adb uninstall');
    if (r.stdout.contains('Failure')) {
      throw DeviceCommandError(backend, 'adb uninstall', oneLine(r.stdout));
    }
  }

  @override
  Future<String> launch(String deviceId, String packageId) async {
    // 先解析 launcher activity，拿不到就退回 monkey（对 Flutter app 更稳）。
    final resolved = await _run(
        deviceId, <String>['shell', 'cmd', 'package', 'resolve-activity', '--brief', packageId]);
    final component = resolved.ok ? resolved.stdout.trim().split('\n').last.trim() : '';
    if (resolved.ok && component.contains('/')) {
      final r = await _run(deviceId, <String>['shell', 'am', 'start', '-n', component]);
      requireOk(r, backend, 'adb shell am start');
      return component;
    }
    final r = await _run(deviceId, <String>[
      'shell',
      'monkey',
      '-p',
      packageId,
      '-c',
      'android.intent.category.LAUNCHER',
      '1',
    ]);
    requireOk(r, backend, 'adb shell monkey');
    return 'monkey -p $packageId';
  }

  @override
  Future<void> terminate(String deviceId, String packageId) async {
    final r = await _run(deviceId, <String>['shell', 'am', 'force-stop', packageId]);
    requireOk(r, backend, 'adb shell am force-stop');
  }

  @override
  Future<void> pressKey(String deviceId, DeviceKey key) async {
    final code = _androidKeyCodes[key];
    if (code == null) {
      throw DeviceUnsupported(DeviceCapability.pressKey, backend, '未知按键 ${key.name}');
    }
    final r = await _run(deviceId, <String>['shell', 'input', 'keyevent', '$code']);
    requireOk(r, backend, 'adb shell input keyevent');
  }

  @override
  Future<void> tapNative(String deviceId, int x, int y) async {
    final r = await _run(deviceId, <String>['shell', 'input', 'tap', '$x', '$y']);
    requireOk(r, backend, 'adb shell input tap');
  }

  @override
  Future<List<CrashReport>> crashList(
    String deviceId, {
    String? packageId,
    int limit = 20,
  }) async {
    final r = await _run(deviceId, <String>['logcat', '-b', 'crash', '-d', '-v', 'threadtime']);
    requireOk(r, backend, 'adb logcat -b crash');
    final parsed = parseAndroidCrashLog(r.stdout, packageId: packageId);
    _crashCache.clear();
    for (final e in parsed) {
      _crashCache[e.report.id] = e.raw;
    }
    _lastCrashes = parsed.map((e) => e.report).toList(growable: false);
    return _lastCrashes.take(limit).toList(growable: false);
  }

  @override
  Future<String> crashGet(String deviceId, String crashId) async {
    final hit = _crashCache[crashId];
    if (hit != null) return hit;
    // 缓存没有就重新拉一次（最多 200 条，避免爆内存）。
    await crashList(deviceId, limit: 200);
    final again = _crashCache[crashId];
    if (again != null) return again;
    final ids = _lastCrashes.map((e) => e.id).take(10).join(', ');
    throw DeviceCommandError(
        backend, 'crashGet', '没有崩溃记录 $crashId${ids.isEmpty ? '' : '，可用：$ids'}');
  }
}

/// 解析 `adb devices -l`。
///
/// 输出形如：
/// ```
/// List of devices attached
/// emulator-5554          device product:sdk_gphone64 model:sdk_gphone64_x86_64 device:emu64xa
/// 0123456789ABCDEF       unauthorized usb:1-1
/// ```
List<DeviceInfo> parseAdbDevices(String raw) {
  final out = <DeviceInfo>[];
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (t.startsWith('List of devices') || t.startsWith('*')) continue;
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final id = parts[0];
    final state = parts[1];
    String? model;
    String? product;
    for (final p in parts.skip(2)) {
      if (p.startsWith('model:')) model = p.substring(6);
      if (p.startsWith('product:')) product = p.substring(8);
    }
    out.add(DeviceInfo(
      backend: 'adb',
      id: id,
      name: model ?? product ?? id,
      platform: 'android',
      state: state,
      model: model,
    ));
  }
  return out;
}

/// 解析 `adb logcat -b crash -d -v threadtime`。
///
/// 每个 FATAL EXCEPTION 块生成一条记录，id 用 `c<序号>`（新的在前）。
/// 返回列表保持新→旧顺序，每项带原始文本块供 crashGet 回读。
List<({CrashReport report, String raw})> parseAndroidCrashLog(
    String raw, {String? packageId}) {
  final lines = raw.split('\n');
  // 行前缀：`MM-DD HH:MM:SS.mmm  PID  TID E Tag: `
  final prefix = RegExp(
      r'^(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+\d+\s+\d+\s+\w\s+([^:]+):\s?(.*)$');
  final blocks = <Map<String, Object?>>[];
  Map<String, Object?>? cur;
  for (final line in lines) {
    final m = prefix.firstMatch(line);
    final body = m?.group(3) ?? line;
    final tag = m?.group(2)?.trim() ?? '';
    // logcat 的 `--------- beginning of crash` 只是缓冲区分隔线，不作为新块起点。
    if (line.startsWith('--------- beginning of')) {
      cur = null;
      continue;
    }
    final isFatal =
        body.contains('FATAL EXCEPTION') || body.contains('*** *** ***');
    if (isFatal) {
      cur = <String, Object?>{
        'time': m?.group(1),
        'tag': tag,
        'lines': <String>[line],
      };
      blocks.add(cur);
      continue;
    }
    if (cur == null) continue;
    // 空行或明显的新进程日志边界结束当前块。
    if (body.trim().isEmpty) {
      cur = null;
      continue;
    }
    (cur['lines'] as List<String>).add(line);
  }
  final results = <({CrashReport report, String raw})>[];
  var index = 0;
  for (final b in blocks.reversed) {
    final text = (b['lines'] as List<String>).join('\n');
    if (text.trim().isEmpty) continue;
    final pkg = RegExp(r'Process:\s*([\w.]+)').firstMatch(text)?.group(1);
    if (packageId != null && packageId.isNotEmpty && pkg != packageId) continue;
    final titleLine = _crashTitle(text);
    final id = 'c${index++}';
    final time = _parseLogTime(b['time'] as String?);
    results.add((
      report: CrashReport(
        id: id,
        title: titleLine,
        package: pkg,
        time: time,
        summary: oneLine(titleLine, max: 120),
      ),
      raw: text,
    ));
  }
  return results;
}

String _crashTitle(String text) {
  final lines = text.split('\n');
  // 优先用异常类名（比 "FATAL EXCEPTION: main" 更有信息量）。
  for (final line in lines) {
    if (line.contains('FATAL EXCEPTION')) continue;
    final idx = line.indexOf(RegExp(r'(signal \d+|\b[\w.$]+(?:Exception|Error)\b)'));
    if (idx >= 0) {
      final tail = line.substring(idx).trim();
      if (tail.isNotEmpty) return tail;
    }
  }
  for (final line in lines) {
    final i = line.indexOf('FATAL EXCEPTION');
    if (i >= 0) return line.substring(i).trim();
  }
  return oneLine(lines.first, max: 100);
}

DateTime? _parseLogTime(String? raw) {
  if (raw == null) return null;
  // logcat 只有 MM-DD，补当前年份。
  final m = RegExp(r'^(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})').firstMatch(raw);
  if (m == null) return null;
  final now = DateTime.now();
  return DateTime(
    now.year,
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
  );
}
