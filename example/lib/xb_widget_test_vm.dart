import 'package:example/xb_widget_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBWidgetTestVM extends XBVM<XBWidgetTest> {
  XBWidgetTestVM({required super.context});

  /// 这里只改变图片路径
  changeTheme() {
    if (XBThemeVM().themeIndex == 0) {
      XBThemeVM().changeTheme(1);
    } else {
      XBThemeVM().changeTheme(0);
    }
    notify();
  }
}
