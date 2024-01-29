import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/configs/color_config.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

double _cellHeight = 50;
double _gap = 8;

actionSheetWidget({required Widget widget, bool isScrollControlled = false}) {
  try {
    _actionSheetWidget(widget: widget, isScrollControlled: isScrollControlled);
  } catch (e) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _actionSheetWidget(
          widget: widget, isScrollControlled: isScrollControlled);
    });
  }
}

_actionSheetWidget({required Widget widget, bool isScrollControlled = false}) {
  showModalBottomSheet(
    context: xbGlobalContext,
    isScrollControlled: isScrollControlled,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) {
      return widget;
    },
  );
}

actionSheet({
  required List<String> titles,
  required ValueChanged<int> onSelected,
  int? selectedIndex,
  Color? selectedColor,
  String? dismissTitle,
  Color? dismissTitleColor,
  double? dismissTitleFontSize,
  VoidCallback? onTapDismiss,
}) {
  List<Widget> children = List.generate(titles.length, (index) {
    bool isLast = index == titles.length - 1;
    return Padding(
      padding: EdgeInsets.only(
          bottom: dismissTitle != null ? 0 : (isLast ? safeAreaBottom : 0)),
      child: XBActionSheetCell(
        title: titles[index],
        titleColor: selectedIndex == index
            ? (selectedColor ?? Colors.blue)
            : Colors.black,
        showLine: !isLast,
        onTap: () {
          Navigator.of(xbGlobalContext, rootNavigator: false).pop();
          onSelected(index);
        },
      ),
    );
  });
  double dismissWidgetHeight = 0;
  List<Widget> dismissWidgets = [];
  if (dismissTitle != null) {
    dismissWidgets.add(Container(
      color: lineColor.withAlpha(100),
      height: _gap,
    ));
    dismissWidgets.add(Padding(
      padding: EdgeInsets.only(bottom: safeAreaBottom),
      child: XBActionSheetCell(
        title: dismissTitle,
        titleColor: dismissTitleColor ?? Colors.black,
        titleFontSize: dismissTitleFontSize ?? 14,
        showLine: false,
        onTap: () {
          Navigator.of(xbGlobalContext, rootNavigator: false).pop();
          if (onTapDismiss != null) {
            onTapDismiss();
          }
        },
      ),
    ));
    dismissWidgetHeight =
        (_cellHeight + _gap + onePixel + safeAreaBottom).toDouble();
  }
  actionSheetWidget(
      widget: ClipRRect(
    borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(10), topRight: Radius.circular(10)),
    child: Container(
      color: Colors.white,
      child: Stack(
        children: [
          SingleChildScrollView(
              child: Padding(
            padding: EdgeInsets.only(bottom: dismissWidgetHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          )),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.white,
              child: Column(
                children: List.generate(
                    dismissWidgets.length, (index) => dismissWidgets[index]),
              ),
            ),
          )
        ],
      ),
    ),
  ));
}

class XBActionSheetCell extends XBWidget {
  final String title;
  final double? titleFontSize;
  final Color titleColor;
  final VoidCallback? onTap;
  final bool showLine;
  const XBActionSheetCell(
      {super.key,
      required this.title,
      this.titleColor = Colors.black,
      this.showLine = true,
      this.titleFontSize,
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
          height: _cellHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: showLine ? lineColor : Colors.transparent, // 边框颜色
                width: onePixel, // 边框宽度
              ),
            ),
          ),
          child: Text(
            title,
            style: TextStyle(color: titleColor, fontSize: titleFontSize ?? 14),
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
