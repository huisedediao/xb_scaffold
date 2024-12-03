import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellTitleSwitch extends XBCell {
  final String title;
  final TextStyle? titleStyle;
  final double? titleRightPadding;
  final double? maxTitleWidth;
  final int? titleMaxLines;
  final TextOverflow? titleOverflow;
  final bool isOn;
  final Color activeColor;
  const XBCellTitleSwitch(
      {required this.title,
      required this.isOn,
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
            value: isOn,
            onChanged: (newValue) {
              onTap?.call();
            })
      ],
    );
  }
}
