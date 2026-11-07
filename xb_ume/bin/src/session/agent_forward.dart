// 直连服务的设备端口转发（adb forward / hdc fport / iOS iproxy）。
//
// app 里的 Agent 只监听设备本机回环（127.0.0.1:47100）。主机要读它，必须先
// 把主机端口转发到设备端口——这一步和设备日志采集一样属于「IDE 侧职责」，
// 不要求用户在 app 里改任何东西。
//
// 三种设备两类机制：adb / hdc 是**注册式**转发（命令执行完就完事，转发表能查）；
// iOS 真机用 libimobiledevice 的 `iproxy`，它是**长驻进程**（一设备一个），
// 所以这里自己持有 Process 句柄，退出时按句柄 kill，绝不按进程名乱杀。
//
// 端口分配：同一设备标识每轮拿到同一个主机端口（稳定哈希），且避开已有转发
// 映射；已存在的同设备同远端转发直接复用，不重复创建。
library;

import 'dart:async';
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

  /// adb / hdc / ios（真机走 iproxy）。
  final String backend;

  /// adb serial、hdc target 或 iOS UDID。
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
/// `idevice_id -l`：每行一个 UDID（iOS 真机，libimobiledevice）。
List<AgentForwardTarget> parseForwardTargets({
  String adbDevices = '',
  String hdcTargets = '',
  String ideviceIds = '',
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
  out.addAll(parseIdeviceIds(ideviceIds)
      .map((id) => AgentForwardTarget(backend: 'ios', id: id)));
  return out;
}

/// 解析 `idevice_id -l` 的 UDID 列表（纯函数）。
///
/// 无设备时输出为空；设备未配对 / usbmuxd 没起来时会有 `ERROR:` 行，一并跳过。
/// 老机型 UDID 是 40 位十六进制，新机型形如 `00008101-000E6D843C68801E`。
List<String> parseIdeviceIds(String out) {
  final list = <String>[];
  for (final line in out.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final lower = t.toLowerCase();
    if (lower.startsWith('error') || lower.startsWith('no device')) continue;
    if (!RegExp(r'^[0-9A-Za-z][0-9A-Za-z-]*$').hasMatch(t)) continue;
    list.add(t);
  }
  return list;
}

/// `iproxy` 的参数（纯函数，便于单测）。
///
/// 用 `LOCAL:DEVICE` 单参数形式：iproxy 的双参数旧写法在部分版本上会把
/// `-u` 当端口解析。
List<String> iproxyArgs(int hostPort, int devicePort, String udid) =>
    <String>['$hostPort:$devicePort', '-u', udid];

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
///
/// Windows 上没有 libimobiledevice，`idevice_id` 会直接失败并返回空串，
/// 不影响 adb / hdc 两条链路。
Future<List<AgentForwardTarget>> listForwardTargets() async {
  final adb = await runToolText('adb', <String>['devices']);
  final hdc = await runToolText('hdc', <String>['list', 'targets']);
  final ios = Platform.isWindows
      ? ''
      : await runToolText('idevice_id', <String>['-l']);
  return parseForwardTargets(
    adbDevices: adb,
    hdcTargets: hdc,
    ideviceIds: ios,
  );
}

// 自己拉起的 iproxy（长驻进程）：设备标识 → 进程 / 主机端口。
final Map<String, Process> _iproxyProcs = <String, Process>{};
final Map<String, int> _iproxyPorts = <String, int>{};

/// 建立（或复用）一台设备的端口转发；已存在同设备同远端映射时直接返回 true。
///
/// iOS 的 `iproxy` 没有转发表可查，所以复用判断靠自持进程 + 端口一致。
Future<bool> ensureDeviceForward(
  AgentForwardTarget target,
  int hostPort, {
  int devicePort = kAgentDevicePort,
  Duration maxAge = const Duration(milliseconds: 3000),
}) async {
  if (target.backend == 'ios') {
    return _ensureIproxy(target.id, hostPort, devicePort);
  }
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

/// 启动（或复用）一条 iproxy：`iproxy <主机端口>:<设备端口> -u <UDID>`。
///
/// 只有「自持进程还在、且主机端口没变」才复用；否则先按句柄 kill 旧的再起。
/// 实测：iproxy 即使设备不在也会立刻监听端口（懒连接），所以「端口可连」
/// 只能证明进程起来了，是否真的能读到 app 仍由调用方的 `/v1/hello` 探测决定。
Future<bool> _ensureIproxy(String udid, int hostPort, int devicePort) async {
  final key = 'ios:$udid';
  if (_iproxyProcs[key] != null && _iproxyPorts[key] == hostPort) return true;
  await _killIproxy(key);
  try {
    final proc = await Process.start(
      'iproxy',
      iproxyArgs(hostPort, devicePort, udid),
      environment: <String, String>{'PATH': augmentedToolPath()},
    );
    // stdout / stderr 必须消费：管道写满后 iproxy 会卡住，转发就不通了。
    unawaited(proc.stdout.drain<void>());
    unawaited(proc.stderr.drain<void>());
    _iproxyProcs[key] = proc;
    _iproxyPorts[key] = hostPort;
    unawaited(proc.exitCode.then((_) {
      // 进程退出（拔线 / 设备未信任 / 端口被抢）后丢掉句柄，下一轮重建。
      if (_iproxyProcs[key] == proc) {
        _iproxyProcs.remove(key);
        _iproxyPorts.remove(key);
      }
    }).catchError((_) {}));
    if (await _waitPort(hostPort)) return true;
    await _killIproxy(key);
    return false;
  } catch (_) {
    // iproxy 没装（没装 libimobiledevice）：静默跳过这台设备。
    return false;
  }
}

/// 等主机端口可连（iproxy 启动后绑端口是异步的）。
///
/// 注意：iproxy 对不存在的设备也会监听端口，这里只当「进程起来了」。
Future<bool> _waitPort(
  int port, {
  Duration max = const Duration(milliseconds: 1500),
}) async {
  final deadline = DateTime.now().add(max);
  while (DateTime.now().isBefore(deadline)) {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 250),
      );
      return true;
    } catch (_) {
      // 还没监听：等一会儿再试。
    } finally {
      socket?.destroy();
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  return false;
}

/// 按句柄结束自己起的 iproxy（不按进程名匹配，避免误伤其他工具的同名进程）。
Future<void> _killIproxy(String key) async {
  final proc = _iproxyProcs.remove(key);
  _iproxyPorts.remove(key);
  if (proc == null) return;
  proc.kill();
  try {
    await proc.exitCode.timeout(const Duration(milliseconds: 600));
  } catch (_) {
    // 忽略：已经退了或超时都无所谓。
  }
}

/// 结束全部自持的 iproxy（GUI / MCP 退出时调用）。
Future<void> stopAgentForwardProcesses() async {
  for (final key in _iproxyProcs.keys.toList(growable: false)) {
    await _killIproxy(key);
  }
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
  // 已被别的设备占用的主机端口先占位，避免抢用。自持的 iproxy 端口不在
  // adb/hdc 转发表里，必须单独算进来，否则两台 iPhone 会抢同一个端口。
  final taken = <int, String>{
    for (final e in forwards.entries) e.key: e.value.device,
    for (final e in _iproxyPorts.entries) e.value: e.key,
  };
  // 已经被任何进程监听的端口也不能用（adb forward 会失败；iproxy 同理）。
  final listening = (await loopbackListeningPorts()).toSet();

  final found = <DiscoveredAgent>[];
  for (final target in targets) {
    var hostPort = agentHostPortFor(target.source);
    var candidate = 0;
    // 端口冲突（别的设备 / 别的远端 / 别的进程）时顺延，最多试 span 个。
    while (candidate < kAgentHostPortSpan) {
      final owner = taken[hostPort];
      final port = forwards[hostPort];
      final mine = target.backend == 'ios' &&
          _iproxyProcs['ios:${target.id}'] != null &&
          _iproxyPorts['ios:${target.id}'] == hostPort;
      final reusable = mine ||
          (port != null &&
              port.remote == devicePort &&
              port.device == target.source);
      if (reusable ||
          (owner == null && port == null && !listening.contains(hostPort))) {
        break;
      }
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