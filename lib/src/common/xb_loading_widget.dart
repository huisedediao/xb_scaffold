import 'dart:math';

import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBLoadingWidget extends XBVMLessWidget {
  const XBLoadingWidget({super.key});

  final double w = 70;

  @override
  Widget buildWidget(XBVM vm, BuildContext context) {
    return Container(
        alignment: Alignment.center,
        child: XBShadowContainer(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: w,
              width: w,
              color: Colors.white,
              alignment: Alignment.center,
              child: XBAnimationRotate(
                repeat: true,
                duration: const Duration(milliseconds: 1000),
                child:
                    CustomPaint(size: Size(w, w), painter: XBLoadingPainter()),
              ),
            ),
          ),
        ));
  }
}

class XBLoadingPainter extends CustomPainter {
  final Color? color;

  XBLoadingPainter({this.color});

  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 3;

    _paint.color = color ?? Colors.black.withAlpha(100);
    _paint.style = PaintingStyle.stroke;
    _paint.strokeWidth = 2.0;
    for (var i = 0; i < 360; i += 40) {
      final midPoint = Offset(center.dx + (radius * cos(i * pi / 180) / 1.4),
          center.dy + (radius * sin(i * pi / 180) / 1.4));

      _paint.style = PaintingStyle.fill;
      canvas.drawCircle(midPoint, (1 + (i * 1.0 / 60) * 0.4) * 1, _paint);
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
