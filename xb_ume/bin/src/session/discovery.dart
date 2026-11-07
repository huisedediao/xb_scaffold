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

import 'capability.dart';

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
    this.remotePort,
  });

  /// 归一化的 WebSocket 地址（ws://127.0.0.1:<port>/ws）。
  final String wsUrl;
  final int port;

  /// 来源标识：adb:SERIAL#port:N / hdc:SERIAL#port:N / port:N。
  final String source;
  final String fingerprint;

  /// VM 名（通常即 app 名）。
  final String name;

  /// 设备侧端口（有转发记录时才有），用于和直连通道配对。
  final int? remotePort;

  /// 设备标识（adb:SERIAL / hdc:SERIAL），无转发时为 null。
  String? get deviceId {
    final i = source.indexOf('#');
    if (i <= 0) return null;
    final s = source.substring(0, i);
    return s.contains(':') ? s : null;
  }
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
///
/// VM 与直连两轮探测在同一轮询周期里各调一次，[maxAge] 内的结果直接复用；
/// `lsof` 在 macOS 上单次可能上百毫秒，缓一轮比多扫一次划算。
Future<List<int>> loopbackListeningPorts({
  Duration maxAge = const Duration(milliseconds: 1200),
  bool force = false,
}) async {
  final cached = _portsCache;
  final at = _portsAt;
  if (!force &&
      cached != null &&
      at != null &&
      DateTime.now().difference(at) < maxAge) {
    return cached;
  }
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
  // Windows 的通配绑定是 0.0.0.0 / [::]（lsof 是 *），一并接受。
  final pattern = RegExp(r'(?:127\.0\.0\.1|0\.0\.0\.0|\*|\[::1?\]):(\d+)\s');
  for (final line in output.split('\n')) {
    if (Platform.isWindows && !line.contains('LISTENING')) continue;
    final match = pattern.firstMatch(line);
    if (match != null) ports.add(int.parse(match.group(1)!));
  }
  final sorted = ports.toList()..sort();
  _portsCache = sorted;
  _portsAt = DateTime.now();
  return sorted;
}

/// 一条端口转发记录（本机端口 → 设备端口）。
class ForwardedPort {
  const ForwardedPort({
    required this.local,
    required this.remote,
    required this.device,
  });

  final int local;

  /// 设备侧端口，用于和 app 自报的 vmPort / agentPort 精确配对。
  final int remote;

  /// adb:<serial> / hdc:<serial>。
  final String device;
}

/// 读取 adb / hdc 的端口转发表（本机端口 → 设备端口）。
///
/// 同 [loopbackListeningPorts]：同一轮询周期内 VM / 直连探测共缓存。
Future<Map<int, ForwardedPort>> forwardedPortMap({
  Duration maxAge = const Duration(milliseconds: 1200),
  bool force = false,
}) async {
  final cached = _forwardsCache;
  final at = _forwardsAt;
  if (!force &&
      cached != null &&
      at != null &&
      DateTime.now().difference(at) < maxAge) {
    return cached;
  }
  final result = <int, ForwardedPort>{};
  // adb forward --list："<serial> tcp:<local> tcp:<remote>"
  final adb = await runToolText('adb', <String>['forward', '--list']);
  for (final line in adb.trim().split('\n')) {
    final m =
        RegExp(r'^(\S+)\s+tcp:(\d+)\s+tcp:(\d+)').firstMatch(line.trim());
    if (m != null) {
      result[int.parse(m.group(2)!)] = ForwardedPort(
        local: int.parse(m.group(2)!),
        remote: int.parse(m.group(3)!),
        device: 'adb:${m.group(1)}',
      );
    }
  }
  // hdc -t <target> fport ls：每行含 "tcp:<local> tcp:<remote>"
  final targets = await runToolText('hdc', <String>['list', 'targets']);
  for (final target in targets.trim().split('\n')) {
    final t = target.trim();
    if (t.isEmpty || t.contains('[') || t.contains('error')) continue;
    final ls = await runToolText('hdc', <String>['-t', t, 'fport', 'ls']);
    for (final line in ls.split('\n')) {
      final m = RegExp(r'tcp:(\d+)\s+tcp:(\d+)').firstMatch(line);
      if (m == null) continue;
      final local = int.parse(m.group(1)!);
      result.putIfAbsent(
        local,
        () => ForwardedPort(
          local: local,
          remote: int.parse(m.group(2)!),
          device: 'hdc:$t',
        ),
      );
    }
  }
  _forwardsCache = result;
  _forwardsAt = DateTime.now();
  return result;
}

