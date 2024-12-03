import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/xb_cell/xb_right_icon.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellIconTitleArrow extends XBCell {
  final String icon;
  final Size? iconSize;
  final double? iconRightPadding;
  final String title;
  final TextStyle? titleStyle;
  final double? maxTitleWidth;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  final Color? arrowColor;
  final double? arrowLeftPadding;
  const XBCellIconTitleArrow(
      {required this.icon,
      this.iconSize,
      this.iconRightPadding,
      required this.title,
      this.titleStyle,
      this.maxTitleWidth,
      this.titleMaxLines,
      this.titleOverflow,
      this.arrowColor,
      this.arrowLeftPadding,
      super.contentHeight,
      super.margin,
      super.padding,
      super.onTap,
      super.contentBorderRadius,
      super.backgroundColor,
      super.key});

  @override
  Widget buildContent() {
    return Row(
      children: [
        XBImage(
          icon,
          width: iconSize?.width ?? 15,
          height: iconSize?.height ?? 15,
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
        const Spacer(),
        SizedBox(width: arrowLeftPadding ?? 5),
        XBCellArrow(
          color: arrowColor,
        ),
      ],
    );
  }
}
