import 'package:example/xb_global_key_test_widget.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBGlobalKeyTestWidgetVM extends XBVM<XBGlobalKeyTestWidget> {
  XBGlobalKeyTestWidgetVM({required super.context});

  String _title = "1";
  String get title => _title;

  changeTitle() {
    _title = "2";
    notify();
  }
}
