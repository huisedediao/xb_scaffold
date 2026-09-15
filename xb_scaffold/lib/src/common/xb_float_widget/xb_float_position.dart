/// 浮层内容相对锚点的展示位置
///
/// 取代原 XBFloatWidget 家族的 int type 魔数（0/1）：
/// - 旧 `type: 0`（内容在锚点下方）对应 [XBFloatPosition.below]
/// - 旧 `type: 1`（内容在锚点上方）对应 [XBFloatPosition.above]
enum XBFloatPosition {
  /// 内容展示在锚点下方（默认）
  below,

  /// 内容展示在锚点上方
  above,
}
