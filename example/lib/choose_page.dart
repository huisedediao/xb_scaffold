import 'package:example/pages/xb_dialog_input_demo.dart';
import 'package:example/pages/xb_page_demo.dart';
import 'package:example/pages/xb_cell_demo.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class ChoosePage extends XBPage<ChoosePageVM> {
  const ChoosePage({super.key});

  @override
  generateVM(BuildContext context) {
    return ChoosePageVM(context: context);
  }

  @override
  Widget? leading(ChoosePageVM vm) {
    return null;
  }

  @override
  Widget buildPage(ChoosePageVM vm, BuildContext context) {
    return ListView.separated(
      itemCount: vm.titles.length,
      separatorBuilder: (context, index) {
        return Container(
          height: 10,
        );
      },
      itemBuilder: (context, index) {
        String title = vm.titles[index];
        return XBCellTitleSubtitle(
          backgroundColor: colors.randColor,
          padding: EdgeInsets.all(spaces.gapDef),
          title: title,
          onTap: () {
            vm.onTapIndex(index);
          },
          subtitle: '',
          isShowArrow: true,
        );
      },
    );
  }
}

class ChoosePageVM extends XBPageVM<ChoosePage> {
  ChoosePageVM({required super.context});

  List<String> titles = [
    "XBCell demo",
    "XBPage demo",
    "XBDialogInput demo",
  ];

  void onTapIndex(int index) {
    if (index == 0) {
      push(const XBCellDemo());
    } else if (index == 1) {
      push(const XBPageDemo());
    } else if (index == 2) {
      push(const XBDialogInputDemo());
    }
  }
}
