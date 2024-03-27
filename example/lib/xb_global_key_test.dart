import 'package:example/xb_global_key_test_vm.dart';
import 'package:example/xb_global_key_test_widget.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBGlobalKeyTest extends XBPage<XBGlobalKeyTestVM> {
  const XBGlobalKeyTest({super.key});

  @override
  generateVM(BuildContext context) {
    return XBGlobalKeyTestVM(context: context);
  }

  @override
  Widget buildPage(vm, BuildContext context) {
    return Column(
      children: [
        XBGlobalKeyTestWidget(key: vm.globalKey),
        XBButton(
          onTap: vm.onChangeTitle,
          child: Container(
            color: Colors.blue,
            child: const Padding(
              padding: EdgeInsets.all(8.0),
              child: Text("change title"),
            ),
          ),
        ),
        const SizedBox(
          height: 10,
        ),
        XBButton(
          onTap: vm.onChangeVM,
          child: Container(
            color: Colors.blue,
            child: const Padding(
              padding: EdgeInsets.all(8.0),
              child: Text("change vm"),
            ),
          ),
        )
      ],
    );
  }
}
