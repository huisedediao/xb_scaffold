import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitle extends XBCell {
  final String title;
  final TextStyle? titleStyle;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  const XBCellTitle(
      {required this.title,
      this.titleStyle,
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
    return Text(
      title,
      overflow: titleOverflow,
      style: titleStyle,
      maxLines: titleMaxLines,
    );
  }
}
