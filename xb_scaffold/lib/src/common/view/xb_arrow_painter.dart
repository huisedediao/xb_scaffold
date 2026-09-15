import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/xb_float_widget/xb_float_position.dart';

class XBArrowPainter extends CustomPainter {
  Color color;
  XBFloatPosition type;
  XBArrowPainter({required this.color, required this.type});

  @override
  void paint(Canvas canvas, Size size) {
    Paint paint_0 = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..strokeWidth = 1.0;

    Path path_0 = Path();
    if (type == XBFloatPosition.below) {
      // below 时，保持当前样式
      path_0.moveTo(size.width * 0.50, 0);
      path_0.lineTo(size.width * 1.00, size.height);
      path_0.lineTo(0, size.height);
      path_0.lineTo(size.width * 0.50, 0);
    } else {
      // above 时，箭头方向上下翻转
      path_0.moveTo(size.width * 0.50, size.height);
      path_0.lineTo(size.width * 1.00, 0);
      path_0.lineTo(0, 0);
      path_0.lineTo(size.width * 0.50, size.height);
    }
    path_0.close();

    canvas.drawPath(path_0, paint_0);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}
