// 直连服务的设备端口转发（adb forward / hdc fport）。
//
// app 里的 Agent 只监听设备本机回环（127.0.0.1:47100）。主机要读它，必须先
// 把主机端口转发到设备端口——这一步和设备日志采集一样属于「IDE 侧职责」，
// 不要求用户在 app 里改任何东西。
//
// 端口分配：同一序列号每轮拿到同一个主机端口（稳定哈希），且避开已有转发
// 映射；已存在的同设备同远端转发直接复用，不重复创建。
library;

import 'dart:io';

import 'discovery.dart';

/// 设备侧 Agent 默认端口（与 lib/src/agent/xb_ume_agent_types.dart 一致）。
const int kAgentDevicePort = 47100;

/// 主机侧转发端口区间（与 VM service 的 46xxx 段错开，避免混进 VM 扫描）。
const int kAgentHostPortBase = 47110;

/// 同时支持的设备数上限。
const int kAgentHostPortSpan = 40;

/// 一台可转发设备。
class AgentForwardTarget {
  const AgentForwardTarget({required this.backend, required this.id});

  /// adb / hdc。
  final String backend;

  /// adb serial 或 hdc target。
  final String id;

  /// 与 VM 会话来源同形的设备标识（用于直连/VM 配对）。
  String get source => '$backend:$id';

  @override
  String toString() => source;
}

/// 解析设备列表输出（纯函数，便于单测）。
///
/// `adb devices`：`<serial>\tdevice`，只取 state=device（unauthorized/offline 跳过）。
/// `hdc list targets`：每行一个 target，含 `[Empty]`/`error` 的行跳过。
List<AgentForwardTarget> parseForwardTargets({
  String adbDevices = '',
  String hdcTargets = '',
}) {
  final out = <AgentForwardTarget>[];
  for (final line in adbDevices.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('List of devices') || t.startsWith('*')) {
      continue;
    }
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    if (parts[1] != 'device') continue;
    out.add(AgentForwardTarget(backend: 'adb', id: parts[0]));
  }
  for (final line in hdcTargets.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.contains('[') || t.toLowerCase().contains('error')) {
      continue;
    }
    out.add(AgentForwardTarget(backend: 'hdc', id: t));
  }
  return out;
}

/// 设备 → 主机端口的稳定分配。
///
/// 用序列号哈希落在 [base, base+span) 内；同一台设备每次都是同一个端口，
/// 这样端口被别的进程（上一轮 daemon、用户手工 forward）占用时也不会串设备。
int agentHostPortFor(
  String deviceId, {
  int base = kAgentHostPortBase,
  int span = kAgentHostPortSpan,
}) {
  if (span <= 0) return base;
  var hash = 0;
  for (final code in deviceId.codeUnits) {
    hash = (hash * 31 + code) & 0x7fffffff;
  }
  return base + (hash % span);
}

/// 列出当前可转发的设备。
Future<List<AgentForwardTarget>> listForwardTargets() async {
  final adb = await runToolText('adb', <String>['devices']);
  final hdc = await runToolText('hdc', <String>['list', 'targets']);
  return parseForwardTargets(adbDevices: adb, hdcTargets: hdc);
}

/// 建立（或复用）一台设备的端口转发；已存在同设备同远端映射时直接返回 true。
Future<bool> ensureDeviceForward(
  AgentForwardTarget target,
  int hostPort, {
  int devicePort = kAgentDevicePort,
  Duration maxAge = const Duration(milliseconds: 3000),
}) async {
  final forwards = await forwardedPortMap(maxAge: maxAge);
  final hit = forwards[hostPort];
  if (hit != null && hit.remote == devicePort && hit.device == target.source) {
    return true;
  }
  final String out;
  if (target.backend == 'hdc') {
    out = await runToolText(
      'hdc',
      <String>['-t', target.id, 'fport', 'tcp:$hostPort', 'tcp:$devicePort'],
    );
  } else {
    out = await runToolText(
      'adb',
      <String>['-s', target.id, 'forward', 'tcp:$hostPort', 'tcp:$devicePort'],
    );
  }
  if (out.toLowerCase().contains('error') || out.toLowerCase().contains('cannot')) {
    return false;
  }
  return true;
}

List<DiscoveredAgent>? _cachedAgents;
DateTime? _cachedAt;
String _cachedTargets = '';

/// 为所有在线设备建立转发并探测直连服务。
///
/// 结果带 `source='adb:SERIAL#port:<主机端口>'`，与 VM 会话来源同形，配对逻辑
/// 不用特判。`XBUME_AGENT_PROBE=0` 时直接返回空（单测 / CI）。
Future<List<DiscoveredAgent>> ensureAgentForwards({
  int devicePort = kAgentDevicePort,
  Duration maxAge = const Duration(seconds: 8),
  bool force = false,
}) async {
  if (Platform.environment['XBUME_AGENT_PROBE'] == '0') {
    return const <DiscoveredAgent>[];
  }
  if (!force &&
      _cachedAgents != null &&
      _cachedAt != null &&
      DateTime.now().difference(_cachedAt!) < maxAge) {
    return _cachedAgents!;
  }
  final targets = await listForwardTargets();
  final signature = targets.map((t) => t.source).join(',');
  final forwards = await forwardedPortMap(
    maxAge: const Duration(seconds: 3),
    force: signature != _cachedTargets,
  );
  // 已被别的设备占用的主机端口先占位，避免抢用。
  final taken = <int, String>{
    for (final e in forwards.entries) e.key: e.value.device,
  };

  final found = <DiscoveredAgent>[];
  for (final target in targets) {
    var hostPort = agentHostPortFor(target.source);
    var candidate = 0;
    // 端口冲突（别的设备 / 别的远端）时顺延，最多试 span 个。
    while (candidate < kAgentHostPortSpan) {
      final owner = taken[hostPort];
      final port = forwards[hostPort];
      final reusable = port != null &&
          port.remote == devicePort &&
          port.device == target.source;
      if (reusable || (owner == null && port == null)) break;
      hostPort = kAgentHostPortBase +
          ((hostPort - kAgentHostPortBase + 1) % kAgentHostPortSpan);
      candidate++;
    }
    if (candidate >= kAgentHostPortSpan) continue;
    final ok = await ensureDeviceForward(
      target,
      hostPort,
      devicePort: devicePort,
    );
    if (!ok) continue;
    final probe = await probeAgent(hostPort);
    if (probe == null) continue;
    taken[hostPort] = target.source;
    found.add(DiscoveredAgent(
      port: hostPort,
      baseUrl: probe.baseUrl,
      source: '${target.source}#port:$hostPort',
      appId: probe.appId,
      packageName: probe.packageName,
      bootId: probe.bootId,
      version: probe.version,
      obfuscated: probe.obfuscated,
      caps: probe.caps,
      vmPort: probe.vmPort,
    ));
  }
  _cachedAgents = found;
  _cachedAt = DateTime.now();
  _cachedTargets = signature;
  return found;
}

/// 清缓存（会话列表重置 / 单测用）。
void resetAgentForwardCache() {
  _cachedAgents = null;
  _cachedAt = null;
  _cachedTargets = '';
}