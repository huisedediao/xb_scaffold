import 'package:flutter/material.dart';

class XBGradientWidget extends StatelessWidget {
  final AlignmentGeometry begin;
  final AlignmentGeometry end;
  final Color beginColor;
  final Color endColor;
  final Widget child;
  const XBGradientWidget(
      {required this.begin,
      required this.end,
      required this.beginColor,
      required this.endColor,
      required this.child,
      super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: begin,
          end: end,
          colors: [beginColor, endColor],
          stops: const [0.0, 1.0],
        ),
      ),
      child: child,
    );
  }
}
