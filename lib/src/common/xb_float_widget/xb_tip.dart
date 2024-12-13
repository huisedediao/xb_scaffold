import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/view/xb_arrow_painter.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBTip extends XBFloatWidget {
  final String tip;
  final TextStyle? tipStyle;
  final Color? bgColor;
  final double paddingH;
  final double maxWidth;
  const XBTip({
    super.key,
    required super.child,
    required this.tip,
    super.type,
    super.tapContentHide = true,
    this.tipStyle,
    this.bgColor,
    this.paddingH = 10,
    this.maxWidth = 280,
  });

  @override
  double get contentWidth => textSize().width + paddingH * 2;

  @override
  Widget buildContent(Offset position, double contentLeft, bool isAbove) {
    double tempContentLeft = position.dx - contentWidth / 2;
    double arrowOffset = 0;
    if (tempContentLeft < minGapToBorder) {
      arrowOffset = -(minGapToBorder - tempContentLeft);
    } else if (tempContentLeft + contentWidth > screenW - minGapToBorder) {
      arrowOffset = tempContentLeft + contentWidth - screenW + minGapToBorder;
    }
    double arrowWidth = 10;
    double arrowHeight = 5;
    double arrowStart = contentWidth * 0.5 - arrowWidth * 0.5 + arrowOffset;

    double circular = 5;
    return Stack(
      children: [
        type == 0
            ? Positioned(
                top: 1,
                child: arrow(position, arrowHeight, arrowStart, arrowWidth),
              )
            : const SizedBox(),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            type == 0
                ? SizedBox(
                    height: arrowHeight,
                  )
                : const SizedBox(),
            ClipRRect(
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
            ),
            type == 1
                ? SizedBox(
                    height: arrowHeight,
                  )
                : const SizedBox(),
          ],
        ),
        type == 1
            ? Positioned(
                bottom: 1,
                child: arrow(position, arrowHeight, arrowStart, arrowWidth),
              )
            : const SizedBox(),
      ],
    );
  }

  Widget arrow(
    Offset position,
    double arrowHeight,
    double arrowStart,
    double arrowWidth,
  ) {
    return Padding(
      padding: EdgeInsets.only(left: arrowStart),
      child: Container(
        // color: colors.randColor,
        alignment: Alignment.centerLeft,
        width: arrowWidth,
        height: arrowHeight,
        child: CustomPaint(
          size: Size(arrowWidth, arrowHeight),
          painter: XBArrowPainter(color: bgColor ?? Colors.black, type: type),
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