List<int>? _portsCache;
DateTime? _portsAt;
Map<int, ForwardedPort>? _forwardsCache;
DateTime? _forwardsAt;

/// 通过 adb/hdc 端口转发表把本机转发端口映射到设备标识。
Future<Map<int, String>> forwardedPortsByDevice() async {
  final map = await forwardedPortMap();
  return <int, String>{
    for (final e in map.entries) e.key: e.value.device,
  };
}

/// 扫描本机并返回新发现的调试会话（按实例指纹去重）。
///
/// [knownFingerprints] 命中的实例直接跳过（daemon 用它避免重复接入）；
/// [skipPorts] 用于排除自身服务端口（如 GUI / MCP）。
Future<List<DiscoveredSession>> discoverLocalVmServices({
  Set<String> knownFingerprints = const <String>{},
  Set<int> skipPorts = const <int>{},
  bool freshPorts = false,
}) async {
  final ports = await loopbackListeningPorts(force: freshPorts);
  final forwards = await forwardedPortMap(force: freshPorts);
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
        final da = forwards.containsKey(a);
        final db = forwards.containsKey(b);
        if (da != db) return da ? -1 : 1;
        return a.compareTo(b);
      });
    final port = candidates.first;
    final forward = forwards[port];
    found.add(DiscoveredSession(
      wsUrl: 'ws://127.0.0.1:$port/ws',
      port: port,
      source: forward == null
          ? 'port:$port'
          : '${forward.device}#port:$port',
      fingerprint: entry.key,
      name: probes[port]?.name ?? '',
      remotePort: forward?.remote,
    ));
  }
  found.sort((a, b) => a.port.compareTo(b.port));
  return found;
}

// ---------------------------------------------------------------------------
// 直连（app 内 Agent）发现
// ---------------------------------------------------------------------------

/// 直连服务探测结果（app 内 `/v1/hello` 自报的元信息）。
class DiscoveredAgent {
  const DiscoveredAgent({
    required this.port,
    required this.baseUrl,
    required this.source,
    required this.appId,
    required this.packageName,
    required this.bootId,
    required this.version,
    required this.obfuscated,
    required this.caps,
    this.vmPort,
  });

  /// 本机（转发后）端口。
  final int port;
  final String baseUrl;

  /// 来源标识：adb:SERIAL#port:N / port:N。
  final String source;

  final String appId;

  /// 包名（release 下唯一可靠的 app 标识）。
  final String packageName;

  /// 进程启动随机串：同一包重启后指纹会变。
  final String bootId;

  final String version;

  /// 编译时开了 --obfuscate：类型名不可读，按类型查找会失真。
  final bool obfuscated;

  /// app 自报的能力键（与 bin/src/session/capability.dart 的 Cap 同源）。
  final List<String> caps;

  /// debug 下 app 能通过 Service.getInfo() 拿到自己的 VM service 设备端口，
  /// 用于和 VM 会话精确配对；release 恒为 null。
  final int? vmPort;

  String get deviceId {
    final i = source.indexOf('#');
    if (i <= 0) return '';
    final s = source.substring(0, i);
    return s.contains(':') ? s : '';
  }

  String get fingerprint =>
      'agent:${deviceId.isEmpty ? 'port:$port' : deviceId}:$packageName:$bootId';
}

