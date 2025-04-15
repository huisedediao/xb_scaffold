import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitleImage extends XBCell {
  final double? titleRightPadding;
  final String title;
  final TextStyle? titleStyle;
  final double? maxTitleWidth;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  final String? img;
  final Size? imgSize;
  final double? imgRadius;
  const XBCellTitleImage(
      {required this.title,
      this.titleRightPadding,
      this.titleStyle,
      this.maxTitleWidth,
      this.titleMaxLines,
      this.titleOverflow,
      super.contentHeight,
      this.img,
      this.imgSize,
      this.imgRadius,
      super.margin,
      super.padding,
      super.onTap,
      super.contentBorderRadius,
      super.backgroundColor,
      super.isShowArrow,
      super.arrowColor,
      super.arrowLeftPadding,
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
      ],
    );
  }

  @override
  Widget rightWidget() {
    if (img == null) {
      return Container();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(imgRadius ?? 0),
      child: SizedBox(
        width: imgSize?.width ?? 50,
        height: imgSize?.height ?? 50,
        child: XBImage(
          img,
        ),
      ),
    );
  }
}
