import 'package:example/pages/xb_cell_demo.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:xb_simple_router/xb_simple_router.dart';
import 'package:flutter/material.dart';

class XBCellGroupDemo extends XBPage<XBCellGroupDemoVM> {
  const XBCellGroupDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XBCellGroupDemoVM(context: context);
  }

  @override
  Widget buildPage(BuildContext context) {
    final vm = vmOf(context);
    return XBCellGroup(
      separatorBuilder: (value) {
        return xbLine(startPadding: value * 15);
      },
      backgroundColor: Colors.orange,
      headerBuilder: () {
        return const Text("header");
      },
      marginTop: spaces.gapLess,
      marginBottom: spaces.gapLess,
      marginLeft: spaces.gapDef,
      marginRight: spaces.gapDef,
      headerBottomPadding: 10,
      children: [
        const XBCellTitle(title: "1"),
        const XBCellTitleSelect(title: "2", isSelected: true),
        const XBCellTitleSwitch(title: "3", isOn: true),
        XBButton(
            onTap: () {
              bool topIsXBCellDemoWidget = vm.isTop;
              toast("topIsXBCellGroupDemo instance:$topIsXBCellDemoWidget");
              xbError(
                  "stackContainType(XBCellDemo):${stackContainType(XBCellDemo)}");
            },
            child: const Text("测试点击"))
      ],
    );
  }
}

class XBCellGroupDemoVM extends XBPageVM<XBCellGroupDemo> {
  XBCellGroupDemoVM({required super.context});
}
