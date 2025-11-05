import 'package:example/pages/xb_cell_demo.dart';
import 'package:flutter/material.dart';
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

  @override
  void didPush() {
    // 页面已入栈（可访问 this 和 context）
    super.didPush();
    xbError("didPush");
  }

  @override
  void didPopNext() {
    // 上一个页面出栈，当前页面重新可见
    super.didPopNext();
    xbError("didPopNext");
  }

  /// Called when the current route has been popped off.
  @override
  void didPop() {
    super.didPop();
    xbError("didPop");
  }

  /// Called when a new route has been pushed, and the current route is no
  /// longer visible.
  @override
  void didPushNext() {
    super.didPushNext();
    xbError("didPushNext");
  }
}
