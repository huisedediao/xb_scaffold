import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/xb_cell/xb_right_icon.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitleSubtitleLeftArrow extends XBCell {
  final String title;
  final TextStyle? titleStyle;
  final double? titleRightPadding;
  final double? maxTitleWidth;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  final String subtitle;
  final TextStyle? subtitleStyle;
  final TextOverflow? subtitleOverflow;
  final double? maxSubtitleWidth;
  final int? subtitleMaxLines;
  final Color? arrowColor;
  final double? arrowLeftPadding;
  const XBCellTitleSubtitleLeftArrow(
      {required this.title,
      this.titleStyle,
      this.titleRightPadding,
      this.maxTitleWidth,
      this.titleMaxLines,
      this.titleOverflow,
      required this.subtitle,
      this.subtitleStyle,
      this.subtitleOverflow,
      this.maxSubtitleWidth,
      this.subtitleMaxLines,
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
        SizedBox(
          width: maxSubtitleWidth,
          child: Text(
            subtitle,
            overflow: subtitleOverflow,
            style: subtitleStyle ?? const TextStyle(color: Colors.grey),
            maxLines: subtitleMaxLines,
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
