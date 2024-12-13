import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBFloatTip extends XBFloatWidget {
  final String tip;
  final TextStyle? tipStyle;
  final Color? bgColor;
  final double maxWidth;
  final double paddingH;
  const XBFloatTip({
    super.key,
    required super.child,
    required super.contentWidth,
    required this.tip,
    this.tipStyle,
    this.bgColor,
    this.maxWidth = 280,
    this.paddingH = 10,
  });

  @override
  Widget buildContent(
      Offset position, double contentLeft, double contentWidth, bool isAbove) {
    double circular = 5;
    return Container(
      color: colors.randColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.only(
                topLeft: Radius.circular(circular),
                topRight: Radius.circular(circular),
                bottomLeft: Radius.circular(circular),
                bottomRight: Radius.circular(circular)),
            child: Container(
              color: bgColor ?? Colors.black,
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Padding(
                padding: EdgeInsets.only(
                    left: paddingH, right: paddingH, top: 5, bottom: 5),
                child: Text(
                  tip,
                  style: _tipsStyle,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  TextStyle get _tipsStyle =>
      tipStyle ?? const TextStyle(color: Colors.white, fontSize: 12);

  Size textSize() {
    final TextPainter textPainter = TextPainter(
      text: TextSpan(text: tip, style: _tipsStyle),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth - paddingH * 2);

    final double height = textPainter.height;
    final double width = textPainter.width;
    return Size(width, height);
  }
}
