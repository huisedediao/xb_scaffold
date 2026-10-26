// HarmonyOS 设备后端：hdc（HarmonyOS Device Connector）。
//
// 覆盖 install / uninstall / launch / terminate / pressKey。
// 崩溃日志（hilog / faultlogger）与注入式点击在设备间差异较大，
// 暂不声明能力，避免给出不确定的实现。
library;

import 'bridge.dart';
import 'process.dart';

/// HarmonyOS keycode（与 Android 不同：Back=2 / Home=1）。
const Map<DeviceKey, int> _ohosKeyCodes = <DeviceKey, int>{
  DeviceKey.back: 2,
  DeviceKey.home: 1,
  DeviceKey.enter: 2054,
  DeviceKey.delete: 2055,
  DeviceKey.tab: 2049,
  DeviceKey.escape: 2070,
  DeviceKey.menu: 2064,
  DeviceKey.appSwitch: 2077,
  DeviceKey.volumeUp: 16,
  DeviceKey.volumeDown: 17,
  DeviceKey.power: 18,
};

class HdcBridge extends DeviceBridge {
  HdcBridge() {
    _exe = findExecutable('hdc');
  }

  String? _exe;

  @override
  String get backend => 'hdc';

  @override
  bool get available => _exe != null;

  @override
  String? get unavailableReason =>
      _exe == null ? '未找到 hdc（HarmonyOS SDK toolchains 加入 PATH）' : null;

  @override
  Set<DeviceCapability> get capabilities => available
      ? <DeviceCapability>{
          DeviceCapability.install,
          DeviceCapability.uninstall,
          DeviceCapability.launch,
          DeviceCapability.terminate,
          DeviceCapability.pressKey,
        }
      : <DeviceCapability>{};

  Future<CmdResult> _run(String? deviceId, List<String> args,
          {Duration timeout = const Duration(seconds: 60)}) =>
      runCmd(_exe ?? 'hdc',
          <String>[if (deviceId != null && deviceId.isNotEmpty) ...<String>['-t', deviceId], ...args],
          timeout: timeout);

  @override
  Future<List<DeviceInfo>> listDevices() async {
    if (!available) return <DeviceInfo>[];
    final r = await _run(null, <String>['list', 'targets']);
    requireOk(r, backend, 'hdc list targets');
    return parseHdcTargets(r.stdout);
  }

  @override
  Future<void> install(String deviceId, String artifact) async {
    final r = await _run(deviceId, <String>['install', '-r', artifact],
        timeout: const Duration(minutes: 5));
    requireOk(r, backend, 'hdc install');
  }

  @override
  Future<void> uninstall(String deviceId, String packageId) async {
    final r = await _run(deviceId, <String>['uninstall', packageId],
        timeout: const Duration(minutes: 2));
    requireOk(r, backend, 'hdc uninstall');
  }

  /// [packageId] 支持 `bundle` 或 `bundle#Ability`；省略 Ability 时用 EntryAbility。
  @override
  Future<String> launch(String deviceId, String packageId) async {
    final parts = packageId.split('#');
    final bundle = parts.first;
    final ability = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : 'EntryAbility';
    final r = await _run(
        deviceId, <String>['shell', 'aa', 'start', '-a', ability, '-b', bundle]);
    requireOk(r, backend, 'hdc shell aa start');
    return '$bundle/$ability';
  }

  @override
  Future<void> terminate(String deviceId, String packageId) async {
    final bundle = packageId.split('#').first;
    final r = await _run(deviceId, <String>['shell', 'aa', 'force-stop', bundle]);
    requireOk(r, backend, 'hdc shell aa force-stop');
  }

  @override
  Future<void> pressKey(String deviceId, DeviceKey key) async {
    final code = _ohosKeyCodes[key];
    if (code == null) {
      throw DeviceUnsupported(DeviceCapability.pressKey, backend, '未知按键 ${key.name}');
    }
    final r = await _run(deviceId, <String>['shell', 'input', 'keyevent', '$code']);
    requireOk(r, backend, 'hdc shell input keyevent');
  }
}

/// 解析 `hdc list targets`：每行一个 connect key，可能附带状态。
///
/// ```
/// 7001005458323933328XXXXX
/// 127.0.0.1:5555
/// [Empty]
/// ```
List<DeviceInfo> parseHdcTargets(String raw) {
  final out = <DeviceInfo>[];
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('[')) continue;
    if (t.toLowerCase().contains('empty')) continue;
    final parts = t.split(RegExp(r'\s+'));
    final id = parts.first;
    if (id.isEmpty) continue;
    out.add(DeviceInfo(
      backend: 'hdc',
      id: id,
      name: id,
      platform: 'harmonyos',
      state: parts.length > 1 ? parts[1] : 'device',
    ));
  }
  return out;
}
