import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellIconTitleSwitch extends XBCell {
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
  final Color activeColor;
  const XBCellIconTitleSwitch(
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
      this.activeColor = Colors.blue,
      super.contentHeight,
      super.margin,
      super.padding,
      super.onTap,
      super.contentBorderRadius,
      super.backgroundColor,
      super.key});

  @override
  bool get isNeedBtn => false;

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
        const Spacer(),
        CupertinoSwitch(
            activeColor: activeColor,
            value: isSelected,
            onChanged: (newValue) {
              onTap?.call();
            })
      ],
    );
  }
}
