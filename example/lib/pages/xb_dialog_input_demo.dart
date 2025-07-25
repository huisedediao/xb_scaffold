import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBDialogInputDemo extends XBPage<XBDialogInputDemoVM> {
  const XBDialogInputDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XBDialogInputDemoVM(context: context);
  }

  @override
  Widget buildPage(XBDialogInputDemoVM vm, BuildContext context) {
    return Container(
      alignment: Alignment.center,
      child: XBButton(
        child: const Text("show"),
        onTap: () {
          vm.showDialog();
        },
      ),
    );
  }
}

class XBDialogInputDemoVM extends XBPageVM<XBDialogInputDemo> {
  XBDialogInputDemoVM({required super.context});

  void showDialog() {
    dialogWidget(
      XBDialogInput(
        title: "title",
        // subTitle: "subTitle",
        placeholder: "placeholder",
        unit: Padding(
          padding: EdgeInsets.only(left: spaces.gapDef, right: spaces.gapDef),
          child: const Text("unit"),
        ),
        clearLeftWidget: Padding(
          padding: EdgeInsets.only(left: spaces.gapDef),
          child: const Text("unit"),
        ),
        clearRightWidget: Padding(
          padding: EdgeInsets.only(right: spaces.gapDef),
          child: const Text("unit"),
        ),
        onDone: (value) {
          xbLog(value);
        },
      ),
    );
  }
}
