import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellIconTitle extends XBCell {
  final String icon;
  final Size? iconSize;
  final double? iconRightPadding;
  final String title;
  final TextStyle? titleStyle;
  final double? maxTitleWidth;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  const XBCellIconTitle(
      {required this.icon,
      this.iconSize,
      this.iconRightPadding,
      required this.title,
      this.titleStyle,
      this.maxTitleWidth,
      this.titleMaxLines,
      this.titleOverflow,
      super.contentHeight,
      super.margin,
      super.padding,
      super.onTap,
      super.contentBorderRadius,
      super.backgroundColor,
      super.isShowArrow,
      super.arrowColor,
      super.arrowLeftPadding,
      super.arrowSize,
      super.key});

  @override
  Widget buildContent() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: iconSize?.width ?? 15,
          height: iconSize?.height ?? 15,
          child: XBImage(
            icon,
          ),
        ),
        SizedBox(width: iconRightPadding ?? spaces.gapLess),
        SizedBox(
          width: maxTitleWidth,
          child: Text(
            title,
            overflow: titleOverflow,
            style: titleStyle,
            maxLines: titleMaxLines,
          ),
        ),
      ],
    );
  }
}
