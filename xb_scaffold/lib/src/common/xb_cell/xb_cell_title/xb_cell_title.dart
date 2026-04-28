import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitle extends XBCell {
  final String title;
  final TextStyle? titleStyle;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  final double? titleRightPadding;
  final double? maxTitleWidth;
  const XBCellTitle(
      {required this.title,
      this.titleStyle,
      this.titleMaxLines,
      this.titleOverflow,
      this.titleRightPadding,
      this.maxTitleWidth,
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
      ],
    );
  }
}
