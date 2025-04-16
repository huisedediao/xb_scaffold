import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitleSwitch extends XBCellTitle {
  final bool isOn;
  final Color activeColor;
  const XBCellTitleSwitch(
      {required super.title,
      required this.isOn,
      this.activeColor = Colors.blue,
      super.titleStyle,
      super.titleRightPadding,
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
      super.key});

  @override
  bool get isNeedBtn => false;

  @override
  Widget rightWidget() {
    return CupertinoSwitch(
        activeColor: activeColor,
        value: isOn,
        onChanged: (newValue) {
          onTap?.call();
        });
  }
}
