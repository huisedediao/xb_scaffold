import 'package:example/pages/switch_title_widget.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class HideTopBarTest extends XBPage<HideTopBarTestVM> {
  const HideTopBarTest({super.key});

  @override
  generateVM(BuildContext context) {
    return HideTopBarTestVM(context: context);
  }

  @override
  bool needImmersiveAppbar(HideTopBarTestVM vm) {
    return true;
  }

  @override
  Widget? buildTitle(HideTopBarTestVM vm) {
    return SwitchTitleWidget(
      titles: ["1", "2"],
      selectedIndex: 0,
      onSelectedIndex: (index) {},
    );
  }

  @override
  Widget buildPage(HideTopBarTestVM vm, BuildContext context) {
    return PageView(
      children: [SubPage(), SubPage()],
    );
  }
}

class HideTopBarTestVM extends XBPageVM<HideTopBarTest> {
  HideTopBarTestVM({required super.context});
}

class SubPage extends XBPage<SubPageVM> {
  const SubPage({super.key});

  @override
  generateVM(BuildContext context) {
    return SubPageVM(context: context);
  }

  @override
  bool needHideAppbar(SubPageVM vm) {
    return true;
  }

  @override
  Widget buildPage(SubPageVM vm, BuildContext context) {
    return Container(
      color: colors.randColor,
      child: Column(
        children: [
          Container(
            height: 150,
            color: colors.randColor,
            child: GestureDetector(
              onTap: () {
                toast("fly");
              },
              child: Container(
                width: 50,
                height: 40,
                color: Colors.amber,
              ),
            ),
          ),
          Expanded(
              child: Container(
            color: colors.randColor,
          ))
        ],
      ),
    );
  }
}

class SubPageVM extends XBPageVM<SubPage> {
  SubPageVM({required super.context});
}
