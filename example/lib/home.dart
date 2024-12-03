import 'package:example/home_vm.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class Home extends XBPage<HomeVM> {
  const Home({super.key});

  @override
  generateVM(BuildContext context) {
    return HomeVM(context: context);
  }

  @override
  String setTitle(HomeVM vm) {
    return "XBCellDemo";
  }

  @override
  Widget? leading(HomeVM vm) {
    return null;
  }

  @override
  Widget buildPage(HomeVM vm, BuildContext context) {
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
          return XBCellTitleSubtitleArrow(
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
          );
        }
        if (index == 1) {
          return XBCellTitleSubtitle(
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
            maxTitleWidth: screenW * 0.5,
            subtitle: "subtitle",
            onTap: () {},
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
            onTap: () {},
          );
        }
        if (index == 3) {
          return XBCellIconTitleArrow(
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
          );
        }
        if (index == 4) {
          return XBCellTitleImageArrow(
            contentBorderRadius: BorderRadius.circular(6),
            image: "assets/images/icon_inspectionPlan.png",
            margin: EdgeInsets.only(
              left: spaces.gapDef,
              right: spaces.gapDef,
            ),
            contentHeight: 40,
            padding: EdgeInsets.only(
                left: spaces.gapDef, right: spaces.gapDef, top: 10, bottom: 10),
            title: title,
            titleStyle: const TextStyle(color: Colors.white),
            // imageSize: const Size(20, 20),
            backgroundColor: Colors.teal,
            arrowColor: Colors.white,
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
          );
        }
        return Container(
          color: colors.randColor,
          height: 50,
        );
      },
    );
  }
}
