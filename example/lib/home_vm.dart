import 'package:example/home.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class HomeVM extends XBPageVM<Home> {
  HomeVM({required super.context});

  List<String> get titles => [
        "XBCellTitleSubtitleArrow",
        "XBCellTitleSubtitle",
        "XBCellCenterTitle",
        "XBCellIconTitleArrow",
        "XBCellTitleImageArrow",
        "XBCellTitleSelect",
        "XBCellIconTitleSelect",
        "XBCellTitleSwitch",
        "XBCellIconTitleSwitch",
        "XBCellIconTitleTb",
        "XBCellIconTitleSubtitleArrow",
        "XBCellTitlePointArrow",
        "XBCellTitleSubtitleLeftArrow",
        "XBCellTitleSubtitleLeft",
        "XBMenu 1",
        "XBMenu 2",
        "XBFloatWidget",
        "def"
      ];

  bool isSelected = false;
  onSelectChange() {
    isSelected = !isSelected;
    notify();
  }
}
