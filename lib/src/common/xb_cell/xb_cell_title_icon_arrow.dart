import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/xb_cell/xb_right_icon.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitleIconArrow extends XBCell {
  final String image;
  final Size? imageSize;
  final double? titleRightPadding;
  final String title;
  final TextStyle? titleStyle;
  final double? maxTitleWidth;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  final Color? arrowColor;
  final double? arrowLeftPadding;
  const XBCellTitleIconArrow(
      {required this.image,
      this.imageSize,
      required this.title,
      this.titleRightPadding,
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
        XBImage(
          image,
          width: imageSize?.width ?? 50,
          height: imageSize?.height ?? 50,
        ),
        SizedBox(width: arrowLeftPadding ?? 5),
        XBCellArrow(
          color: arrowColor,
        ),
      ],
    );
  }
}
