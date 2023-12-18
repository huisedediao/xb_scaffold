import 'package:flutter/material.dart';
import 'dart:math';

class XBThemeColor {
  Color get randColor => Color.fromARGB(
      255, Random().nextInt(256), Random().nextInt(256), Random().nextInt(256));
}
