import 'package:flutter/material.dart';

import '../../xb_scaffold.dart' show xbDialogStyle;

/// 分区内容 builder：返回 null 则走框架默认渲染
typedef XBDialogPartBuilder = Widget? Function(
    BuildContext context, XBDialogStyle style);

/// dialog 各分区的内容 builder 集合（结构不变，仅替换分区内容）
class XBDialogPartBuilders {
  /// 覆盖标题区（含上下间距），返回 null 走默认渲染
  final XBDialogPartBuilder? title;

  /// 覆盖内容区（仅 dialogContent 有意义），返回 null 走默认渲染
  final XBDialogPartBuilder? content;

  /// 覆盖整个按钮行（onSelected 回调语义由业务方自行保持），返回 null 走默认渲染
  final XBDialogPartBuilder? buttons;

  const XBDialogPartBuilders({this.title, this.content, this.buttons});
}

/// dialog 全局样式配置，所有字段可空，null 时回退框架默认值。
///
/// 取值优先级：调用处参数 > 全局 xbDialogStyle > 框架默认值。
/// 通过 XBScaffold(dialogStyle:) 注入或 xbSetDialogStyle() 动态设置。
class XBDialogStyle {
  /// 卡片容器背景色（dialog/dialogContent/XBDialogInput 共用），默认 Colors.white
  final Color? backgroundColor;

  /// 卡片圆角，默认 10
  final double? radius;

  /// 标题样式，dialog 默认 s18+medium，input 默认 s16+semiBold
  final TextStyle? titleStyle;

  /// 正文/副标题样式，dialog 默认 s15+#808080，input subTitle 默认 s14+grey
  final TextStyle? msgStyle;

  /// 内容区 padding，默认维持现有间距
  final EdgeInsets? contentPadding;

  /// 分隔线颜色（横向 + 按钮间竖线），默认框架 lineColor
  final Color? lineColor;

  /// 按钮行高度，默认 50
  final double? btnHeight;

  /// 按钮字号，默认 s16
  final double? btnFontSize;

  /// 默认按钮颜色（双按钮的第一个），默认 Colors.black
  final Color? btnDefaultColor;

  /// 高亮按钮颜色（最后一个/唯一按钮），默认 colors.primary（跟随主题）
  final Color? btnHighLightColor;

  /// 输入弹窗输入框边框颜色，默认 Colors.grey.withAlpha(80)
  final Color? inputBorderColor;

  /// 卡片最大宽度（横屏收窄 dialog 宽度用），
  /// 取值优先级：调用处 maxWidth > XBDialogStyle.maxWidth > 框架默认（screenW - gapDef*2）
  final double? maxWidth;

  /// 分区内容 builder 集合（可选）
  final XBDialogPartBuilders? partBuilders;

  const XBDialogStyle({
    this.backgroundColor,
    this.radius,
    this.titleStyle,
    this.msgStyle,
    this.contentPadding,
    this.lineColor,
    this.btnHeight,
    this.btnFontSize,
    this.btnDefaultColor,
    this.btnHighLightColor,
    this.inputBorderColor,
    this.maxWidth,
    this.partBuilders,
  });
}

/// 分区渲染辅助：配置了 builder 则调用（返回 null 回退 defaultChild），
/// 否则直接渲染 defaultChild，保证“返回 null 走默认渲染”的语义。
class XBDialogPart extends StatelessWidget {
  final XBDialogPartBuilder? builder;
  final Widget defaultChild;

  const XBDialogPart({super.key, required this.defaultChild, this.builder});

  @override
  Widget build(BuildContext context) {
    final style = xbDialogStyle ?? const XBDialogStyle();
    return builder?.call(context, style) ?? defaultChild;
  }
}
