/// 自动点击采集配置。
class XBAutoTrackConfig {
  const XBAutoTrackConfig({
    this.enabled = true,
    this.eventName = 'auto_click',
    this.maxDepth = 30,
    this.textMaxLength = 60,
    this.blacklist = const <String>[],
    this.extraNoiseTypes = const <String>[],
  });

  /// 总开关，false 时点击拦截直接短路。
  final bool enabled;

  /// 上报的事件名。
  final String eventName;

  /// 类型链向上遍历的最大深度，超出即截断。
  final int maxDepth;

  /// 可读文本截断上限，防止把长文本打进埋点。
  final int textMaxLength;

  /// Widget 类型名前缀黑名单：链上任一节点命中即丢弃整条事件，
  /// 用于过滤调试工具自身 UI（如 xb_ume 面板）造成的点击污染。
  final List<String> blacklist;

  /// 额外的噪声类型：这些类型在链遍历中跳过不收集（见内置默认集），
  /// 业务可追加自己框架的布局壳类型。
  final List<String> extraNoiseTypes;
}
