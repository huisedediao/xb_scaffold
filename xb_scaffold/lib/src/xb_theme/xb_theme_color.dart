import 'package:flutter/material.dart';
import 'dart:math';

class XBThemeColor {
  XBThemeColor({Color? primaryColor}) {
    primary = primaryColor ?? const Color(0xFF007AFF);
  }

  /// primary color
  late Color primary;

  /// 随机颜色
  Color get randColor => Color.fromARGB(
      255, Random().nextInt(256), Random().nextInt(256), Random().nextInt(256));
}
