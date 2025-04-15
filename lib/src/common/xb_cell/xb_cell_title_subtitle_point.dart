import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitleSubtitlePoint extends XBCellTitleSubtitle {
  final double? pointSize;
  final Color? pointColor;
  final double? pointLeftPadding;
  const XBCellTitleSubtitlePoint(
      {required super.title,
      required super.subtitle,
      this.pointSize,
      this.pointColor,
      this.pointLeftPadding,
      super.titleStyle,
      super.titleRightPadding,
      super.maxTitleWidth,
      super.titleMaxLines,
      super.titleOverflow,
      super.subtitleStyle,
      super.subtitleOverflow,
      super.maxSubtitleWidth,
      super.subtitleMaxLines,
      super.subtitleAlignment,
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

  double get _pointW => pointSize ?? 6;

  @override
  Widget rightWidget() {
    return Padding(
      padding: EdgeInsets.only(left: pointLeftPadding ?? 5),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_pointW * 0.5),
        child: Container(
          width: _pointW,
          height: _pointW,
          color: pointColor ?? Colors.red,
        ),
      ),
    );
  }
}
