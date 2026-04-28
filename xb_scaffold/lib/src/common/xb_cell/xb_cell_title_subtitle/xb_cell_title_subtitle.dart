import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

enum XBCellAlignment {
  left,
  right,
}

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
  final XBCellAlignment subtitleAlignment;
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
      this.subtitleAlignment = XBCellAlignment.right,
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
  Widget content() {
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
        ..._buildSubtitle()
      ],
    );
  }

  List<Widget> _buildSubtitle() {
    if (subtitleAlignment == XBCellAlignment.left) {
      return [
        SizedBox(
          width: maxSubtitleWidth,
          child: Text(
            subtitle,
            overflow: subtitleOverflow,
            textAlign: TextAlign.start,
            style: subtitleStyle ?? const TextStyle(color: Colors.grey),
            maxLines: subtitleMaxLines,
          ),
        ),
        const Spacer(),
      ];
    } else {
      return [
        const Spacer(),
        SizedBox(
          width: maxSubtitleWidth,
          child: Text(
            subtitle,
            overflow: subtitleOverflow,
            textAlign: TextAlign.end,
            style: subtitleStyle ?? const TextStyle(color: Colors.grey),
            maxLines: subtitleMaxLines,
          ),
        )
      ];
    }
  }
}
