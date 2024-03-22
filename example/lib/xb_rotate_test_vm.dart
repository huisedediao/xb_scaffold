import 'package:example/xb_rotate_test.dart';
import 'package:flutter/services.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBRotateTestVM extends XBPageVM<XBRotateTest> {
  XBRotateTestVM({required super.context});

  int orientation = 0;

  onChange() {
    orientation = orientation == 0 ? 1 : 0;
    if (orientation == 1) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    // notify();
  }
}
