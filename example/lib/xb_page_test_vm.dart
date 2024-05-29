import 'dart:async';

import 'package:example/xb_page_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBPageTestVM extends XBPageVM<XBPageTest> {
  late StreamSubscription _subscription;
  XBPageTestVM({required super.context}) {
    // showLoading();
    // toast("msg");
    // dialog(
    //     title: "title", msg: "msg", btnTitles: ["1"], onSelected: (index) {});
    // showLoadingGlobal();
    // Future.delayed(const Duration(seconds: 3), () {
    //   hideLoading();
    // });
    // showLoadingGlobal(contentEnable: true);
    // hideLoadingGlobal();
    Future.delayed(Duration(milliseconds: 30), () {
      // showLoadingGlobal();
      // hideLoadingGlobal();
      // hideLoadingGlobal();
    });

    showPageLog();

    _subscription = XBEventBus.on<String>().listen((event) {
      print("listen: $event");
    });

    XBEventBus.addListener<String>(this, (p0) => print("addListener 0: $p0"));
    XBEventBus.addListener<int>(this, (p0) => print("addListener 1: $p0"));

    listen<double>((data) {
      xbError("listen double:$data");
    });
  }

  @override
  void back<O extends Object?>([O? result]) {
    hideLoadingGlobal();
    super.back(result);
  }

  @override
  willHide() {
    super.willHide();
    print("$runtimeType willHide");
  }

  @override
  willShow() {
    super.willShow();
    print("$runtimeType willShow");
  }

  @override
  void willDispose() {
    _subscription.cancel();
    super.willDispose();
    print("$runtimeType willDispose");
  }
}
