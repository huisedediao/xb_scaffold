// 直连通道（app 内 Agent 服务）的类型与契约。
//
// 背景：release 包里没有 VM service，`eval` / 断点 / 热重载物理不可用；但
// 日志、异常、网络、路由、帧率这些数据本来就在 process 内，app 自己就能读。
// 所以这里起一个**只读**的 loopback HTTP 服务，让 IDE 侧（GUI / MCP）用固定
// 协议取数——传输层换掉，工具层与界面不用区分通道。
//
// 默认关闭：`--dart-define=XBUME_AGENT=1` 才随 app 启动（release 内测包用）；
// 也可在代码里 `XBUme.startAgentServer()` 显式打开。
library;

/// 服务标识：探测方只认这一个值，避免误把手写 HTTP 服务当成本服务。
const String kXBUmeAgentService = 'xbume-agent';

/// 协议版本：破坏性调整端点/字段时递增。
const int kXBUmeAgentProtocol = 1;

/// 默认监听端口（设备侧）。
const int kXBUmeAgentDefaultPort = 47100;

/// 编译期开关：默认关闭，内测包用 `--dart-define=XBUME_AGENT=1` 打开。
///
/// 不能直接用 `bool.fromEnvironment`：它只认 `true`，而大家习惯写 `=1`
/// （写上 `=1` 却静默不生效，排查代价很大），这里两种都接受。
const String _kAgentEnabledRaw = String.fromEnvironment('XBUME_AGENT');

const bool kXBUmeAgentDefaultEnabled = _kAgentEnabledRaw == '1' ||
    _kAgentEnabledRaw == 'true' ||
    _kAgentEnabledRaw == 'TRUE' ||
    _kAgentEnabledRaw == 'True';

/// 编译期端口覆盖：`--dart-define=XBUME_AGENT_PORT=47101`。
const int kXBUmeAgentEnvPort =
    int.fromEnvironment('XBUME_AGENT_PORT', defaultValue: kXBUmeAgentDefaultPort);

/// 编译期 token：`--dart-define=XBUME_AGENT_TOKEN=xxx`（空 = 不校验）。
const String kXBUmeAgentEnvToken = String.fromEnvironment('XBUME_AGENT_TOKEN');

/// 编译期应用标识：`--dart-define=XBUME_AGENT_APP=com.example.app`。
///
/// 纯 Dart 拿不到包名；Android 会尝试从 `/proc/self/cmdline` 自采，采不到
/// （iOS / 桌面 / 自定义进程名）才需要构建方显式给一个，用于下拉展示。
const String kXBUmeAgentEnvApp = String.fromEnvironment('XBUME_AGENT_APP');

/// 编译期混淆标记：`--dart-define=XBUME_AGENT_OBFUSCATED=1`。
///
/// Dart 运行时拿不到「是否 --obfuscate」的可靠信号，只能由构建方声明：
/// 声明后 IDE 侧会禁用「按类型名查找」类功能（源码定位降级为启发式）。
const String _kAgentObfuscatedRaw =
    String.fromEnvironment('XBUME_AGENT_OBFUSCATED');

const bool kXBUmeAgentEnvObfuscated = _kAgentObfuscatedRaw == '1' ||
    _kAgentObfuscatedRaw == 'true' ||
    _kAgentObfuscatedRaw == 'TRUE' ||
    _kAgentObfuscatedRaw == 'True';

/// 直连通道已实现的能力键（与 bin/src/session/capability.dart 的 Cap 同源）。
///
/// P1：`inspect`（日志/网络/异常/时间轴）；
/// P2：`widgets`（组件树 / find_widget / ref）、`act`（点击/输入/滑动/跳转）、
///     `shot`（app 内渲染截图）；
/// P3：`fs`（沙盒只读 / shared_prefs 读写 / SQLite 文件枚举）、
///     `perf`（帧耗时统计 + 进程 CPU/内存；没有 VM 的堆/isolate 采样）、
///     `inspectable`（app 注册的字段树，替代 VM 的实例展开）、
///     `srclocate:heuristic`（路由事件 + 路由名推类名，在本机源码里找声明）。
const List<String> kXBUmeAgentCaps = <String>[
  'inspect',
  'fs',
  'widgets',
  'act',
  'shot',
  'perf',
  'inspectable',
  'srclocate:heuristic',
];

/// 直连服务选项。
class XBUmeAgentOptions {
  const XBUmeAgentOptions({
    this.enabled = false,
    this.port = kXBUmeAgentDefaultPort,
    this.token = '',
    this.appId = '',
    this.packageName = '',
    this.obfuscated = false,
    this.vmPort,
    this.caps = kXBUmeAgentCaps,
    this.bindAllInterfaces = false,
  });

  /// 读编译期 define。构建方没声明就返回 `enabled=false`（默认关闭）。
  factory XBUmeAgentOptions.fromEnvironment({
    String packageName = '',
    String appId = '',
    int? vmPort,
  }) {
    return XBUmeAgentOptions(
      enabled: kXBUmeAgentDefaultEnabled,
      port: kXBUmeAgentEnvPort,
      token: kXBUmeAgentEnvToken,
      appId: appId.isNotEmpty ? appId : kXBUmeAgentEnvApp,
      packageName: packageName.isNotEmpty ? packageName : kXBUmeAgentEnvApp,
      obfuscated: kXBUmeAgentEnvObfuscated,
      vmPort: vmPort,
    );
  }

  final bool enabled;

  /// 设备侧监听端口；经 adb forward / hdc fport 映射到主机端口后被发现。
  final int port;

  /// 非空时所有数据端点都要求 `x-xbume-token` 头（`/v1/hello` 除外：
  /// 发现阶段还不知道 token，hello 只回非敏感元信息）。
  final String token;

  /// app 标识（包名/工程名），用于 IDE 下拉展示。
  final String appId;
  final String packageName;

  /// 构建时开了 `--obfuscate`：类型名不可读。
  final bool obfuscated;

  /// debug/profile 下 app 自己 VM service 的设备端口，仅用于与 VM 会话精确配对。
  final int? vmPort;

  /// 自报能力键。
  final List<String> caps;

  /// true = 监听 0.0.0.0（默认只监听 127.0.0.1，减少暴露面）。
  final bool bindAllInterfaces;

  XBUmeAgentOptions copyWith({
    bool? enabled,
    int? port,
    String? token,
    String? appId,
    String? packageName,
    bool? obfuscated,
    int? vmPort,
    List<String>? caps,
    bool? bindAllInterfaces,
  }) {
    return XBUmeAgentOptions(
      enabled: enabled ?? this.enabled,
      port: port ?? this.port,
      token: token ?? this.token,
      appId: appId ?? this.appId,
      packageName: packageName ?? this.packageName,
      obfuscated: obfuscated ?? this.obfuscated,
      vmPort: vmPort ?? this.vmPort,
      caps: caps ?? this.caps,
      bindAllInterfaces: bindAllInterfaces ?? this.bindAllInterfaces,
    );
  }
}

/// 已启动的直连服务句柄。
abstract class XBUmeAgentServer {
  /// 实际监听端口（传 0 时由系统分配）。
  int get port;

  /// `http://127.0.0.1:<port>`（IDE 侧当作会话 uri 用）。
  String get baseUrl;

  Future<void> close();
}