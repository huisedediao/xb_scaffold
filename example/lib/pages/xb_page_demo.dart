import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBPageDemo extends XBPage<XBPageDemoVM> {
  const XBPageDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XBPageDemoVM(context: context);
  }

  @override
  Widget? drawer(BuildContext context) {
    final vm = vmOf(context);
    return Container(
      width: 200,
      color: Colors.red,
    );
  }

  @override
  Widget? leading(BuildContext context) {
    final vm = vmOf(context);
    return Container(
      height: 30,
      color: colors.randColor,
    );
  }

  @override
  double? leadingWidth(BuildContext context) {
    final vm = vmOf(context);
    return 100;
  }

  @override
  Widget? endDrawer(BuildContext context) {
    return Container(
      width: 200,
      color: Colors.blue,
    );
  }

  @override
  Widget buildPage(BuildContext context) {
    final vm = vmOf(context);
    return Container(
      alignment: Alignment.center,
      child: Column(
        children: [
          ElevatedButton(
            onPressed: () {
              vm.openDrawer();
            },
            child: const Text('打开左侧菜单'),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () {
              vm.openEndDrawer();
            },
            child: const Text('打开右侧菜单'),
          ),
        ],
      ),
    );
  }
}

class XBPageDemoVM extends XBPageVM<XBPageDemo> {
  XBPageDemoVM({required super.context});
}
