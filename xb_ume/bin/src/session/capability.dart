// 会话能力模型（P0）：一条会话「能做什么」由它走的传输通道决定。
//
// 为什么单独一层：工具层不写 `if (vm) ... else ...`，GUI 置灰也需要同一份
// 事实来源。transport → caps 的换算、缺能力时的人话说明都是纯函数，单测覆盖。
//
// 通道定义：
//   vm    = VM service（debug/profile）：eval、断点、热重载、GC 全在；
//   agent = app 内直连服务（HTTP 固定 RPC）：数据面/动作面齐全，但 AOT 下
//           没有 eval / 断点 / 热重载，源码位置只能启发式匹配。
library;

/// 能力键（工具与 GUI 置灰共用同一份字符串）。
abstract final class Cap {
  /// 状态 / 路由 / 日志 / 网络 / 异常 / 时间轴 / 帧统计。
  static const String inspect = 'inspect';

  /// 沙盒 / SQLite / shared_prefs。
  static const String fs = 'fs';

  /// 点击 / 输入 / 滑动 / 导航。
  static const String act = 'act';

  /// 组件树 / find_widget / ref。
  static const String widgets = 'widgets';

  /// 截图。
  static const String shot = 'shot';

  /// FPS / 帧耗时 / 内存采样。
  static const String perf = 'perf';

  /// 触发 GC / reassemble（UI 重建）。
  static const String gc = 'gc';

  /// 断点 / 单步 / 变量树 / 任意求值。
  static const String debug = 'debug';

  /// 热重载 / 热重启。
  static const String hot = 'hot';

  /// 精确源码定位（debugCreator 给出的创建位置）。
  static const String srclocateExact = 'srclocate:exact';

  /// 启发式源码定位（按类型名 + 文本反查，可能是候选列表）。
  static const String srclocateHeuristic = 'srclocate:heuristic';

  /// 可读类型名（未混淆）。
  static const String names = 'names';
}

/// 传输通道。
enum SessionTransport { vm, agent, both }

const String kTransportVm = 'vm';
const String kTransportAgent = 'agent';
const String kTransportBoth = 'both';

/// 解析线上的 transport 字符串；未知值返回 null（调用方按「未知」保守处理）。
SessionTransport? parseSessionTransport(String? raw) {
  switch (raw) {
    case kTransportVm:
      return SessionTransport.vm;
    case kTransportAgent:
      return SessionTransport.agent;
    case kTransportBoth:
      return SessionTransport.both;
  }
  return null;
}

/// 线上表示的 transport 字符串。
String sessionTransportName(SessionTransport t) {
  switch (t) {
    case SessionTransport.vm:
      return kTransportVm;
    case SessionTransport.agent:
      return kTransportAgent;
    case SessionTransport.both:
      return kTransportBoth;
  }
}

/// VM service 通道全量能力（debug/profile）。
const Set<String> kVmCaps = <String>{
  Cap.inspect,
  Cap.fs,
  Cap.act,
  Cap.widgets,
  Cap.shot,
  Cap.perf,
  Cap.gc,
  Cap.debug,
  Cap.hot,
  Cap.srclocateExact,
  Cap.names,
};

/// 直连（app 内 Agent）通道的能力：少 debug / hot / gc / 精确源码定位。
const Set<String> kAgentCaps = <String>{
  Cap.inspect,
  Cap.fs,
  Cap.act,
  Cap.widgets,
  Cap.shot,
  Cap.perf,
  Cap.srclocateHeuristic,
};

/// 会话实际可用能力。
///
/// [vmDegraded]：VM 通道存在但当前不可用（连接失败/端口漂移），本轮按直连
/// 通道的能力算，等下一轮探测恢复后再回到 VM。
Set<String> sessionCaps({
  required SessionTransport transport,
  bool obfuscated = false,
  bool vmDegraded = false,
}) {
  final useVm = !vmDegraded &&
      (transport == SessionTransport.vm || transport == SessionTransport.both);
  final useAgent = transport == SessionTransport.agent ||
      transport == SessionTransport.both;
  final caps = <String>{};
  if (useVm) caps.addAll(kVmCaps);
  if (useAgent) {
    caps.addAll(kAgentCaps);
    // 混淆后类型名变成 A/B/C：按类型查找、源码文本匹配都会失真。
    if (!obfuscated) caps.add(Cap.names);
  }
  // 两条通道并存时，精确源码定位优先（VM 能给就不标启发式）。
  if (caps.contains(Cap.srclocateExact)) {
    caps.remove(Cap.srclocateHeuristic);
  }
  return caps;
}

