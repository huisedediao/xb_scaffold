import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBCellGroupDemo extends XBPage<XBCellGroupDemoVM> {
  const XBCellGroupDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XBCellGroupDemoVM(context: context);
  }

  @override
  Widget buildPage(XBCellGroupDemoVM vm, BuildContext context) {
    return Container(
      child: XBCellGroup(
        children: [
          XBCellTitle(title: "1"),
          XBCellTitleSelect(title: "2", isSelected: true),
          XBCellTitleSwitch(title: "3", isOn: true),
        ],
        separatorBuilder: (value) {
          return xbLine(startPadding: value * 15);
        },
        backgroundColor: Colors.orange,
      ),
    );
  }
}

class XBCellGroupDemoVM extends XBPageVM<XBCellGroupDemo> {
  XBCellGroupDemoVM({required super.context});
}
