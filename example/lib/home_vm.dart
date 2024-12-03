import 'package:example/home.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class HomeVM extends XBPageVM<Home> {
  HomeVM({required super.context});

  List<String> get titles => ["XBTitleSubtitleCell", "XBCenterTitleCell"];
}
