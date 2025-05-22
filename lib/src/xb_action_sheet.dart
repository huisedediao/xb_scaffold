import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/configs/xb_color_config.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

double _cellHeight = 50;
double _gap = 8;
typedef ActionSheetMultiItemBuilder = Widget Function(
  BuildContext context,
  int index,
  bool isSelected,
  double height,
  VoidCallback onTap,
);

actionSheetWidget({
  required Widget widget,
  bool isScrollControlled = false,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  try {
    _actionSheetWidget(
        widget: widget,
        isScrollControlled: isScrollControlled,
        isDismissible: isDismissible,
        enableDrag: enableDrag);
  } catch (e) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _actionSheetWidget(
          widget: widget,
          isScrollControlled: isScrollControlled,
          isDismissible: isDismissible,
          enableDrag: enableDrag);
    });
  }
}

_actionSheetWidget({
  required Widget widget,
  bool isScrollControlled = false,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  showModalBottomSheet(
    context: xbGlobalContext,
    isScrollControlled: isScrollControlled,
    backgroundColor: Colors.transparent,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
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
            ? (selectedColor ?? colors.primary)
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

actionSheetMulti({
  required List<String> titles,

  /// 完成
  required ValueChanged<List<int>> onDone,

  /// 标题栏的高度
  double topBarHeight = 50,

  /// 取消
  VoidCallback? onCancel,

  /// 选中的序号
  List<int>? selectedIndexes,

  /// 如果有点击事件,会被覆盖，
  Widget? cancelBtn,

  /// title
  Widget? titleWidget,

  /// 如果有点击事件，会被覆盖
  Widget? doneBtn,

  /// topBar下面的分割widget
  Widget? topBarSeparator,

  /// 顶部圆角
  double topRadius = 10,

  /// 如果不为null，则使用自定义item
  ActionSheetMultiItemBuilder? itemBuilder,

  /// 分割线
  IndexedWidgetBuilder? separatorBuilder,
}) {
  actionSheetMultiItem(
      itemCount: titles.length,
      onCancel: onCancel,
      onDone: onDone,
      selectedIndexes: selectedIndexes,
      cancelBtn: cancelBtn,
      titleWidget: titleWidget,
      doneBtn: doneBtn,
      topRadius: topRadius,
      itemBuilder: itemBuilder ??
          (context, index, isSelected, height, onTap) {
            return XBActionSheetMultiDefItem(
              title: titles[index],
              isSelected: isSelected,
              height: height,
              onTap: onTap,
            );
          },
      separatorBuilder: separatorBuilder,
      topBarHeight: topBarHeight,
      topBarSeparator: topBarSeparator);
}

actionSheetMultiItem({
  /// item数量
  required int itemCount,

  /// 如果不为null，则使用自定义item
  required ActionSheetMultiItemBuilder itemBuilder,

  /// 完成
  required ValueChanged<List<int>> onDone,

  /// 标题栏的高度
  double topBarHeight = 50,

  /// 取消
  VoidCallback? onCancel,

  /// 选中的序号
  List<int>? selectedIndexes,

  /// 如果有点击事件,会被覆盖，
  Widget? cancelBtn,

  /// title
  Widget? titleWidget,

  /// topBar下面的分割widget
  Widget? topBarSeparator,

  /// 如果有点击事件，会被覆盖
  Widget? doneBtn,

  /// 顶部圆角
  double topRadius = 10,

  /// 分割线
  IndexedWidgetBuilder? separatorBuilder,
}) async {
  actionSheetWidget(
    widget: XBActionSheetMultiItemDefWidget(
        itemCount: itemCount,
        selectedIndexes: selectedIndexes,
        itemBuilder: itemBuilder,
        onCancel: onCancel,
        onDone: onDone,
        topRadius: topRadius,
        cancelBtn: cancelBtn,
        doneBtn: doneBtn,
        titleWidget: titleWidget,
        separatorBuilder: separatorBuilder,
        topBarHeight: topBarHeight,
        topBarSeparator: topBarSeparator),
    isScrollControlled: true,
  );
}

class XBActionSheetMultiItemDefWidget
    extends XBWidget<XBActionSheetMultiItemDefWidgetVM> {
  final int itemCount;

  /// 如果不为null，则使用自定义item
  final ActionSheetMultiItemBuilder itemBuilder;

  /// 完成
  final ValueChanged<List<int>> onDone;

  /// 标题栏的高度
  final double topBarHeight;

  /// topBar下面的分割widget
  final Widget? topBarSeparator;

  /// 取消
  final VoidCallback? onCancel;

  /// 选中的序号
  final List<int>? selectedIndexes;

  /// 如果有点击事件,会被覆盖，
  final Widget? cancelBtn;

  /// title
  final Widget? titleWidget;

  /// 如果有点击事件，会被覆盖
  final Widget? doneBtn;

  /// 顶部圆角
  final double topRadius;

  /// 分割线
  final IndexedWidgetBuilder? separatorBuilder;
  const XBActionSheetMultiItemDefWidget(
      {required this.itemCount,
      required this.itemBuilder,
      required this.onDone,
      this.onCancel,
      this.topBarHeight = 50,
      this.topBarSeparator,
      this.selectedIndexes,
      this.cancelBtn,
      this.titleWidget,
      this.doneBtn,
      this.topRadius = 10,
      this.separatorBuilder,
      super.key});

  @override
  generateVM(BuildContext context) {
    return XBActionSheetMultiItemDefWidgetVM(context: context);
  }

  @override
  Widget buildWidget(
      XBActionSheetMultiItemDefWidgetVM vm, BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.only(
          topLeft: Radius.circular(topRadius),
          topRight: Radius.circular(topRadius)),
      child: Container(
        color: Colors.white,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: vm.titleHeight,
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(child: leftBtn),
                        centerWidget,
                        Expanded(child: rightBtn(vm))
                      ],
                    ),
                  ),
                  topBarSeparator ??
                      Container(
                        height: onePixel,
                        color: Colors.grey.withAlpha(70),
                      )
                ],
              ),
            ),
            SizedBox(
              height: vm.listViewHeight,
              child: ListView.separated(
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  bool isSelected = vm.isSelected(index);
                  return itemBuilder(context, index, isSelected, vm.itemHeight,
                      () {
                    vm.onSelect(index);
                  });
                },
                separatorBuilder: (context, index) {
                  if (separatorBuilder != null) {
                    return separatorBuilder!(context, index);
                  }
                  return Container(
                    height: onePixel,
                    color: Colors.grey.withAlpha(50),
                  );
                },
              ),
            ),
            SizedBox(
              height: safeAreaBottom,
            )
          ],
        ),
      ),
    );
  }

  Widget get leftBtn {
    Widget ret;
    if (cancelBtn != null) {
      ret = cancelBtn!;
    } else {
      ret = Padding(
        padding: EdgeInsets.only(left: spaces.gapLess),
        child: const Text("取消"),
      );
    }
    return XBButton(
        onTap: () {
          pop();
          onCancel?.call();
        },
        child: Container(
            color: Colors.transparent,
            alignment: Alignment.centerLeft,
            child: ret));
  }

  Widget get centerWidget => titleWidget ?? Container();

  Widget rightBtn(XBActionSheetMultiItemDefWidgetVM vm) {
    Widget ret;
    if (doneBtn != null) {
      ret = doneBtn!;
    } else {
      ret = Padding(
        padding: EdgeInsets.only(right: spaces.gapLess),
        child: Text(
          "确定",
          style: TextStyle(
              color: const Color.fromARGB(255, 42, 124, 247).withAlpha(200)),
        ),
      );
    }
    return XBButton(
        onTap: () {
          pop();
          onDone(vm.selectedIndexes..sort());
        },
        child: Container(
            color: Colors.transparent,
            alignment: Alignment.centerRight,
            child: ret));
  }
}

