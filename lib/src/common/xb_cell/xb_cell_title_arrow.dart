import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:xb_scaffold/src/common/xb_cell/xb_right_icon.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitleArrow extends XBCell {
  final String title;
  final TextStyle? titleStyle;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  final Color? arrowColor;
  final double? arrowLeftPadding;
  const XBCellTitleArrow(
      {required this.title,
      this.titleStyle,
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
        Expanded(
          child: Text(
            title,
            overflow: titleOverflow,
            style: titleStyle,
            maxLines: titleMaxLines,
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
