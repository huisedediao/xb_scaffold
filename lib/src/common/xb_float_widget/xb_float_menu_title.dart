import 'dart:math';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBFloatMenuTitle extends StatelessWidget {
  final Widget child;
  final List<String> items;
  final ValueChanged<int> onTapItem;
  final Color? bgColor;
  final double maxWidth;
  final double minWidth;
  final double paddingH;
  final double paddingV;
  final TextStyle? textStyle;
  final TextOverflow? textOverflow;
  final Color? separatorColor;
  final int type;
  const XBFloatMenuTitle(
      {super.key,
      required this.child,
      required this.items,
      required this.onTapItem,
      this.bgColor,
      this.maxWidth = 280,
      this.minWidth = 80,
      this.paddingH = 10,
      this.paddingV = 10,
      this.textStyle,
      this.textOverflow,
      this.separatorColor,
      this.type = 0});

  double get _width {
    double width = 0;
    for (var item in items) {
      double tempWidth = _textSize(item).width;
      if (tempWidth > width) {
        width = tempWidth;
      }
    }
    return max(width + paddingH * 2 + 4, minWidth);
  }

  @override
  Widget build(BuildContext context) {
    return XBFloatMenu(
      bgColor: bgColor,
      width: _width,
      type: type,
      itemCount: items.length,
      itemBuilder: (index, hide) {
        return XBCellCenterTitle(
          onTap: () {
            hide();
            onTapItem(index);
          },
          padding: EdgeInsets.only(top: paddingV, bottom: paddingV),
          title: items[index],
          titleStyle: _textStyle,
          titleOverflow: textOverflow,
        );
      },
      separatorBuilder: (index) {
        return xbLine(
            color: separatorColor ?? Colors.white24,
            startPadding: 5,
            endPadding: 5);
      },
      child: child,
    );
  }

  TextStyle get _textStyle => textStyle ?? const TextStyle(color: Colors.white);

  Size _textSize(String text) {
    final TextPainter textPainter = TextPainter(
      text: TextSpan(text: text, style: _textStyle),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth - paddingH * 2);

    final double height = textPainter.height;
    final double width = textPainter.width;
    return Size(width, height);
  }
}