class XBActionSheetMultiItemDefWidgetVM
    extends XBVM<XBActionSheetMultiItemDefWidget> {
  List<int> selectedIndexes = [];
  XBActionSheetMultiItemDefWidgetVM({required super.context}) {
    selectedIndexes.addAll(widget.selectedIndexes ?? []);
  }

  double get titleHeight => widget.topBarHeight;

  double get listViewMaxHeight => screenH * 0.7 - titleHeight - safeAreaBottom;

  double get itemHeight => 50;

  double get totalItemHeight => widget.itemCount * itemHeight;

  double get totalSeparatorHeight =>
      widget.itemCount <= 0 ? 0 : (1.0 * (widget.itemCount - 1) * onePixel);

  double get totalListViewContentHeight =>
      totalItemHeight + totalSeparatorHeight;

  double get listViewHeight => totalListViewContentHeight > listViewMaxHeight
      ? listViewMaxHeight
      : totalListViewContentHeight;

  onSelect(int index) {
    if (selectedIndexes.contains(index)) {
      selectedIndexes.remove(index);
    } else {
      selectedIndexes.add(index);
    }
    notify();
  }

  isSelected(int index) => selectedIndexes.contains(index);
}

class XBActionSheetMultiDefItem extends StatelessWidget {
  final String title;
  final bool isSelected;
  final VoidCallback? onTap;
  final double height;
  const XBActionSheetMultiDefItem({
    super.key,
    required this.title,
    required this.isSelected,
    required this.height,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return XBButton(
      preventMultiTapMilliseconds: 0,
      onTap: onTap,
      child: Container(
        color: Colors.white,
        height: height,
        child: Row(
          children: [
            SizedBox(
              width: spaces.gapDef,
            ),
            Expanded(
                child: Text(
              title,
              overflow: TextOverflow.ellipsis,
            )),
            const SizedBox(
              width: 8,
            ),
            SizedBox(
              width: 22,
              height: 22,
              child: isSelected
                  ? Icon(
                      Icons.radio_button_checked,
                      color: const Color.fromARGB(255, 42, 124, 247)
                          .withAlpha(200),
                    )
                  : Icon(
                      Icons.radio_button_unchecked,
                      color: Colors.grey.withAlpha(100),
                    ),
            ),
            SizedBox(
              width: spaces.gapDef,
            ),
          ],
        ),
      ),
    );
  }
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
