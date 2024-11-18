import 'package:flutter/cupertino.dart';
import 'package:xb_scaffold/src/configs/xb_color_config.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// 0 横向 1 纵向
Widget xbLine(
    {double? width,
    Color? color,
    int direction = 0,
    double startPadding = 0,
    double endPadding = 0}) {
  EdgeInsetsGeometry padding;
  if (direction == 0) {
    padding = EdgeInsets.only(left: startPadding, right: endPadding);
  } else {
    padding = EdgeInsets.only(top: startPadding, bottom: endPadding);
  }
  return Padding(
    padding: padding,
    child: Container(
      height: direction == 0 ? (width ?? onePixel) : double.infinity,
      width: direction == 1 ? (width ?? onePixel) : double.infinity,
      color: color ?? lineColor,
    ),
  );
}

Widget xbSpace({double? height, double? width}) {
  if (height != null) {
    return SizedBox(height: height);
  }
  if (width != null) {
    return SizedBox(width: width);
  }
  return const SizedBox();
}

Widget xbSpaceHeight(double height) => xbSpace(height: height);
Widget xbSpaceWidth(double width) => xbSpace(width: width);

class XBBottomLine extends StatelessWidget {
  final Widget child;
  final bool isShow;
  final double? lineWidth;
  final Color? lineColor;
  const XBBottomLine(
      {required this.child,
      this.isShow = true,
      this.lineWidth,
      this.lineColor,
      super.key});

  @override
  Widget build(BuildContext context) {
    if (!isShow) return child;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [child, xbLine(width: lineWidth, color: lineColor)],
    );
  }
}
