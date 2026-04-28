import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBDisable extends StatelessWidget {
  final Widget child;
  final bool disable;
  final VoidCallback? onTapDisable;

  /// 不可操作时的透明度
  final double disableOpacity;
  const XBDisable(
      {required this.child,
      this.disable = true,
      this.onTapDisable,
      this.disableOpacity = 1,
      super.key});

  @override
  Widget build(BuildContext context) {
    if (disable) {
      return XBButton(
          preventMultiTapMilliseconds: 10,
          onTap: onTapDisable,
          effect: XBButtonTapEffect.none,
          child: Opacity(opacity: disableOpacity, child: child));
    } else {
      return child;
    }
  }
}
