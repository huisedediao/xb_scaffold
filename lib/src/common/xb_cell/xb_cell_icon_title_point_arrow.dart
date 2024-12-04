import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/xb_cell/xb_right_icon.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellIconTitlePointArrow extends XBCell {
  final String icon;
  final Size? iconSize;
  final double? iconRightPadding;
  final String title;
  final TextStyle? titleStyle;
  final double? titleRightPadding;
  final double? maxTitleWidth;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  final double? pointSize;
  final Color? pointColor;
  final Color? arrowColor;
  final double? arrowLeftPadding;
  const XBCellIconTitlePointArrow(
      {required this.icon,
      this.iconSize,
      this.iconRightPadding,
      required this.title,
      this.titleStyle,
      this.titleRightPadding,
      this.maxTitleWidth,
      this.titleMaxLines,
      this.titleOverflow,
      this.pointSize,
      this.pointColor,
      this.arrowColor,
      this.arrowLeftPadding,
      super.contentHeight,
      super.margin,
      super.padding,
      super.onTap,
      super.contentBorderRadius,
      super.backgroundColor,
      super.key});

  double get _pointW => pointSize ?? 6;

  @override
  Widget buildContent() {
    return Row(
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
        SizedBox(width: titleRightPadding ?? spaces.gapLess),
        const Spacer(),
        ClipRRect(
          borderRadius: BorderRadius.circular(_pointW * 0.5),
          child: Container(
            width: _pointW,
            height: _pointW,
            color: pointColor ?? Colors.red,
          ),
        ),
        SizedBox(width: arrowLeftPadding ?? 5),
        XBCellArrow(
          color: arrowColor,
        ),
      ],
    );
  }
}
