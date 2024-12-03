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
        return Container(
          color: colors.randColor,
          height: 50,
        );
      },
    );
  }
}
