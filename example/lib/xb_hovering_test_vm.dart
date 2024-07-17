import 'package:example/xb_hovering_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBHoveringTestVM extends XBPageVM<XBHoveringTest> {
  XBHoveringTestVM({required super.context}) {
    showLoading();
    Future.delayed(Duration(seconds: 1), () {
      hideLoading();
      xbRouteObserver.showStack();
    });

    testTask();
  }

  testTask() async {
    xbError("开始执行");
    final ret =
        await waitTask.execute<int>(task: test, param: 1, milliseconds: 2000);
    if (ret) {
      print("执行成功");
    } else {
      print("执行超时");
    }
  }

  Future test(int param) async {
    return await Future.delayed(Duration(seconds: param), () {
      xbError("test 执行完成");
    });
  }

  XBWaitTask waitTask = XBWaitTask();

  final List<int> itemCounts = [5, 5];
}
