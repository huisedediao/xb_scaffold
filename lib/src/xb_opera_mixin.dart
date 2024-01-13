import 'package:flutter/material.dart';

mixin XBOperaMixin {
  BuildContext get context;

  static final List<Widget> _stack = [];

  /// 页面是否在栈顶
  static bool isTop(Widget page) {
    return _stack.last == page;
  }

  /// 用新页面替换当前页
  static void replaceStatic(BuildContext context, Widget newPage) {
    popStatic(context);
    pushStatic(context, newPage);
  }

  /// 进入新页面
  static Future<T?> pushStatic<T extends Object?>(
      BuildContext context, Widget newPage) {
    _stack.add(newPage);
    return Navigator.push(
        context, MaterialPageRoute<T>(builder: (context) => newPage));
  }

  /// 回到上一页
  static Widget? popStatic<O extends Object?>(BuildContext context,
      [O? result]) {
    if (_stack.isNotEmpty) {
      Navigator.of(context, rootNavigator: false).pop(result);
      return _stack.removeLast();
    }
    return null;
  }

  /// 回到根页面
  static void popToRootStatic(BuildContext context) {
    if (_stack.isNotEmpty) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      _stack.clear();
    }
  }

  /// 回到最后一个Type类型的页面
  static void popUntilTypeStatic(BuildContext context, Type type) {
    while (_stack.isNotEmpty) {
      final remove = popStatic(context);
      if (remove == null || type == remove.runtimeType) {
        break;
      }
    }
  }

  /// 结束编辑
  static endEditingStatic(BuildContext context) =>
      FocusScope.of(context).requestFocus(FocusNode());

  /// 用新页面替换当前页
  void replace(Widget newPage) {
    replaceStatic(context, newPage);
  }

  /// 进入新页面
  Future<T?> push<T extends Object?>(Widget newPage) {
    return pushStatic(context, newPage);
  }

  /// 回到上一页
  Widget? pop<O extends Object?>([O? result]) {
    return popStatic(context, result);
  }

  /// 回到根页面
  void popToRoot() {
    popToRootStatic(context);
  }

  /// 回到最后一个Type类型的页面
  void popUntilType(Type type) {
    popUntilTypeStatic(context, type);
  }

  /// 结束编辑
  get endEditing => endEditingStatic(context);
}
