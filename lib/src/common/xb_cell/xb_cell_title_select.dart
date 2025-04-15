import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitleSelect extends XBCell {
  final String title;
  final TextStyle? titleStyle;
  final double? titleRightPadding;
  final double? maxTitleWidth;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  final bool isSelected;
  final Color selectedColor;
  final Color unSelectedColor;
  const XBCellTitleSelect(
      {required this.title,
      required this.isSelected,
      this.titleStyle,
      this.titleRightPadding,
      this.maxTitleWidth,
      this.titleMaxLines,
      this.titleOverflow,
      this.selectedColor = Colors.blue,
      this.unSelectedColor = Colors.blue,
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
      ],
    );
  }

  @override
  Widget rightWidget() {
    return Icon(
        isSelected
            ? Icons.check_circle_outline_rounded
            : Icons.radio_button_unchecked_rounded,
        color: isSelected ? selectedColor : unSelectedColor);
  }
}
