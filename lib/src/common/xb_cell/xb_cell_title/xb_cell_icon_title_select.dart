import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellIconTitleSelect extends XBCellTitleSelect {
  final String icon;
  final Size? iconSize;
  final double? iconRightPadding;
  const XBCellIconTitleSelect(
      {required this.icon,
      this.iconSize,
      this.iconRightPadding,
      required super.title,
      required super.isSelected,
      super.titleStyle,
      super.titleRightPadding,
      super.maxTitleWidth,
      super.titleMaxLines,
      super.titleOverflow,
      super.selectedColor,
      super.unSelectedColor,
      super.contentHeight,
      super.margin,
      super.padding,
      super.onTap,
      super.contentBorderRadius,
      super.backgroundColor,
      super.arrowColor,
      super.isShowArrow = false,
      super.arrowLeftPadding,
      super.arrowSize,
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
