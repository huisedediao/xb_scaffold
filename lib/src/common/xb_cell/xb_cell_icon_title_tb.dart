import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellIconTitleTb extends XBCell {
  final String icon;
  final Size? iconSize;
  final String title;
  final TextStyle? titleStyle;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  final double? gap;
  const XBCellIconTitleTb(
      {required this.icon,
      required this.title,
      this.iconSize,
      this.titleStyle,
      this.titleMaxLines,
      this.titleOverflow,
      this.gap,
      super.margin,
      super.padding,
      super.onTap,
      super.contentBorderRadius,
      super.backgroundColor,
      super.key});

  @override
  Widget buildContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
            width: iconSize?.width,
            height: iconSize?.height,
            child: XBImage(icon)),
        SizedBox(
          height: gap ?? 5,
        ),
        Text(
          title,
          maxLines: titleMaxLines,
          overflow: titleOverflow,
          style: titleStyle,
        )
      ],
    );
  }
}
