// iOS 模拟器后端：xcrun simctl。
//
// 能力：install / uninstall / launch / terminate / crashList / crashGet。
// 注入类（pressKey / tapNative）simctl 不支持——显式声明为空，
// 由工具层转成结构化 unsupported，可用桌面点击或 Flutter 侧 tap 替代。
library;

import 'dart:convert';
import 'dart:io';

import 'bridge.dart';
import 'process.dart';

class SimctlBridge extends DeviceBridge {
  SimctlBridge() {
    _xcrun = Platform.isMacOS ? findExecutable('xcrun') : null;
  }

  String? _xcrun;
  final Map<String, String> _crashCache = <String, String>{};

  @override
  String get backend => 'simctl';

  @override
  bool get available => _xcrun != null;

  @override
  String? get unavailableReason =>
      _xcrun == null ? '仅 macOS 且需要 Xcode 命令行工具（xcrun）' : null;

  @override
  Set<DeviceCapability> get capabilities => available
      ? <DeviceCapability>{
          DeviceCapability.install,
          DeviceCapability.uninstall,
          DeviceCapability.launch,
          DeviceCapability.terminate,
          DeviceCapability.crashList,
          DeviceCapability.crashGet,
        }
      : <DeviceCapability>{};

  Future<CmdResult> _simctl(List<String> args,
          {Duration timeout = const Duration(seconds: 60)}) =>
      runCmd(_xcrun ?? 'xcrun', <String>['simctl', ...args], timeout: timeout);

  @override
  Future<List<DeviceInfo>> listDevices() async {
    if (!available) return <DeviceInfo>[];
    final r = await _simctl(<String>['list', 'devices', '--json']);
    requireOk(r, backend, 'xcrun simctl list devices');
    return parseSimctlDevices(r.stdout);
  }

  @override
  Future<void> install(String deviceId, String artifact) async {
    final r = await _simctl(<String>['install', deviceId, artifact],
        timeout: const Duration(minutes: 3));
    requireOk(r, backend, 'xcrun simctl install');
  }

  @override
  Future<void> uninstall(String deviceId, String packageId) async {
    final r = await _simctl(<String>['uninstall', deviceId, packageId]);
    requireOk(r, backend, 'xcrun simctl uninstall');
  }

  @override
  Future<String> launch(String deviceId, String packageId) async {
    final r = await _simctl(<String>['launch', deviceId, packageId]);
    requireOk(r, backend, 'xcrun simctl launch');
    return oneLine(r.stdout, max: 80);
  }

  @override
  Future<void> terminate(String deviceId, String packageId) async {
    final r = await _simctl(<String>['terminate', deviceId, packageId]);
    requireOk(r, backend, 'xcrun simctl terminate');
  }

  @override
  Future<List<CrashReport>> crashList(
    String deviceId, {
    String? packageId,
    int limit = 20,
  }) async {
    // 模拟器崩溃由 macOS 落到 DiagnosticReports（.ips）。
    final dir = Directory(
        '${Platform.environment['HOME'] ?? ''}/Library/Logs/DiagnosticReports');
    if (!dir.existsSync()) return <CrashReport>[];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.ips') || f.path.endsWith('.crash'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    _crashCache.clear();
    final out = <CrashReport>[];
    for (final f in files) {
      if (out.length >= limit) break;
      String raw;
      try {
        raw = f.readAsStringSync();
      } catch (_) {
        continue;
      }
      final pkg = _guessBundleId(raw);
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

/// 解析 `xcrun simctl list devices --json`。
///
/// 结构：`{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
///   {"udid": "...", "name": "iPhone 15", "state": "Booted", "isAvailable": true}]}}`
List<DeviceInfo> parseSimctlDevices(String raw) {
  final out = <DeviceInfo>[];
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return out;
  }
  if (decoded is! Map<String, Object?>) return out;
  final devices = decoded['devices'];
  if (devices is! Map<String, Object?>) return out;
  devices.forEach((runtime, list) {
    if (list is! List) return;
    final osVersion = _runtimeVersion(runtime);
    for (final d in list) {
      if (d is! Map) continue;
      final udid = (d['udid'] ?? '').toString();
      if (udid.isEmpty) continue;
      final available = d['isAvailable'] != false;
      out.add(DeviceInfo(
        backend: 'simctl',
        id: udid,
        name: (d['name'] ?? udid).toString(),
        platform: 'ios',
        state: available ? (d['state'] ?? 'unknown').toString() : 'unavailable',
        model: (d['name'] ?? '').toString(),
        osVersion: osVersion,
      ));
    }
  });
  // Booted 排前面，方便 AI 直接选。
  out.sort((a, b) => (b.state == 'Booted' ? 1 : 0) - (a.state == 'Booted' ? 1 : 0));
  return out;
}

String? _runtimeVersion(String runtime) {
  final m = RegExp(r'iOS-(\d+)-(\d+)').firstMatch(runtime);
  return m == null ? null : 'iOS ${m.group(1)}.${m.group(2)}';
}

String? _guessBundleId(String raw) {
  for (final key in <String>['bundleID', 'bundleId', 'app_name']) {
    final m = RegExp('"$key"\\s*:\\s*"([^"]+)"').firstMatch(raw);
    if (m != null) return m.group(1);
  }
  final m = RegExp(r'Process:\s*([\w.\-]+)').firstMatch(raw);
  return m?.group(1);
}

String _titleOf(String raw) {
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (t.startsWith('{') || t.startsWith('}')) continue;
    if (t.contains('"exception"') || t.contains('"termination"')) {
      final m = RegExp(r'"(?:type|reason|indicator)"\s*:\s*"([^"]+)"').firstMatch(t);
      if (m != null) return m.group(1)!;
    }
    return t;
  }
  return '崩溃报告';
}
