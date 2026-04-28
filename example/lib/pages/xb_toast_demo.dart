import 'package:example/pages/xb_toast_demo_vm.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBToastDemo extends XBPage<XBToastDemoVM> {
  const XBToastDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XBToastDemoVM(context: context);
  }

  @override
  Widget buildPage(BuildContext context) {
    final vm = vmOf(context);
    return Column(
      children: [
        XBButton(
            onTap: () {
              toast("msg");
            },
            child: const Text("toast")),
        XBButton(
            onTap: () {
              toastWidget(
                  widget: Container(
                color: Colors.green,
                child: const Text("success"),
              ));
            },
            child: const Text("toast success"))
      ],
    );
  }
}
