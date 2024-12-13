import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBTip extends XBFloatWidgetArrow {
  final String tip;
  final TextStyle? tipStyle;
  final double paddingH;
  final double maxWidth;
  const XBTip({
    super.key,
    required super.child,
    required this.tip,
    super.type,
    super.tapContentHide = true,
    this.tipStyle,
    super.bgColor,
    this.paddingH = 10,
    this.maxWidth = 280,
  });

  @override
  double get contentWidth => textSize().width + paddingH * 2;

  @override
  Widget buildContentWithoutArrow(
      Offset position, double contentLeft, bool isAbove, Function hide) {
    double circular = 5;
    return ClipRRect(
      borderRadius: BorderRadius.only(
          topLeft: Radius.circular(circular),
          topRight: Radius.circular(circular),
          bottomLeft: Radius.circular(circular),
          bottomRight: Radius.circular(circular)),
      child: Container(
        color: bgColor ?? Colors.black,
        constraints: BoxConstraints(maxWidth: contentWidth),
        alignment: Alignment.center,
        child: Padding(
          padding: EdgeInsets.only(
              left: paddingH - onePixel,
              right: paddingH - onePixel,
              top: 5,
              bottom: 5),
          child: Text(
            tip,
            style: _tipsStyle,
          ),
        ),
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
