import 'package:flutter/material.dart';

class XBShadowContainer extends StatelessWidget {
  final Widget child;
  final Color? shadowColor;
  final double? shadowRadius;

  const XBShadowContainer(
      {required this.child,
      this.shadowColor = Colors.black12,
      this.shadowRadius = 5,
      Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: Colors.transparent, boxShadow: [
        BoxShadow(color: shadowColor!, blurRadius: shadowRadius!)
      ]),
      child: child,
    );
  }
}
