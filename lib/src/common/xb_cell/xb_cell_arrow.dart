import 'package:flutter/material.dart';

class XBCellArrow extends StatelessWidget {
  final Color? color;
  final double? size;
  const XBCellArrow({this.color, this.size, super.key});

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.arrow_forward_ios,
      color: color ?? Colors.black54,
      size: size ?? 15,
    );
  }
}
