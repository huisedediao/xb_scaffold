import 'package:example/xb_hovering_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBHoveringTestVM extends XBPageVM<XBHoveringTest> {
  XBHoveringTestVM({required super.context}) {
    showLoading();
    Future.delayed(Duration(seconds: 1), () {
      hideLoading();
      navigatorObserver.showStack();
    });
  }

  final List<int> itemCounts = [5, 5];
}
