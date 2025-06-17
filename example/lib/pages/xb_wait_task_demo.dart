import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBWaitTaskDemo extends XBPage<XBWaitTaskDemoVM> {
  const XBWaitTaskDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XBWaitTaskDemoVM(context: context);
  }

  @override
  Widget buildPage(XBWaitTaskDemoVM vm, BuildContext context) {
    return XBButton(
        onTap: () {
          vm.test();
        },
        child: const Padding(
          padding: EdgeInsets.all(8.0),
          child: Text("测试"),
        ));
  }
}

class XBWaitTaskDemoVM extends XBPageVM<XBWaitTaskDemo> {
  XBWaitTaskDemoVM({required super.context});

  XBWaitTask waitTask = XBWaitTask();

  void test() async {
    final ret = await waitTask.execute(task: task, param: "param");
    xbError(ret);
  }

  Future<String> task(String param) async {
    await Future.delayed(const Duration(seconds: 2));
    return "task";
  }
}
