// VM service 自动发现与开发工具 PATH 增强（daemon 与 MCP server 共用）。
//
// 发现策略（与 daemon 原有实现等价）：
//   1. 列出本机回环地址上的 TCP 监听端口（lsof / netstat）；
//   2. 对每个端口 GET /getVM，返回 {"result":{"type":"VM",...}} 即判定为
//      VM service（DevTools 返回 HTML，adb/hdc 服务无此响应）；
//   3. 用 isolates id 组合作为实例指纹，同一实例经多端口可达时按指纹去重，
//      优先选有设备转发映射的端口（adb forward / hdc fport），使来源可读。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 拼接开发工具常见安装目录到 PATH。
///
/// launchd / 注册表自启 / IDE 拉起的进程，PATH 只有系统默认目录，
/// adb（Android SDK / brew）、hdc（DevEco SDK）、idevice（brew）都不在其中。
String augmentedToolPath() {
  final dirs = <String>[
    if (!Platform.isWindows) '/opt/homebrew/bin',
    if (!Platform.isWindows) '/usr/local/bin',
  ];
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '';
  final androidHome = Platform.environment['ANDROID_HOME'];
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    dirs.addAll(<String>[
      if (androidHome != null) '$androidHome\\platform-tools',
      if (localAppData.isNotEmpty)
        '$localAppData\\Android\\Sdk\\platform-tools',
    ]);
    final sdkRoot = Directory(r'C:\Program Files\Huawei\DevEco Studio\sdk');
    if (sdkRoot.existsSync()) {
      try {
        for (final entry in sdkRoot.listSync()) {
          final toolchain = Directory('${entry.path}\\openharmony\\toolchains');
          if (toolchain.existsSync()) dirs.add(toolchain.path);
        }
      } catch (_) {
        // 目录不可读时忽略，保持默认 PATH。
      }
    }
  } else {
    dirs.addAll(<String>[
      if (androidHome != null) '$androidHome/platform-tools',
      '$home/Library/Android/sdk/platform-tools',
      '$home/Android/Sdk/platform-tools',
    ]);
    final sdkRoot = Directory('/Applications/DevEco-Studio.app/Contents/sdk');
    if (sdkRoot.existsSync()) {
      try {
        for (final entry in sdkRoot.listSync()) {
          final toolchain = Directory('${entry.path}/openharmony/toolchains');
          if (toolchain.existsSync()) dirs.add(toolchain.path);
        }
      } catch (_) {
        // 同上。
      }
    }
  }
  final current = Platform.environment['PATH'] ?? '';
  return <String>[
    ...dirs.where((d) => d.isNotEmpty),
    current,
  ].join(Platform.isWindows ? ';' : ':');
}

/// 以增强 PATH 运行设备工具，返回 stdout（失败返回空串）。
Future<String> runToolText(
  String command,
  List<String> args, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  try {
    final result = await Process.run(
      command,
      args,
      environment: <String, String>{'PATH': augmentedToolPath()},
    ).timeout(timeout);
    return '${result.stdout}';
  } catch (_) {
    return '';
  }
}

/// 以增强 PATH 运行设备工具，返回完整结果（调用方需要 exitCode/stderr）。
Future<ProcessResult?> runToolFull(
  String command,
  List<String> args, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  try {
    return await Process.run(
      command,
      args,
      environment: <String, String>{'PATH': augmentedToolPath()},
    ).timeout(timeout);
  } catch (_) {
    return null;
  }
}

/// 单个端口的 VM service 探测结果。
class VmProbe {
  const VmProbe({
    required this.fingerprint,
    required this.name,
    required this.isolateCount,
  });

  /// isolates id 组合（实例级去重键）。
  final String fingerprint;

  /// VM 名，通常是 app 名（如 example）。
  final String name;

  final int isolateCount;
}

/// 已发现的调试会话。
class DiscoveredSession {
  const DiscoveredSession({
    required this.wsUrl,
    required this.port,
    required this.source,
    required this.fingerprint,
    required this.name,
  });

  /// 归一化的 WebSocket 地址（ws://127.0.0.1:<port>/ws）。
  final String wsUrl;
  final int port;

  /// 来源标识：adb:SERIAL#port:N / hdc:SERIAL#port:N / port:N。
  final String source;
  final String fingerprint;

  /// VM 名（通常即 app 名）。
  final String name;
}

