import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
export 'xb_cell_center_title.dart';
export 'xb_cell_title_subtitle_arrow.dart';
export 'xb_cell_title_subtitle.dart';

abstract class XBCell extends StatelessWidget {
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final Color? backgroundColor;
  final double? contentHeight;
  final BorderRadiusGeometry contentBorderRadius;
  const XBCell(
      {this.margin,
      this.padding,
      this.onTap,
      this.backgroundColor,
      this.contentHeight,
      this.contentBorderRadius = BorderRadius.zero,
      super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin ?? const EdgeInsets.all(0),
      child: XBButton(
        onTap: onTap,
        coverTransparentWhileOpacity: true,
        child: ClipRRect(
          borderRadius: contentBorderRadius,
          child: Container(
            color: backgroundColor,
            child: Padding(
              padding: padding ?? const EdgeInsets.all(0),
              child: SizedBox(height: contentHeight, child: buildContent()),
            ),
          ),
        ),
      ),
    );
  }

  Widget buildContent();
}
