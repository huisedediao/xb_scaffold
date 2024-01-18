import 'package:flutter/material.dart';

class XBHoveringHeader extends StatelessWidget {
  final Widget? child;
  final double offset;
  final bool visible;
  final double? width;

  const XBHoveringHeader(
      {super.key,
      this.child,
      this.offset = 0,
      this.visible = true,
      this.width});

  @override
  Widget build(BuildContext context) {
    return Visibility(
      visible: visible,
      child: Stack(
        children: <Widget>[
          Positioned(
            top: offset,
            child: Container(
              width: width ?? MediaQuery.of(context).size.width,
              alignment: Alignment.centerLeft,
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}
