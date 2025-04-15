import 'package:example/pages/xb_cell_demo_vm.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBCellDemo extends XBPage<XBCellDemoVM> {
  const XBCellDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XBCellDemoVM(context: context);
  }

  @override
  String setTitle(XBCellDemoVM vm) {
    return "XBCellDemo";
  }

  @override
  Widget? leading(XBCellDemoVM vm) {
    return null;
  }

  @override
  Widget buildPage(XBCellDemoVM vm, BuildContext context) {
    return ListView.separated(
      itemCount: vm.titles.length,
      separatorBuilder: (context, index) {
        return Container(
          height: 10,
        );
      },
      itemBuilder: (context, index) {
        String title = vm.titles[index];
        if (index == 0) {
          return XBCellTitleSubtitle(
            contentBorderRadius: BorderRadius.circular(6),
            margin: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            backgroundColor: Colors.green,
            titleStyle: const TextStyle(color: Colors.white),
            subtitleStyle: TextStyle(color: Colors.white.withAlpha(150)),
            contentHeight: 70,
            padding: EdgeInsets.only(
                left: spaces.gapDef, right: spaces.gapDef, top: 10, bottom: 10),
            title: title,
            titleMaxLines: 2,
            titleOverflow: TextOverflow.ellipsis,
            maxTitleWidth: screenW * 0.5,
            subtitle: "subtitle",
            arrowColor: Colors.white,
            onTap: () {},
            isShowArrow: true,
          );
        }
        if (index == 1) {
          return XBTip(
            type: 1,
            tip:
                "提示  提示 XBCellTitleSubtitleXBCellTitleSubtitleXBCellTitleSubtitleXBCellTitleSubtitleXBCellTitleSubtitleXBCellTitleSubtitle",
            child: XBDisable(
              disable: true,
              child: XBCellTitleSubtitle(
                contentBorderRadius: BorderRadius.circular(6),
                margin: EdgeInsets.only(
                  left: spaces.gapDef,
                  right: spaces.gapDef,
                ),
                backgroundColor: Colors.blue,
                titleStyle: const TextStyle(color: Colors.white),
                subtitleStyle: TextStyle(color: Colors.white.withAlpha(150)),
                contentHeight: 70,
                padding: EdgeInsets.only(
                    left: spaces.gapDef,
                    right: spaces.gapDef,
                    top: 10,
                    bottom: 10),
                title: title,
                titleMaxLines: 2,
                titleOverflow: TextOverflow.ellipsis,
                maxTitleWidth: screenW * 0.5,
                subtitle: "subtitle",
                onTap: () {},
              ),
            ),
          );
        }
        if (index == 2) {
          return XBCellCenterTitle(
            contentBorderRadius: BorderRadius.circular(6),
            margin: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            backgroundColor: Colors.red,
            titleStyle: const TextStyle(color: Colors.white),
            contentHeight: 50,
            padding: const EdgeInsets.only(top: 10, bottom: 10),
            title: title,
            onTap: () {
              dialogWidget(XBDialogInput(
                  title: title,
                  onDone: (value) {
                    xbLog(value);
                  }));
            },
          );
        }
        if (index == 3) {
          return XBCellIconTitle(
            contentBorderRadius: BorderRadius.circular(6),
            icon: "assets/images/icon_inspectionPlan.png",
            margin: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            contentHeight: 40,
            padding: EdgeInsets.only(
                left: spaces.gapDef, right: spaces.gapDef, top: 10, bottom: 10),
            title: title,
            titleStyle: const TextStyle(color: Colors.white),
            iconSize: const Size(20, 20),
            backgroundColor: Colors.purple,
            arrowColor: Colors.white,
            isShowArrow: true,
          );
        }
        if (index == 4) {
          return XBCellTitleImage(
            contentBorderRadius: BorderRadius.circular(6),
            img: "assets/images/icon_inspectionPlan.png",
            margin: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            // contentHeight: 40,
            padding: EdgeInsets.only(
                left: spaces.gapDef, right: spaces.gapDef, top: 10, bottom: 10),
            title: title,
            titleStyle: const TextStyle(color: Colors.white),
            imgSize: const Size(30, 30),
            imgRadius: 15,
            backgroundColor: Colors.teal,
            arrowColor: Colors.white,
            arrowLeftPadding: 10,
            isShowArrow: true,
          );
        }
        if (index == 5) {
          return XBCellTitleSelect(
              contentBorderRadius: BorderRadius.circular(6),
              title: title,
              isSelected: vm.isSelected,
              margin: EdgeInsets.only(
                left: spaces.gapDef,
                right: spaces.gapDef,
              ),
              contentHeight: 40,
              padding: EdgeInsets.only(
                  left: spaces.gapDef,
                  right: spaces.gapDef,
                  top: 10,
                  bottom: 10),
              // imageSize: const Size(20, 20),
              backgroundColor: Colors.white,
              selectedColor: Colors.green,
              unSelectedColor: Colors.green,
              onTap: vm.onSelectChange);
        }
        if (index == 6) {
          return XBCellIconTitleSelect(
              icon: "assets/images/icon_inspectionPlan.png",
              contentBorderRadius: BorderRadius.circular(6),
              title: title,
              isSelected: vm.isSelected,
              margin: EdgeInsets.only(
                left: spaces.gapDef,
                right: spaces.gapDef,
              ),
              contentHeight: 40,
              padding: EdgeInsets.only(
                  left: spaces.gapDef,
                  right: spaces.gapDef,
                  top: 10,
                  bottom: 10),
              iconSize: const Size(20, 20),
              backgroundColor: Colors.white,
              selectedColor: Colors.green,
              unSelectedColor: Colors.green,
              onTap: vm.onSelectChange);
        }
        if (index == 7) {
          return XBCellTitleSwitch(
            title: title,
            isOn: vm.isSelected,
            contentBorderRadius: BorderRadius.circular(6),
            margin: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            contentHeight: 40,
            padding: EdgeInsets.only(
                left: spaces.gapDef, right: spaces.gapDef, top: 10, bottom: 10),
            backgroundColor: Colors.white,
            activeColor: Colors.green,
            onTap: vm.onSelectChange,
          );
        }
        if (index == 8) {
          return XBCellIconTitleSwitch(
            title: title,
            isSelected: vm.isSelected,
            contentBorderRadius: BorderRadius.circular(6),
            margin: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            contentHeight: 40,
            padding: EdgeInsets.only(
                left: spaces.gapDef, right: spaces.gapDef, top: 10, bottom: 10),
            backgroundColor: Colors.white,
            activeColor: Colors.green,
            onTap: vm.onSelectChange,
            icon: 'assets/images/icon_inspectionPlan.png',
            iconSize: const Size(20, 20),
          );
        }
        if (index == 9) {
          return Container(
            alignment: Alignment.center,
            child: XBCellIconTitleTb(
              title: title,
              contentBorderRadius: BorderRadius.circular(6),
              margin: EdgeInsets.only(
                left: spaces.gapDef,
                right: spaces.gapDef,
              ),
              padding: EdgeInsets.only(
                  left: spaces.gapDef,
                  right: spaces.gapDef,
                  top: 10,
                  bottom: 10),
              backgroundColor: Colors.white,
              icon: 'assets/images/icon_inspectionPlan.png',
              iconSize: const Size(50, 50),
              gap: 10,
            ),
          );
        }
        if (index == 10) {
          return XBCellIconTitleSubtitlePoint(
            title: title,
            subtitle: "222",
            contentBorderRadius: BorderRadius.circular(6),
            margin: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            contentHeight: 50,
            padding: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            backgroundColor: Colors.white,
            icon: 'assets/images/icon_inspectionPlan.png',
            iconSize: const Size(20, 20),
            pointSize: 10,
            pointColor: Colors.orange,
            isShowArrow: true,
          );
        }
        if (index == 11) {
          return XBCellTitleSubtitlePoint(
            title: title,
            subtitle: "222",
            pointLeftPadding: 20,
            contentBorderRadius: BorderRadius.circular(6),
            margin: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            contentHeight: 50,
            padding: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            backgroundColor: Colors.white,
            pointSize: 10,
            pointColor: Colors.orange,
            isShowArrow: true,
          );
        }
        if (index == 12) {
          return XBCellTitleSubtitleLeft(
            title: title,
            contentBorderRadius: BorderRadius.circular(6),
            margin: EdgeInsets.only(left: spaces.gapDef, right: spaces.gapDef),
            padding: EdgeInsets.only(
                left: spaces.gapDef, right: spaces.gapDef, top: 10, bottom: 10),
            backgroundColor: Colors.white,
            subtitle: 'subtitle',
            maxTitleWidth: 100,
            isShowArrow: true,
          );
        }
        if (index == 13) {
          return XBCellTitleSubtitleLeft(
            contentBorderRadius: BorderRadius.circular(6),
            margin: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            backgroundColor: Colors.blue,
            titleStyle: const TextStyle(color: Colors.white),
            subtitleStyle: TextStyle(color: Colors.white.withAlpha(150)),
            contentHeight: 70,
            padding: EdgeInsets.only(
                left: spaces.gapDef, right: spaces.gapDef, top: 10, bottom: 10),
            title: title,
            titleMaxLines: 2,
            titleOverflow: TextOverflow.ellipsis,
            // maxTitleWidth: screenW * 0.5,
            subtitle: "subtitle",
            onTap: () {},
          );
        }

        if (index == 14) {
          return Row(
            children: [
              const Spacer(),
              XBFloatMenuTitle(
                items: const [
                  "Average stay duration",
                  "222222",
                  "333333",
                  "444444",
                  "555555",
                  "666666"
                ],
                type: 1,
                onTapItem: (value) {
                  xbLog(value);
                },
                child: Container(
                  width: 40,
                  height: 40,
                  color: colors.randColor,
                  alignment: Alignment.center,
                  child: Container(
                    width: 1,
                    height: 40,
                    color: Colors.red,
                  ),
                ),
              ),
            ],
          );
        }

        if (index == 15) {
          return Row(
            children: [
              XBFloatMenuTitle(
                // bgColor: Colors.white,
                // textStyle: const TextStyle(color: Colors.black),
                // textOverflow: TextOverflow.ellipsis,
                // separatorColor: Colors.red,
                items: vm.textItems,
                onTapItem: (value) {
                  xbLog(value);
                },
                child: Container(
                  width: 40,
                  height: 40,
                  color: colors.randColor,
                  alignment: Alignment.center,
                  child: Container(
                    width: 1,
                    height: 40,
                    color: Colors.red,
                  ),
                ),
              ),
              const Spacer(),
            ],
          );
        }

        if (index == 16) {
          return Row(
            children: [
              XBFloatWidget(
                type: 1,
                child: Container(
                  width: 40,
                  height: 40,
                  color: colors.randColor,
                  alignment: Alignment.center,
                  child: Container(
                    width: 1,
                    height: 40,
                    color: Colors.red,
                  ),
                ),
              ),
              const Spacer(),
            ],
          );
        }

        if (index == 17) {
          return Row(
            children: [
              XBTip(
                tipStyle: const TextStyle(color: Colors.orange),
                // type: 1,
                tip: "提示提示提示提示提示提示提示提示提示提示提示提示提示提示提示",
                child: Container(
                  width: 40,
                  height: 40,
                  color: colors.randColor,
                  alignment: Alignment.center,
                  child: Container(
                    width: 1,
                    height: 40,
                    color: Colors.red,
                  ),
                ),
              ),
              const Spacer(),
              // SizedBox(
              //   width: 80,
              // )
            ],
          );
        }

        if (index == 18) {
          return Container(
            width: 200,
            alignment: Alignment.center,
            color: colors.randColor,
            child: Container(
              width: 200,
              height: 50,
              color: colors.randColor,
              child: XBCellIconTitle(
                title: title,
                icon: 'assets/images/icon_inspectionPlan.png',
                iconSize: const Size(20, 20),
              ),
            ),
          );
        }

        if (index == 19) {
          return Row(
            children: [
              XBFloatMenuIconTitle(
                bgColor: Colors.white,
                titleStyle: const TextStyle(color: Colors.black),
                titleOverflow: TextOverflow.ellipsis,
                contentHeight: 60,
                separatorColor: Colors.red,
                gap: 20,
                iconSize: const Size(20, 20),
                items: vm.iconItems,
                onTapItem: (value) {
                  xbLog(value);
                },
                // type: 1,
                paddingLeft: 15,
                width: 160,
                child: Container(
                  width: 40,
                  height: 40,
                  color: colors.randColor,
                  alignment: Alignment.center,
                  child: Container(
                    width: 1,
                    height: 40,
                    color: Colors.red,
                  ),
                ),
              ),
              const Spacer(),
            ],
          );
        }

        if (index == 20) {
          return XBCellTitle(
            contentBorderRadius: BorderRadius.circular(6),
            margin: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            backgroundColor: Colors.green,
            titleStyle: const TextStyle(color: Colors.white),
            contentHeight: 70,
            padding: EdgeInsets.only(
                left: spaces.gapDef, right: spaces.gapDef, top: 10, bottom: 10),
            title: title + "title" + title + "title" + title + "title" + title,
            titleMaxLines: 2,
            titleOverflow: TextOverflow.ellipsis,
            arrowColor: Colors.white,
            onTap: () {},
            isShowArrow: true,
          );
        }

        return Container(
          color: colors.randColor,
          height: 200,
        );
      },
    );
  }
}
