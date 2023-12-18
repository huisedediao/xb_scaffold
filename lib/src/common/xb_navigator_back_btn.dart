import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/xb_stateless_widget.dart';
import 'xb_button.dart';

class XBNavigatorBackBtn extends XBStatelessWidget {
  final VoidCallback onTap;
  final String? img;

  const XBNavigatorBackBtn({required this.onTap, this.img, Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return XBButton(
        onTap: onTap,
        child: Container(
          color: Colors.transparent,
          alignment: Alignment.center,
          child: const Icon(Icons.arrow_back),
        ));
  }
}
