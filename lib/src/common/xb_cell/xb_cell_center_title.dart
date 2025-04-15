import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellCenterTitle extends XBCell {
  final String title;
  final TextStyle? titleStyle;
  final TextOverflow? titleOverflow;
  const XBCellCenterTitle(
      {required this.title,
      this.titleStyle,
      this.titleOverflow,
      super.contentHeight,
      super.backgroundColor,
      super.margin,
      super.padding,
      super.onTap,
      super.contentBorderRadius,
      super.arrowColor,
      super.isShowArrow,
      super.arrowLeftPadding,
      super.arrowSize,
      super.key});

  @override
  Widget buildContent() {
    return Container(
      alignment: Alignment.center,
      child: Text(
        title,
        overflow: titleOverflow,
        style: titleStyle,
      ),
    );
  }
}
