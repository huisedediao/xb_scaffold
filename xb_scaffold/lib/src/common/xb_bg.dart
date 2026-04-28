import 'package:flutter/material.dart';

class XBBG extends StatelessWidget {
  final Widget child;
  final Color? color;
  final double paddingH;
  final double paddingV;
  final BorderRadiusGeometry? borderRadius;
  final double defAllRadius;
  final double? borderWidth;
  final Color? borderColor;

  const XBBG(
      {required this.child,
      this.color = Colors.white,
      this.paddingH = 5,
      this.paddingV = 1,
      this.borderRadius,
      this.defAllRadius = 3,
      this.borderWidth,
      this.borderColor,
      super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: color,
          border: Border.all(
              color: borderColor ?? Colors.transparent,
              width: borderWidth ?? 0),
          borderRadius: borderRadius ?? BorderRadius.circular(defAllRadius)),
      child: Padding(
        padding: EdgeInsets.only(
            left: paddingH, right: paddingH, top: paddingV, bottom: paddingV),
        child: child,
      ),
    );
  }
}
