import 'package:flutter/material.dart';

class XBMaxHeightContainer extends StatelessWidget {
  final double maxHeight;
  final List<Widget> children;

  const XBMaxHeightContainer({
    required this.maxHeight,
    required this.children,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: maxHeight,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}
