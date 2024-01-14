import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

mixin XBOperaMixin {
  BuildContext get context;

  static final List<Widget> _stack = [];

  /// 页面是否在栈顶
  static bool pageIsTopStatic(Widget page) {
    return _stack.last == page;
  }

  /// 用新页面替换当前页
  static void replacePageStatic(BuildContext context, Widget newPage) {
    popPageStatic(context);
    pushPageStatic(context, newPage);
  }

  /// 进入新页面
  /// style：0 iOS风格；1 material风格
  static Future<T?> pushPageStatic<T extends Object?>(
      BuildContext context, Widget newPage,
      [int style = 0]) {
    _stack.add(newPage);
    if (style == 0) {
      return Navigator.push(
          context, CupertinoPageRoute<T>(builder: (ctx) => newPage));
    } else {
      return Navigator.push(
          context, MaterialPageRoute<T>(builder: (context) => newPage));
    }
  }

  /// 回到上一页
  static Widget? popPageStatic<O extends Object?>(BuildContext context,
      [O? result]) {
    if (_stack.isNotEmpty) {
      Navigator.of(context, rootNavigator: false).pop(result);
      return _stack.removeLast();
    }
    return null;
  }

  /// 回到根页面
  static void popToRootPageStatic(BuildContext context) {
    if (_stack.isNotEmpty) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      _stack.clear();
    }
  }

  /// 回到最后一个Type类型的页面
  /// 如果找不到，则回到根页面
  static void popPageUntilTypeStatic(BuildContext context, Type type) {
    while (true) {
      popPageStatic(context);
      if (_stack.isEmpty || type == _stack.last.runtimeType) {
        break;
      }
    }
  }

  /// 结束编辑
  static endEditingStatic(BuildContext context) =>
      FocusScope.of(context).requestFocus(FocusNode());

  /// 页面是否在栈顶
  bool pageIsTop(Widget page) {
    return _stack.last == page;
  }

  /// 用新页面替换当前页
  void replacePage(Widget newPage) {
    replacePageStatic(context, newPage);
  }

  /// 进入新页面
  Future<T?> pushPage<T extends Object?>(Widget newPage) {
    return pushPageStatic(context, newPage);
  }

  /// 回到上一页
  Widget? popPage<O extends Object?>([O? result]) {
    return popPageStatic(context, result);
  }

  /// 回到根页面
  void popToRootPage() {
    popToRootPageStatic(context);
  }

  /// 回到最后一个Type类型的页面
  void popPageUntilType(Type type) {
    popPageUntilTypeStatic(context, type);
  }

  /// 结束编辑
  get endEditing => endEditingStatic(context);
}
