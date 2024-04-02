import 'package:example/xb_global_key_test.dart';
import 'package:example/xb_global_key_test_widget_vm.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBGlobalKeyTestVM extends XBPageVM<XBGlobalKeyTest> {
  XBGlobalKeyTestVM({required super.context});

  final GlobalKey<XBWidgetState> _globalKey = GlobalKey();
  GlobalKey get globalKey => _globalKey;

  onGetState() {
    print("state:$state,state.hashCode:${state.hashCode}");
    state.reset();
  }

  onChangeTitle() {
    final currentState = globalKey.currentState as XBWidgetState;
    (currentState.vm as XBGlobalKeyTestWidgetVM).changeTitle();
  }

  onChangeVM() {
    final currentState = globalKey.currentState as XBWidgetState;
    currentState.reset();
  }

  @override
  didCreate() {
    super.didCreate();
    print("$runtimeType didCreate");
  }

  @override
  willHide() {
    super.willHide();
    print("$runtimeType willHide");
  }

  @override
  willShow() {
    super.willShow();
    print("$runtimeType willShow");
  }

  @override
  void willDispose() {
    super.willDispose();
    print("$runtimeType willDispose");
  }

  @override
  void dispose() {
    super.dispose();
    print("$runtimeType dispose");
  }
}
