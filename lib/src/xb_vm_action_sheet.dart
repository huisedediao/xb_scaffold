import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/configs/color_config.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

extension XBVMActionSheet on XBVM {
  actionSheetWidget(Widget widget) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return widget;
      },
    );
  }

  actionSheet(
      {required List<String> titles, required ValueChanged<int> onSelected}) {
    actionSheetWidget(ClipRRect(
      borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(10), topRight: Radius.circular(10)),
      child: Container(
        color: Colors.white,
        child: SingleChildScrollView(
            child: Column(
          children: List.generate(titles.length, (index) {
            bool isLast = index == titles.length - 1;
            return Padding(
              padding: EdgeInsets.only(bottom: isLast ? safeAreaBottom : 0),
              child: XBActionSheetCell(
                title: titles[index],
                showLine: !isLast,
                onTap: () {
                  pop();
                  onSelected(index);
                },
              ),
            );
          }),
        )),
      ),
    ));
  }
}

class XBActionSheetCell extends XBWidget {
  final String title;
  final Color titleColor;
  final VoidCallback? onTap;
  final bool showLine;
  const XBActionSheetCell(
      {super.key,
      required this.title,
      this.titleColor = Colors.black,
      this.showLine = true,
      this.onTap});

  @override
  Widget buildWidget(XBVM vm, BuildContext context) {
    return XBButton(
      effect: XBButtonTapEffect.cover,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.only(
            left: app.spaces.leftGap, right: app.spaces.leftGap),
        child: Container(
          height: 50,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: showLine ? lineColor : Colors.transparent, // 边框颜色
                width: vm.onePixel, // 边框宽度
              ),
            ),
          ),
          child: Text(
            title,
            style: TextStyle(color: titleColor),
          ),
        ),
      ),
    );
  }

  @override
  XBVM generateVM(BuildContext context) {
    return XBVM(context: context);
  }
}
