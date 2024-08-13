import 'package:flutter/material.dart';
import '../../../xb_scaffold.dart';

class XBRefreshTaskDemo extends XBPage<XBRefreshTaskDemoVM> {
  const XBRefreshTaskDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XBRefreshTaskDemoVM(context: context);
  }

  @override
  Widget buildPage(vm, BuildContext context) {
    return Center(
      child: XBButton(
          onTap: () {
            vm._util.refresh(XBTask(
                params: "task${vm.taskIndex}",
                execute: (param) {
                  debugPrint("执行任务：$param");
                }));
          },
          child: Container(
              color: colors.randColor,
              child: const Padding(
                padding: EdgeInsets.all(8.0),
                child: Text("添加任务"),
              ))),
    );
  }
}

class XBRefreshTaskDemoVM extends XBPageVM<XBRefreshTaskDemo> {
  XBRefreshTaskDemoVM({required super.context});

  int _taskIndex = 0;

  int get taskIndex {
    int ret = _taskIndex;
    _taskIndex++;
    return ret;
  }

  final XBRefreshTasKUtil _util =
      XBRefreshTasKUtil(duration: const Duration(seconds: 1));

  addTask(XBTask task) {
    _util.refresh(task);
  }

  @override
  void dispose() {
    _util.dispose();
    super.dispose();
  }
}