/// 探测端口是否为 xb_ume 直连服务；命中返回详情，否则 null。
///
/// 只读 `/v1/hello`，不携带 token：发现阶段客户端还不知道 token，而 hello
/// 只返回包名/版本/能力等非敏感元信息；真正的数据接口仍要 token。
Future<DiscoveredAgent?> probeAgent(
  int port, {
  Duration connectionTimeout = const Duration(milliseconds: 300),
}) async {
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = connectionTimeout;
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port/v1/hello'))
        .timeout(const Duration(seconds: 1));
    request.headers.set('x-xbume-probe', '1');
    final response =
        await request.close().timeout(const Duration(seconds: 1));
    if (response.statusCode != 200) return null;
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 1));
    final parsed = jsonDecode(body);
    if (parsed is! Map) return null;
    if ('${parsed['service'] ?? ''}' != 'xbume-agent') return null;
    final caps = <String>[];
    final rawCaps = parsed['caps'];
    if (rawCaps is List) {
      for (final c in rawCaps) {
        if (c is String && c.isNotEmpty) caps.add(c);
      }
    }
    final vmPort = parsed['vmPort'];
    return DiscoveredAgent(
      port: port,
      baseUrl: 'http://127.0.0.1:$port',
      source: 'port:$port',
      appId: '${parsed['appId'] ?? ''}',
      packageName: '${parsed['packageName'] ?? ''}',
      bootId: '${parsed['bootId'] ?? ''}',
      version: '${parsed['version'] ?? ''}',
      obfuscated: parsed['obfuscated'] == true,
      caps: caps,
      vmPort: vmPort is int ? vmPort : int.tryParse('${vmPort ?? ''}'),
    );
  } catch (_) {
    return null;
  } finally {
    client?.close(force: true);
  }
}

/// 扫描本机直连服务（按指纹去重，优先有转发映射的端口）。
///
/// 会向本机所有回环端口发 `GET /v1/hello`；单元测试 / CI 里可能撞到其他
/// 进程的 WebSocket 端口，设 `XBUME_AGENT_PROBE=0` 可关闭。
Future<List<DiscoveredAgent>> discoverLocalAgents({
  Set<int> skipPorts = const <int>{},
  bool freshPorts = false,
}) async {
  if (Platform.environment['XBUME_AGENT_PROBE'] == '0') {
    return const <DiscoveredAgent>[];
  }
  final ports = await loopbackListeningPorts(force: freshPorts);
  final forwards = await forwardedPortMap(force: freshPorts);
  final probes = <int, DiscoveredAgent>{};
  await Future.wait(ports
      .where((p) => !skipPorts.contains(p))
      .map((port) async {
    final probe = await probeAgent(port);
    if (probe != null) probes[port] = probe;
  }));
  final byFingerprint = <String, List<int>>{};
  probes.forEach((port, probe) {
    byFingerprint.putIfAbsent(probe.fingerprint, () => <int>[]).add(port);
  });
  final found = <DiscoveredAgent>[];
  for (final entry in byFingerprint.entries) {
    final candidates = entry.value.toList()
      ..sort((a, b) {
        final fa = forwards.containsKey(a);
        final fb = forwards.containsKey(b);
        if (fa != fb) return fa ? -1 : 1;
        return a.compareTo(b);
      });
    final port = candidates.first;
    final probe = probes[port]!;
    final forward = forwards[port];
    found.add(DiscoveredAgent(
      port: port,
      baseUrl: probe.baseUrl,
      source: forward == null
          ? 'port:$port'
          : '${forward.device}#port:$port',
      appId: probe.appId,
      packageName: probe.packageName,
      bootId: probe.bootId,
      version: probe.version,
      obfuscated: probe.obfuscated,
      caps: probe.caps,
      vmPort: probe.vmPort,
    ));
  }
  found.sort((a, b) => a.port.compareTo(b.port));
  return found;
}

/// 逻辑会话：同一个 app 的 VM 通道与直连通道合并成一条，工具按能力选通道。
class LogicalSession {
  const LogicalSession({this.vm, this.agent});

  final DiscoveredSession? vm;
  final DiscoveredAgent? agent;

  bool get hasVm => vm != null;
  bool get hasAgent => agent != null;

  /// 稳定 id：有 VM 时沿用 `s<port>`（兼容既有的选择/租约/指纹逻辑）。
  String get id => vm != null ? 's${vm!.port}' : 'a${agent!.port}';

  int get port => vm?.port ?? agent!.port;
  int? get vmPort => vm?.port;
  int? get agentPort => agent?.port;
  int? get remotePort => vm?.remotePort;
  String? get deviceId => vm?.deviceId ?? agent?.deviceId;
  String? get packageName => agent?.packageName;
  bool get obfuscated => agent?.obfuscated ?? false;

  String get appName {
    final pkg = agent?.packageName ?? '';
    if (pkg.isNotEmpty) return pkg;
    return vm?.name ?? '';
  }

  String get source => vm?.source ?? agent!.source;
  String get uri => vm?.wsUrl ?? agent!.baseUrl;
  String get fingerprint => vm?.fingerprint ?? agent!.fingerprint;

