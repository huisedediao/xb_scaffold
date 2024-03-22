import 'package:example/xb_rotate_test_vm.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBRotateTest extends XBPage<XBRotateTestVM> {
  const XBRotateTest({super.key});

  @override
  generateVM(BuildContext context) {
    return XBRotateTestVM(context: context);
  }

  @override
  bool needShowContentFromScreenTop(XBRotateTestVM vm) {
    return vm.orientation == 1;
  }

  @override
  bool needRebuildWhileOrientationChanged() {
    return true;
  }

  @override
  Widget buildPage(vm, BuildContext context) {
    return Container(
      alignment: Alignment.center,
      child: XBButton(
        onTap: vm.onChange,
        child: const Padding(
          padding: EdgeInsets.all(8.0),
          child: Text("旋转测试"),
        ),
      ),
    );
  }
}
