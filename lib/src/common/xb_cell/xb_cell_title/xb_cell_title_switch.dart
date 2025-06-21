import 'package:flutter/cupertino.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitleSwitch extends XBCellTitle {
  final bool isOn;
  final Color? activeColor;
  const XBCellTitleSwitch(
      {required super.title,
      required this.isOn,
      this.activeColor,
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
      super.isNeedBtn = false,
      super.key});

  @override
  Widget rightWidget() {
    return CupertinoSwitch(
        activeColor: activeColor ?? colors.primary,
        value: isOn,
        onChanged: (newValue) {
          onTap?.call();
        });
  }
}
