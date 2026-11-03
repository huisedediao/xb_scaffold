// iOS 真机后端：libimobiledevice（idevice_id / ideviceinstaller / idevicecrashreport）。
//
// 这些工具不是系统自带：全部缺失时 available=false，capabilities 为空，
// 由 xbume_devices 显式展示原因（不做"假装支持"）。
library;

import 'dart:io';

import 'bridge.dart';
import 'process.dart';

class IDeviceBridge extends DeviceBridge {
  IDeviceBridge() {
    _idExe = findExecutable('idevice_id');
    _installerExe = findExecutable('ideviceinstaller');
    _crashExe = findExecutable('idevicecrashreport');
    _nameExe = findExecutable('idevicename');
    _syslogExe = findExecutable('idevicesyslog');
  }

  String? _idExe;
  String? _installerExe;
  String? _crashExe;
  String? _nameExe;
  String? _syslogExe;
  final Map<String, String> _crashCache = <String, String>{};

  @override
  String get backend => 'idevice';

  @override
  bool get available => _idExe != null;

  @override
  String? get unavailableReason => _idExe == null
      ? (Platform.isWindows
          ? '未找到 idevice_id（Windows 需自行安装 libimobiledevice 并加入 PATH）'
          : '未找到 idevice_id（brew install libimobiledevice）')
      : (_installerExe == null ? '未找到 ideviceinstaller，装包/卸包不可用' : null);

  @override
  Set<DeviceCapability> get capabilities => <DeviceCapability>{
        if (available && _installerExe != null) ...<DeviceCapability>{
          DeviceCapability.install,
          DeviceCapability.uninstall,
        },
        if (available && _crashExe != null) ...<DeviceCapability>{
          DeviceCapability.crashList,
          DeviceCapability.crashGet,
        },
        if (available && _syslogExe != null) DeviceCapability.logDump,
      };

  @override
  Future<DeviceLogDump> logDump(
    String deviceId, {
    int lines = 1000,
    int sinceMinutes = 5,
    int durationMs = 3000,
  }) async {
    final exe = _syslogExe;
    if (exe == null) {
      throw DeviceUnsupported(DeviceCapability.logDump, backend,
          '未安装 idevicesyslog（brew install libimobiledevice）');
    }
    // 真机 syslog 只能流式读（没历史 dump、不发 EOF）：限时采集后由
    // runCmd 超时 SIGKILL 收尸，不驻留进程。
    final ms = durationMs.clamp(500, 15000);
    final r = await runCmd(exe, <String>['-u', deviceId],
        timeout: Duration(milliseconds: ms));
    return DeviceLogDump(
      backend: backend,
      command: 'idevicesyslog -u $deviceId（限时 ${ms}ms）',
      raw: r.stdout,
      note: 'iOS 真机没有历史 dump：只含观察窗口内的日志；'
          '要覆盖整个操作过程就“先开抓再操作”，或用 GUI 设备日志的持续采集',
    );
  }

  @override
  Future<List<DeviceInfo>> listDevices() async {
    if (!available) return <DeviceInfo>[];
    final r = await runCmd(_idExe!, <String>['-l']);
    requireOk(r, backend, 'idevice_id -l');
    final ids = r.stdout
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final out = <DeviceInfo>[];
    for (final id in ids) {
      var name = id;
      if (_nameExe != null) {
        final n = await runCmd(_nameExe!, <String>['-u', id],
            timeout: const Duration(seconds: 5));
        if (n.ok && n.stdout.trim().isNotEmpty) name = n.stdout.trim();
      }
      out.add(DeviceInfo(
        backend: backend,
        id: id,
        name: name,
        platform: 'ios',
        state: 'device',
      ));
    }
    return out;
  }

  @override
  Future<void> install(String deviceId, String artifact) async {
    final exe = _installerExe;
    if (exe == null) {
      throw DeviceUnsupported(
          DeviceCapability.install, backend, '未找到 ideviceinstaller');
    }
    final r = await runCmd(exe, <String>['-u', deviceId, '-i', artifact],
        timeout: const Duration(minutes: 5));
    requireOk(r, backend, 'ideviceinstaller -i');
  }

  @override
  Future<void> uninstall(String deviceId, String packageId) async {
    final exe = _installerExe;
    if (exe == null) {
      throw DeviceUnsupported(
          DeviceCapability.uninstall, backend, '未找到 ideviceinstaller');
    }
    final r = await runCmd(exe, <String>['-u', deviceId, '-U', packageId],
        timeout: const Duration(minutes: 2));
    requireOk(r, backend, 'ideviceinstaller -U');
  }

  @override
  Future<String> launch(String deviceId, String packageId) async {
    // libimobiledevice 没有稳定的 app 启动入口（需 idevicedebug / 私有 lockdown
    // 服务），这里显式不支持，避免给出不可靠实现。
    throw DeviceUnsupported(
      DeviceCapability.launch,
      backend,
      '真机 app 启动需 idevicedebug，本机未提供；可改用 flutter run -d <udid>',
    );
  }

  @override
  Future<void> terminate(String deviceId, String packageId) async {
    throw DeviceUnsupported(
      DeviceCapability.terminate,
      backend,
      '真机 app 停止需 idevicedebug/进程管理，本机未提供',
    );
  }

  @override
  Future<List<CrashReport>> crashList(
    String deviceId, {
    String? packageId,
    int limit = 20,
  }) async {
    final exe = _crashExe;
    if (exe == null) {
      throw DeviceUnsupported(
          DeviceCapability.crashList, backend, '未找到 idevicecrashreport');
    }
    final dir = Directory.systemTemp.createTempSync('xb_ume_crash_');
    final r = await runCmd(exe, <String>['-u', deviceId, '-k', dir.path],
        timeout: const Duration(seconds: 60));
    if (!r.ok) {
      throw DeviceCommandError(backend, 'idevicecrashreport', oneLine(r.errorText));
    }
    _crashCache.clear();
    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.ips') || f.path.endsWith('.crash'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    final out = <CrashReport>[];
    for (final f in files) {
      if (out.length >= limit) break;
      String raw;
      try {
        raw = f.readAsStringSync();
      } catch (_) {
        continue;
      }
      final pkg = RegExp(r'"bundleID"\s*:\s*"([^"]+)"').firstMatch(raw)?.group(1) ??
          RegExp(r'Process:\s*([\w.\-]+)').firstMatch(raw)?.group(1);
      if (packageId != null && packageId.isNotEmpty && pkg != packageId) continue;
      final id = f.uri.pathSegments.last;
      _crashCache[id] = raw;
      out.add(CrashReport(
        id: id,
        title: _titleOf(raw),
        package: pkg,
        time: f.lastModifiedSync(),
        summary: oneLine(_titleOf(raw), max: 120),
        path: f.path,
      ));
    }
    return out;
  }

  @override
  Future<String> crashGet(String deviceId, String crashId) async {
    final hit = _crashCache[crashId];
    if (hit != null) return hit;
    await crashList(deviceId, limit: 200);
    final again = _crashCache[crashId];
    if (again != null) return again;
    throw DeviceCommandError(backend, 'crashGet', '没有找到崩溃报告 $crashId');
  }
}

String _titleOf(String raw) {
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('{') || t.startsWith('}')) continue;
    if (t.contains('"exception"')) {
      final m = RegExp(r'"type"\s*:\s*"([^"]+)"').firstMatch(t);
      if (m != null) return m.group(1)!;
    }
    return t;
  }
  return '崩溃报告';
}
