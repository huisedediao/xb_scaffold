import 'package:example/xb_hovering_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBHoveringTestVM extends XBPageVM<XBHoveringTest> {
  XBHoveringTestVM({required super.context}) {
    showLoading();
    Future.delayed(const Duration(seconds: 1), () {
      hideLoading();
      xbRouteObserver.showStack();
    });

    testTask();
  }

  testTask() async {
    final ret =
        await waitTask.execute(task: test, param: 1.0, milliseconds: 2000);
    if (ret == XBWaitTask.paramErr) {
      xbError("参数错误1");
    } else if (ret == XBWaitTask.timeout) {
      xbError("执行超时1");
    } else {
      xbError("执行成功1");
    }

    final ret2 =
        await waitTask.execute(task: test2, param: null, milliseconds: 2000);
    if (ret2 == XBWaitTask.paramErr) {
      xbError("参数错误2");
    } else if (ret2 == XBWaitTask.timeout) {
      xbError("执行超时2");
    } else {
      xbError("执行成功2");
    }
  }

  Future test(double param) async {
    try {
      return await Future.delayed(Duration(seconds: param.toInt()), () {
        xbError("test 执行完成");
      });
    } catch (e) {
      xbError(e);
    }
  }

  Future test2() async {
    return await Future.delayed(const Duration(seconds: 3), () {
      xbError("test2 执行完成");
    });
  }

  XBWaitTask waitTask = XBWaitTask();

  final List<int> itemCounts = [5, 5];
}
