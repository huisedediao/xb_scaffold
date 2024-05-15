import 'package:xb_scaffold/xb_scaffold.dart';

import 'xb_network_test.dart';

class XBNetwrokTestVM extends XBPageVM<XBNetwrokTest> {
  XBNetwrokTestVM({required super.context});

  @override
  void didCreated() {
    super.didCreated();

    XBHttp.request("https://www.baidu.com").then((value) {}).catchError((e) {});
  }
}
