import 'package:example/xb_global_key_test_widget_vm.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBGlobalKeyTestWidget extends XBWidget<XBGlobalKeyTestWidgetVM> {
  const XBGlobalKeyTestWidget({super.key});

  @override
  generateVM(BuildContext context) {
    return XBGlobalKeyTestWidgetVM(context: context);
  }

  @override
  Widget buildWidget(vm, BuildContext context) {
    return Center(
      child: Text(vm.title),
    );
  }
}
