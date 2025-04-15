import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitleSubtitle extends XBCell {
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
  const XBCellTitleSubtitle(
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
        const Spacer(),
        SizedBox(
          width: maxSubtitleWidth,
          child: Text(
            subtitle,
            overflow: subtitleOverflow,
            style: subtitleStyle ?? const TextStyle(color: Colors.grey),
            maxLines: subtitleMaxLines,
          ),
        )
      ],
    );
  }
}
