import 'package:flutter/material.dart';

class XBCellArrow extends StatelessWidget {
  final Color? color;
  const XBCellArrow({this.color, super.key});

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.arrow_forward_ios,
      color: color ?? Colors.black54,
      size: 15,
    );
  }
}
