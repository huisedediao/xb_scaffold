import 'package:example/pages/xb_cell_demo.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellDemoVM extends XBPageVM<XBCellDemo> {
  XBCellDemoVM({required super.context});

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
        "XBFloatTip",
        "XBCellIconTitle",
        "XBFloatMenuIconTitle",
        "def"
      ];

  bool isSelected = false;
  onSelectChange() {
    isSelected = !isSelected;
    notify();
  }

  List<String> get textItems => [
        "item1",
        "item2",
        "item3",
      ];

  List<XBFloatMenuIconTitleItem> get iconItems => [
        XBFloatMenuIconTitleItem(
            "item1", "assets/images/icon_inspectionPlan.png"),
        XBFloatMenuIconTitleItem(
            "item2222222", "assets/images/icon_inspectionPlan.png"),
        XBFloatMenuIconTitleItem(
            "item3222", "assets/images/icon_inspectionPlan.png"),
      ];
}