  SessionTransport get transport {
    if (vm != null && agent != null) return SessionTransport.both;
    if (agent != null) return SessionTransport.agent;
    return SessionTransport.vm;
  }

  /// 各能力键的可用性（与 tools / GUI 共用同一套换算）。
  ///
  /// 直连通道按 app 自报的 caps 求交：P1 的 Agent 只有只读数据面，声明的是
  /// `inspect`，所以不会把没实现的沙盒/截图/点击点亮。
  Set<String> caps({bool vmDegraded = false}) => sessionCaps(
        transport: transport,
        obfuscated: obfuscated,
        vmDegraded: vmDegraded,
        agentCaps: agent?.caps.toSet(),
      );

  Map<String, Object?> toJson({bool vmDegraded = false}) => <String, Object?>{
        'id': id,
        'source': source,
        'uri': uri,
        'fp': fingerprint,
        'transport': sessionTransportName(transport),
        if (vmPort != null) 'vmPort': vmPort,
        if (agentPort != null) 'agentPort': agentPort,
        if ((agent?.baseUrl ?? '').isNotEmpty) 'agentUrl': agent!.baseUrl,
        if ((agent?.version ?? '').isNotEmpty) 'agentVersion': agent!.version,
        if (obfuscated) 'obfuscated': true,
        if (vmDegraded) 'vmDegraded': true,
        'caps': caps(vmDegraded: vmDegraded).toList()..sort(),
      };
}

/// 把 VM 会话与直连会话合并成逻辑会话。
///
/// 配对优先级：
///   1. 精确：app 自报的 vmPort（设备侧端口）等于该 VM 会话转发的远端端口，
///      且设备一致（debug 包 app 能通过 Service.getInfo() 自报，P1 实现）；
///   2. 兼底：同一设备上 VM 与直连各只剩一条（换包/重启导致端口变化时的
///      常见形态，唯一候选基本不会错配）；
///   3. 都不满足就并列成两条，不强行合并（同包多进程时宁可多一条）。
List<LogicalSession> mergeLogicalSessions({
  required List<DiscoveredSession> vmSessions,
  required List<DiscoveredAgent> agents,
}) {
  final pairedAgentByVm = <int, DiscoveredAgent>{};
  final usedAgents = <DiscoveredAgent>{};

  for (final agent in agents) {
    final vmPort = agent.vmPort;
    if (vmPort == null) continue;
    for (final vm in vmSessions) {
      if (pairedAgentByVm.containsKey(vm.port)) continue;
      if (vm.remotePort != vmPort) continue;
      final vmDevice = vm.deviceId;
      if (vmDevice != null &&
          agent.deviceId.isNotEmpty &&
          vmDevice != agent.deviceId) {
        continue;
      }
      pairedAgentByVm[vm.port] = agent;
      usedAgents.add(agent);
      break;
    }
  }

  // 兼底：按设备分组，两边都只剩唯一候选才配。
  final freeVmByDevice = <String, List<DiscoveredSession>>{};
  for (final vm in vmSessions) {
    if (pairedAgentByVm.containsKey(vm.port)) continue;
    freeVmByDevice.putIfAbsent(vm.deviceId ?? '', () => <DiscoveredSession>[]).add(vm);
  }
  final freeAgentByDevice = <String, List<DiscoveredAgent>>{};
  for (final agent in agents) {
    if (usedAgents.contains(agent)) continue;
    freeAgentByDevice
        .putIfAbsent(agent.deviceId, () => <DiscoveredAgent>[])
        .add(agent);
  }
  for (final entry in freeVmByDevice.entries) {
    final freeAgents = freeAgentByDevice[entry.key];
    if (freeAgents == null || freeAgents.length != 1) continue;
    if (entry.value.length != 1) continue;
    pairedAgentByVm[entry.value.first.port] = freeAgents.first;
    usedAgents.add(freeAgents.first);
  }

  final out = <LogicalSession>[];
  for (final vm in vmSessions) {
    out.add(LogicalSession(vm: vm, agent: pairedAgentByVm[vm.port]));
  }
  for (final agent in agents) {
    if (usedAgents.contains(agent)) continue;
    out.add(LogicalSession(agent: agent));
  }
  out.sort((a, b) => a.port.compareTo(b.port));
  return out;
}
