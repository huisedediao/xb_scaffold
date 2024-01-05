import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/configs/color_config.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

extension XBVMActionSheet on XBVM {
  static actionSheetWidgetStatic({
    required BuildContext context,
    required Widget widget,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return widget;
      },
    );
  }

  /// 底部抽屉的形式弹出一个widget
  actionSheetWidget({required Widget widget}) {
    actionSheetWidgetStatic(context: context, widget: widget);
  }

  static actionSheetStatic(
      {required BuildContext context,
      required List<String> titles,
      required ValueChanged<int> onSelected}) {
    actionSheetWidgetStatic(
        context: context,
        widget: ClipRRect(
          borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(10), topRight: Radius.circular(10)),
          child: Container(
            color: Colors.white,
            child: SingleChildScrollView(
                child: Column(
              children: List.generate(titles.length, (index) {
                bool isLast = index == titles.length - 1;
                return Padding(
                  padding: EdgeInsets.only(
                      bottom: isLast
                          ? XBSysSpaceMixin.getSafeAreaBottom(context)
                          : 0),
                  child: XBActionSheetCell(
                    title: titles[index],
                    showLine: !isLast,
                    onTap: () {
                      XBOperaMixin.popStatic(context);
                      onSelected(index);
                    },
                  ),
                );
              }),
            )),
          ),
        ));
  }

  /// 展示一个底部选择框
  actionSheet(
      {required List<String> titles, required ValueChanged<int> onSelected}) {
    actionSheetStatic(context: context, titles: titles, onSelected: onSelected);
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
        padding:
            EdgeInsets.only(left: app.spaces.gapDef, right: app.spaces.gapDef),
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
