import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

final List<Widget> _stack = [];

StreamController _stackStreamController = StreamController.broadcast();

Stream get stackStream => _stackStreamController.stream;

/// 页面是否在栈顶
bool isTop(Widget page) {
  return _stack.last == page;
}

/// 栈顶是否是type类型
bool topIsType(Type type) {
  return _stack.last.runtimeType == type;
}

/// 页面是否在栈里
bool isInStack(Widget page) {
  return _stack.contains(page);
}

/// 进入新页面
/// style：0 iOS风格；1 material风格
Future<T?> push<T extends Object?>(Widget newPage, [int style = 0]) {
  _stack.add(newPage);
  _stackStreamController.add(null);
  debugPrint('push ${newPage.runtimeType}');
  if (style == 0) {
    return Navigator.push(
        xbGlobalContext, CupertinoPageRoute<T>(builder: (ctx) => newPage));
  } else {
    return Navigator.push(
        xbGlobalContext, MaterialPageRoute<T>(builder: (context) => newPage));
  }
}

/// 回到上一页
Widget? pop<O extends Object?>([O? result]) {
  if (_stack.isNotEmpty) {
    Navigator.of(xbGlobalContext, rootNavigator: false).pop(result);
    final ret = _stack.removeLast();
    _stackStreamController.add(null);
    debugPrint('pop ${ret.runtimeType}');
    return ret;
  }
  return null;
}

/// 用新页面替换当前页
Future<T?> replace<T extends Object?>(Widget newPage) {
  pop();
  return push(newPage);
}

/// 回到根页面
void popToRoot() {
  if (_stack.isNotEmpty) {
    Navigator.of(xbGlobalContext).popUntil((route) => route.isFirst);
    _stack.clear();
    _stackStreamController.add(null);
  }
}

/// 进入新页面，并且清除栈中的页面
/// style：0 iOS风格；1 material风格
Future<T?> pushAndClearStack<T extends Object?>(Widget newPage,
    [int style = 0]) {
  popToRoot();
  return push(newPage);
}

/// 回到最后一个Type类型的页面
/// 如果找不到，则回到根页面
void popUntilType(Type type) {
  while (true) {
    pop();
    if (_stack.isEmpty || type == _stack.last.runtimeType) {
      break;
    }
  }
}