/// 探测端口是否为 VM service；命中返回详情，否则 null。
Future<VmProbe?> probeVmService(
  int port, {
  Duration connectionTimeout = const Duration(milliseconds: 800),
}) async {
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = connectionTimeout;
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port/getVM'))
        .timeout(const Duration(seconds: 2));
    final response =
        await request.close().timeout(const Duration(seconds: 2));
    if (response.statusCode != 200) return null;
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 2));
    final parsed = jsonDecode(body);
    if (parsed is! Map<String, Object?>) return null;
    final result = parsed['result'];
    if (result is! Map<String, Object?> || result['type'] != 'VM') return null;
    final isolates = result['isolates'];
    final ids = <String>[];
    if (isolates is List) {
      for (final e in isolates) {
        if (e is Map && e['id'] != null) ids.add('${e['id']}');
      }
    }
    return VmProbe(
      fingerprint: ids.isEmpty ? 'vm:${result['name']}' : ids.join('|'),
      name: '${result['name'] ?? ''}',
      isolateCount: ids.length,
    );
  } catch (_) {
    return null;
  } finally {
    client?.close(force: true);
  }
}

/// 列出本机回环地址上的 TCP 监听端口。
Future<List<int>> loopbackListeningPorts() async {
  final ports = <int>{};
  final String output;
  if (Platform.isWindows) {
    output = await runToolText('netstat', const <String>['-ano']);
  } else {
    output = await runToolText(
      'lsof',
      const <String>['-nP', '-iTCP', '-sTCP:LISTEN'],
    );
  }
  final pattern = RegExp(r'(?:127\.0\.0\.1|\*|\[::1\]):(\d+)\s');
  for (final line in output.split('\n')) {
    if (Platform.isWindows && !line.contains('LISTENING')) continue;
    final match = pattern.firstMatch(line);
    if (match != null) ports.add(int.parse(match.group(1)!));
  }
  return ports.toList()..sort();
}

/// 通过 adb/hdc 端口转发表把本机转发端口映射到设备标识。
Future<Map<int, String>> forwardedPortsByDevice() async {
  final result = <int, String>{};
  // adb forward --list："<serial> tcp:<local> tcp:<remote>"
  final adb = await runToolText('adb', <String>['forward', '--list']);
  for (final line in adb.trim().split('\n')) {
    final m = RegExp(r'^(\S+)\s+tcp:(\d+)\s+').firstMatch(line.trim());
    if (m != null) result[int.parse(m.group(2)!)] = 'adb:${m.group(1)}';
  }
  // hdc -t <target> fport ls：每行含 "tcp:<local> tcp:<remote>"
  final targets = await runToolText('hdc', <String>['list', 'targets']);
  for (final target in targets.trim().split('\n')) {
    final t = target.trim();
    if (t.isEmpty || t.contains('[') || t.contains('error')) continue;
    final ls = await runToolText('hdc', <String>['-t', t, 'fport', 'ls']);
    for (final line in ls.split('\n')) {
      final m = RegExp(r'tcp:(\d+)\s+tcp:\d+').firstMatch(line);
      if (m != null) result.putIfAbsent(int.parse(m.group(1)!), () => 'hdc:$t');
    }
  }
  return result;
}

/// 扫描本机并返回新发现的调试会话（按实例指纹去重）。
///
/// [knownFingerprints] 命中的实例直接跳过（daemon 用它避免重复接入）；
/// [skipPorts] 用于排除自身服务端口（如 GUI / MCP）。
Future<List<DiscoveredSession>> discoverLocalVmServices({
  Set<String> knownFingerprints = const <String>{},
  Set<int> skipPorts = const <int>{},
}) async {
  final ports = await loopbackListeningPorts();
  final devices = await forwardedPortsByDevice();
  final probes = <int, VmProbe>{};
  await Future.wait(ports.where((p) => !skipPorts.contains(p)).map((port) async {
    final probe = await probeVmService(port);
    if (probe != null) probes[port] = probe;
  }));
  final byFingerprint = <String, List<int>>{};
  probes.forEach((port, probe) {
    byFingerprint.putIfAbsent(probe.fingerprint, () => <int>[]).add(port);
  });
  final found = <DiscoveredSession>[];
  for (final entry in byFingerprint.entries) {
    if (knownFingerprints.contains(entry.key)) continue;
    final candidates = entry.value.toList()
      ..sort((a, b) {
        final da = devices.containsKey(a);
        final db = devices.containsKey(b);
        if (da != db) return da ? -1 : 1;
        return a.compareTo(b);
      });
    final port = candidates.first;
    final device = devices[port];
    found.add(DiscoveredSession(
      wsUrl: 'ws://127.0.0.1:$port/ws',
      port: port,
      source: device == null ? 'port:$port' : '$device#port:$port',
      fingerprint: entry.key,
      name: probes[port]?.name ?? '',
    ));
  }
  found.sort((a, b) => a.port.compareTo(b.port));
  return found;
}
