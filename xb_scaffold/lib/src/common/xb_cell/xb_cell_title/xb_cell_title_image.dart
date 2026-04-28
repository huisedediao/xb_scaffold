import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitleImage extends XBCellTitle {
  final String? img;
  final Size? imgSize;
  final double? imgRadius;
  const XBCellTitleImage(
      {required super.title,
      this.img,
      this.imgSize,
      this.imgRadius,
      super.titleRightPadding,
      super.titleStyle,
      super.maxTitleWidth,
      super.titleMaxLines,
      super.titleOverflow,
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
