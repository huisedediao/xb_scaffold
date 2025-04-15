import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellIconTitleSubtitlePoint extends XBCellTitleSubtitlePoint {
  final String icon;
  final Size? iconSize;
  final double? iconRightPadding;
  const XBCellIconTitleSubtitlePoint({
    required this.icon,
    this.iconSize,
    this.iconRightPadding,
    required super.title,
    required super.subtitle,
    super.titleStyle,
    super.subtitleStyle,
    super.pointSize,
    super.pointColor,
    super.pointLeftPadding,
    super.contentHeight,
    super.margin,
    super.padding,
    super.onTap,
    super.contentBorderRadius,
    super.backgroundColor,
    super.isShowArrow,
    super.arrowColor,
    super.arrowLeftPadding,
    super.key,
  });

  @override
  Widget leftWidget() {
    return Padding(
      padding: EdgeInsets.only(right: iconRightPadding ?? spaces.gapLess),
      child: SizedBox(
        width: iconSize?.width ?? 15,
        height: iconSize?.height ?? 15,
        child: XBImage(
          icon,
        ),
      ),
    );
  }
}
