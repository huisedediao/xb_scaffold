import 'package:example/xb_global_key_test.dart';
import 'package:example/xb_global_key_test_widget_vm.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBGlobalKeyTestVM extends XBPageVM<XBGlobalKeyTest> {
  XBGlobalKeyTestVM({required super.context});

  final GlobalKey<XBWidgetState> _globalKey = GlobalKey();
  GlobalKey get globalKey => _globalKey;

  onTap() {
    final currentState = globalKey.currentState as XBWidgetState;
    (currentState.vm as XBGlobalKeyTestWidgetVM).changeTitle();
  }
}
