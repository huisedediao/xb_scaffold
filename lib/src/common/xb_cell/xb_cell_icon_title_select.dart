import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellIconTitleSelect extends XBCell {
  final String icon;
  final Size? iconSize;
  final double? iconRightPadding;
  final String title;
  final TextStyle? titleStyle;
  final double? titleRightPadding;
  final double? maxTitleWidth;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  final bool isSelected;
  final Color selectedColor;
  final Color unSelectedColor;
  const XBCellIconTitleSelect(
      {required this.icon,
      this.iconSize,
      this.iconRightPadding,
      required this.title,
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
      super.arrowColor,
      super.isShowArrow = false,
      super.arrowLeftPadding,
      super.arrowSize,
      super.key});

  @override
  Widget buildContent() {
    return Row(
      children: [
        SizedBox(
          width: iconSize?.width ?? 15,
          height: iconSize?.height ?? 15,
          child: XBImage(
            icon,
          ),
        ),
        SizedBox(width: iconRightPadding ?? spaces.gapLess),
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
