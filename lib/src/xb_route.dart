import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

String xbCategoryNameKey = "xb_category";
String xbCategoryName = "xb_route";
String xbHashCodeKey = "xb_hash_code";

/// 页面是否在栈顶
bool topIsWidget(Widget widget) {
  return xbNavigatorObserver.topIsWidget(widget);
}

/// 页面是否在栈顶之下的第一个
bool topSecondIsWidget(Widget widget) {
  return xbNavigatorObserver.topSecondIsWidget(widget);
}

/// 判断是否是XBRoute
bool isXBRoute(Route route) {
  return xbNavigatorObserver.isXBRoute(route);
}

/// 栈顶是否是type类型
bool topIsType(Type type) {
  return xbNavigatorObserver.topIsType(type);
}

/// 页面是否在栈里，如果是根节点，没办法判断是否在栈里
bool stackContainWidget(Widget widget) {
  return xbNavigatorObserver.stackContainWidget(widget);
}

/// 类型是否在栈里，如果是根节点，没办法判断是否在栈里
bool stackContainType(Type type) {
  return xbNavigatorObserver.stackContainType(type);
}

/// 判断路由是否映射Widget
/// 非XBRoute都返回false
bool routeIsMapWidget({required Route route, required Widget widget}) {
  return xbNavigatorObserver.routeIsMapWidget(route: route, widget: widget);
}

/// 进入新页面
/// style：0 iOS风格；1 material风格
Future<T?> push<T extends Object?>(Widget newPage, [int style = 0]) {
  final routeSetting = RouteSettings(
      name: "${newPage.runtimeType}",
      arguments: {
        xbCategoryNameKey: xbCategoryName,
        xbHashCodeKey: newPage.hashCode
      });
  if (style == 0) {
    return Navigator.push(
        xbGlobalContext,
        CupertinoPageRoute<T>(
            settings: routeSetting, builder: (context) => newPage));
  } else {
    return Navigator.push(
        xbGlobalContext,
        MaterialPageRoute<T>(
            settings: routeSetting, builder: (context) => newPage));
  }
}

/// 回到上一页
void pop<O extends Object?>([O? result]) {
  Navigator.of(xbGlobalContext, rootNavigator: false).pop(result);
}

/// 用新页面替换当前页
Future<T?> replace<T extends Object?>(Widget newPage, [int style = 0]) {
  pop();
  return push(newPage, style);
}

/// 回到根页面
void popToRoot() {
  Navigator.of(xbGlobalContext).popUntil((route) => route.isFirst);
}

/// 进入新页面，并且清除栈中的页面
/// style：0 iOS风格；1 material风格
Future<T?> pushAndClearStack<T extends Object?>(Widget newPage,
    [int style = 0]) {
  popToRoot();
  return push(newPage, style);
}

/// 回到最后一个Type类型的页面
/// 如果找不到，则回到根页面
void popUntilType(Type type) {
  Navigator.of(xbGlobalContext).popUntil((route) {
    if (route.isFirst) {
      return true;
    }
    if (topIsType(type)) {
      return true;
    } else {
      return false;
    }
  });
}

/// 回到最后一个Type类型的页面
/// 如果找不到，则回到根页面
void popUntilWidget(Widget widget) {
  Navigator.of(xbGlobalContext).popUntil((route) {
    if (route.isFirst) {
      return true;
    }
    if (topIsWidget(widget)) {
      return true;
    } else {
      return false;
    }
  });
}
