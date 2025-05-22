import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBButtonText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final Color? backgroundColor;
  final Color? disableColor;
  final double? borderRadius;
  final Color? borderColor;
  final double? borderWidth;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final bool? enable;
  final double? width;
  const XBButtonText({
    super.key,
    required this.text,
    this.style,
    this.backgroundColor,
    this.disableColor,
    this.borderRadius,
    this.borderColor,
    this.borderWidth,
    this.padding,
    this.onTap,
    this.enable,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    return XBButton(
      onTap: onTap,
      enable: enable ?? true,
      disableColor: disableColor,
      coverTransparentWhileOpacity: true,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius ?? 5),
          color: backgroundColor ?? Colors.white,
          border: Border.all(
            color: borderColor ?? Colors.grey.shade200,
            width: borderWidth ?? onePixel,
          ),
        ),
        alignment: width == null ? null : Alignment.center,
        child: Padding(
          padding: padding ??
              EdgeInsets.only(
                  left: spaces.gapDef, right: spaces.gapDef, top: 5, bottom: 5),
          child: Text(text,
              style: style ??
                  TextStyle(fontSize: 12, color: Colors.black.withAlpha(150))),
        ),
      ),
    );
  }
}
