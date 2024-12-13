import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

typedef XBFloatMenuItemBuilder = Widget Function(int index, Function hide);

class XBFloatMenu extends XBFloatWidgetArrow {
  final int itemCount;
  final XBFloatMenuItemBuilder itemBuilder;
  final Widget Function(int index) separatorBuilder;
  final double width;
  final CrossAxisAlignment crossAxisAlignment;
  const XBFloatMenu({
    super.key,
    required super.child,
    required this.itemCount,
    required this.itemBuilder,
    required this.separatorBuilder,
    required this.width,
    super.tapContentHide = true,
    super.bgColor,
    super.type,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  @override
  double get contentWidth => width;

  @override
  Widget buildContentWithoutArrow(
      Offset position, double contentLeft, bool isAbove, Function hide) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: width,
        color: bgColor ?? Colors.black,
        child: Column(
          crossAxisAlignment: crossAxisAlignment,
          children: [
            for (int i = 0; i < itemCount; i++)
              Column(
                crossAxisAlignment: crossAxisAlignment,
                children: [
                  itemBuilder(i, hide),
                  if (i < itemCount - 1) separatorBuilder(i),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
