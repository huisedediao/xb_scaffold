import 'package:example/xb_page_test.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBPageTestVM extends XBPageVM<XBPageTest> {
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
  }

  GlobalKey<XBTipState> tipKey = GlobalKey();

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
    super.willDispose();
    print("$runtimeType willDispose");
  }
}
