import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

final List<Widget> _stack = [];

/// 页面是否在栈顶
bool isTop(Widget page) {
  return _stack.last == page;
}

/// 页面是否在栈里
bool isInStack(Widget page) {
  return _stack.contains(page);
}

/// 进入新页面
/// style：0 iOS风格；1 material风格
Future<T?> push<T extends Object?>(BuildContext context, Widget newPage,
    [int style = 0]) {
  _stack.add(newPage);
  debugPrint('push ${newPage.runtimeType}');
  if (style == 0) {
    return Navigator.push(
        context, CupertinoPageRoute<T>(builder: (ctx) => newPage));
  } else {
    return Navigator.push(
        context, MaterialPageRoute<T>(builder: (context) => newPage));
  }
}

/// 回到上一页
Widget? pop<O extends Object?>(BuildContext context, [O? result]) {
  if (_stack.isNotEmpty) {
    Navigator.of(context, rootNavigator: false).pop(result);
    final ret = _stack.removeLast();
    debugPrint('pop ${ret.runtimeType}');
    return ret;
  }
  return null;
}

/// 用新页面替换当前页
Future<T?> replace<T extends Object?>(BuildContext context, Widget newPage) {
  pop(context);
  return push(context, newPage);
}

/// 回到根页面
void popToRoot(BuildContext context) {
  if (_stack.isNotEmpty) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    _stack.clear();
  }
}

/// 进入新页面，并且清除栈中的页面
/// style：0 iOS风格；1 material风格
Future<T?> pushAndClearStack<T extends Object?>(
    BuildContext context, Widget newPage,
    [int style = 0]) {
  popToRoot(context);
  return push(context, newPage);
}

/// 回到最后一个Type类型的页面
/// 如果找不到，则回到根页面
void popUntilType(BuildContext context, Type type) {
  while (true) {
    pop(context);
    if (_stack.isEmpty || type == _stack.last.runtimeType) {
      break;
    }
  }
}
