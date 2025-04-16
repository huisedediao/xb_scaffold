import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitleSelect extends XBCellTitle {
  final bool isSelected;
  final Color selectedColor;
  final Color unSelectedColor;
  const XBCellTitleSelect(
      {required super.title,
      required this.isSelected,
      this.selectedColor = Colors.blue,
      this.unSelectedColor = Colors.blue,
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
      super.arrowColor,
      super.isShowArrow = false,
      super.arrowLeftPadding,
      super.arrowSize,
      super.key});

  @override
  Widget rightWidget() {
    return Icon(
        isSelected
            ? Icons.check_circle_outline_rounded
            : Icons.radio_button_unchecked_rounded,
        color: isSelected ? selectedColor : unSelectedColor);
  }
}
