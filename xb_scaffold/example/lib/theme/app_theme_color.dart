import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

extension AppThemeColor on XBThemeColor {
  Color get white => XBThemeVM().themeIndex == 0 ? Colors.white : Colors.black;
  Color get orange =>
      XBThemeVM().themeIndex == 0 ? Colors.orange : Colors.green;
}
