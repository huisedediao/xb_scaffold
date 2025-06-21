import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellIconTitle extends XBCellTitle {
  final String icon;
  final Size? iconSize;
  final double? iconRightPadding;
  const XBCellIconTitle(
      {required this.icon,
      required super.title,
      this.iconSize,
      this.iconRightPadding,
      super.titleStyle,
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
      super.titleRightPadding,
      super.maxTitleWidth,
      super.titleMaxLines,
      super.titleOverflow,
      super.isNeedBtn,
      super.key});

  @override
  Widget leftWidget() {
    return Padding(
      padding: EdgeInsets.only(right: iconRightPadding ?? spaces.gapLess),
      child: SizedBox(
        width: iconSize?.width ?? 15,
        height: iconSize?.height ?? 15,
        child: XBImage(
          icon,
        ),
      ),
    );
  }
}
