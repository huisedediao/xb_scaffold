import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/view/xb_arrow_painter.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBFloatWidgetArrow extends XBFloatWidget {
  final Color? bgColor;
  const XBFloatWidgetArrow(
      {super.key,
      required super.child,
      super.type,
      super.tapContentHide = true,
      this.bgColor});

  Widget buildContentWithoutArrow(
      Offset position, double contentLeft, bool isAbove, Function hide) {
    return Container(
      width: contentWidth,
      height: 100,
      color: Colors.red,
      child: const Text(
        '请重写buildContentWithoutArrow',
        style: TextStyle(color: Colors.white),
      ),
    );
  }

  @override
  Widget buildContent(
      Offset position, double contentLeft, bool isAbove, Function hide) {
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
            buildContentWithoutArrow(position, contentLeft, isAbove, hide),
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
}
