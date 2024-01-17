import 'package:example/xb_page_test.dart';
import 'package:flutter/src/widgets/framework.dart';
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

  @override
  Widget? back<O extends Object?>([O? result]) {
    hideLoadingGlobal();
    return super.back(result);
  }
}
