import 'package:example/pages/xb_cell_demo.dart';
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
          XBButton(
              onTap: () {
                bool topIsXBCellDemoWidget = vm.isTop;
                toast("topIsXBCellGroupDemo instance:$topIsXBCellDemoWidget");
                xbError(
                    "stackContainType(XBCellDemo):${stackContainType(XBCellDemo)}");
              },
              child: Text("测试点击"))
        ],
        separatorBuilder: (value) {
          return xbLine(startPadding: value * 15);
        },
        backgroundColor: Colors.orange,
        headerBuilder: () {
          return Text("header");
        },
        marginTop: spaces.gapLess,
        marginBottom: spaces.gapLess,
        marginLeft: spaces.gapDef,
        marginRight: spaces.gapDef,
        headerBottomPadding: 10,
      ),
    );
  }
}

class XBCellGroupDemoVM extends XBPageVM<XBCellGroupDemo> {
  XBCellGroupDemoVM({required super.context});
}