/// 能力 → 人话（GUI tooltip 与工具报错共用）。
const Map<String, String> kCapLabels = <String, String>{
  Cap.inspect: '日志 / 网络 / 异常 / 时间轴',
  Cap.fs: '沙盒 / 存储 / 数据库',
  Cap.act: '点击 / 输入 / 滑动',
  Cap.widgets: '组件树',
  Cap.shot: '截图',
  Cap.perf: '性能采样',
  Cap.gc: '触发 GC / UI 重建',
  Cap.debug: '断点 / 单步 / 变量树 / 求值',
  Cap.hot: '热重载 / 热重启',
  Cap.srclocateExact: '精确源码定位',
  Cap.srclocateHeuristic: '源码定位（启发式）',
  Cap.names: '可读类型名',
};

String capLabel(String cap) => kCapLabels[cap] ?? cap;

/// 「A、B、C」形式的能力说明。
String capLabelsText(Iterable<String> caps) => caps.map(capLabel).join('、');

/// 缺能力的原因（GUI 黄条 / 工具报错都用它）。
String capGapReason(
  SessionTransport transport, {
  bool vmDegraded = false,
}) {
  if (vmDegraded) return 'VM 通道已断开，本轮临时走直连通道';
  if (transport == SessionTransport.agent) {
    return '直连会话（release 包没有 VM 调试服务）';
  }
  return '当前会话不支持';
}

/// 缺能力的完整说明。
String capGapMessage(
  Iterable<String> missing, {
  required SessionTransport transport,
  bool vmDegraded = false,
}) {
  final list = missing.toList();
  if (list.isEmpty) return '';
  return '当前会话不支持 ${capLabelsText(list)}：'
      '${capGapReason(transport, vmDegraded: vmDegraded)}';
}

/// [have] 是否覆盖 [need] 的全部能力。
bool hasAllCaps(Set<String> have, Iterable<String> need) =>
    need.every(have.contains);

/// [need] 里缺失的能力。
List<String> missingCaps(Set<String> have, Iterable<String> need) =>
    need.where((c) => !have.contains(c)).toList();

/// 工具 / 步骤 → 硬性能力需求。
///
/// 只登记「没有就真的做不到」的项；能降级的（如 route_locate 走启发式）
/// 不写进来，由实现自己决定降级程度。P0 只做登记，P1 由 tools 层在调用前
/// 查这张表，工具 handler 里不出现 transport 分支。
const Map<String, List<String>> kToolNeeds = <String, List<String>>{
  // 调试协议面：release 无解。
  'xbume_debug_attach': <String>[Cap.debug],
  'xbume_debug_state': <String>[Cap.debug],
  'xbume_debug_breakpoints': <String>[Cap.debug],
  'xbume_debug_control': <String>[Cap.debug],
  'xbume_debug_inspect': <String>[Cap.debug],
  'xbume_debug_output': <String>[Cap.debug],
  'xbume_eval': <String>[Cap.debug],
  'xbume_hot_reload': <String>[Cap.hot],
  // 部分项：主体可用，个别子操作需要额外能力（实现里单独判断）。
  'xbume_perf': <String>[Cap.perf],
  'xbume_screenshot': <String>[Cap.shot],
  'xbume_widget_tree': <String>[Cap.widgets],
  'xbume_find_widget': <String>[Cap.widgets],
  'xbume_tap': <String>[Cap.act],
  'xbume_input': <String>[Cap.act],
  'xbume_swipe': <String>[Cap.act],
  'xbume_navigate': <String>[Cap.act],
};

/// 调试中枢 / GUI 的个别按钮 → 能力（前端置灰用不到这个表，但
/// `/api/capabilities` 与 MCP 报错文案共用同一份，避免两边说法不一致）。
const Map<String, List<String>> kFeatureNeeds = <String, List<String>>{
  'breakpoints': <String>[Cap.debug],
  'step': <String>[Cap.debug],
  'variables': <String>[Cap.debug],
  'evaluate': <String>[Cap.debug],
  'hotReload': <String>[Cap.hot],
  'gc': <String>[Cap.gc],
  'reassemble': <String>[Cap.gc],
  'sourceExact': <String>[Cap.srclocateExact],
};