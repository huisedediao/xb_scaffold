import 'package:example/xb_page_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBPageTestVM extends XBPageVM<XBPageTest> {
  XBPageTestVM({required super.context}) {
    Future.delayed(Duration(seconds: 3), () {
      hideLoading();
      showLoading();
    });
  }
}
