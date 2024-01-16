import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/xb_route.dart';

mixin XBRouteMixin {
  BuildContext get context;

  /// 结束编辑
  static endEditingStatic(BuildContext context) =>
      FocusScope.of(context).requestFocus(FocusNode());

  /// 页面是否在栈顶
  bool pageIsTop(Widget page) {
    return isTop(page);
  }

  /// 页面是否在栈里
  static bool pageInStack(Widget page) {
    return isInStack(page);
  }

  /// 用新页面替换当前页
  Future<T?> replacePage<T extends Object?>(Widget newPage) {
    return replace(context, newPage);
  }

  /// 进入新页面
  Future<T?> pushPage<T extends Object?>(Widget newPage) {
    return push(context, newPage);
  }

  /// 回到上一页
  Widget? popPage<O extends Object?>([O? result]) {
    return pop(context, result);
  }

  /// 回到根页面
  void popToRootPage() {
    popToRoot(context);
  }

  /// 回到最后一个Type类型的页面
  void popPageUntilType(Type type) {
    popUntilType(context, type);
  }

  /// 结束编辑
  get endEditing => endEditingStatic(context);
}
