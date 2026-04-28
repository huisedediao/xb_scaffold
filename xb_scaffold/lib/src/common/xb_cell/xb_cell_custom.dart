import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellCustom extends XBCell {
  final Widget contentOverride;
  final Widget? bottomContentOverride;
  final Widget? leftWidgetOverride;
  final Widget? rightWidgetOverride;
  final Widget? arrowWidgetOverride;
  final Widget? bottomWidgetOverride;
  const XBCellCustom(
      {required this.contentOverride,
      this.bottomContentOverride,
      this.leftWidgetOverride,
      this.rightWidgetOverride,
      this.arrowWidgetOverride,
      this.bottomWidgetOverride,
      super.contentHeight,
      super.margin,
      super.padding,
      super.onTap,
      super.contentBorderRadius,
      super.backgroundColor,
      super.backgroundWidget,
      super.isShowArrow,
      super.arrowColor,
      super.arrowLeftPadding,
      super.arrowSize,
      super.isNeedBtn,
      super.key});

  @override
  Widget content() => contentOverride;

  @override
  Widget bottomContent() => bottomContentOverride ?? super.bottomContent();

  @override
  Widget leftWidget() => leftWidgetOverride ?? super.leftWidget();

  @override
  Widget rightWidget() => rightWidgetOverride ?? super.rightWidget();

  @override
  Widget arrowWidget() => arrowWidgetOverride ?? super.arrowWidget();

  @override
  Widget bottomWidget() => bottomWidgetOverride ?? super.bottomWidget();
}
