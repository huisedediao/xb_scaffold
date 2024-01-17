import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBNavigatorObserver extends NavigatorObserver {
  final List<Route> _stack = [];

  bool isTop(Widget widget) {
    return topIsType(widget.runtimeType);
  }

  bool topIsType(Type type) {
    if (_stack.isEmpty) return false;
    for (int i = _stack.length - 1; i >= 0; i--) {
      Route tempRoute = _stack[i];
      if (isXBRoute(tempRoute)) {
        if (tempRoute.settings.name == '$type') {
          return true;
        } else {
          return false;
        }
      }
    }
    return false;
  }

  bool isInStack(Type type) {
    if (_stack.isEmpty) return false;
    for (int i = _stack.length - 1; i >= 0; i--) {
      Route tempRoute = _stack[i];
      if (isXBRoute(tempRoute)) {
        if (tempRoute.settings.name == '$type') {
          return true;
        }
      }
    }
    return false;
  }

  Map xbRouteArg(Route route) {
    return route.settings.arguments as Map;
  }

  bool isXBRoute(Route route) {
    final arg = route.settings.arguments;
    if (arg == null || arg is! Map) {
      return false;
    }
    final tempName = arg[xbCategoryNameKey];
    return tempName != null && tempName is String && tempName == xbCategoryName;
  }

  bool get topIsXBRoute {
    if (_stack.isEmpty) return false;
    return isXBRoute(_stack.last);
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    debugPrint("didPush:$route");
    _stack.add(route);
    stackStreamController.add(null);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    debugPrint("didPop:$route");
    _stack.removeLast();
    stackStreamController.add(null);
  }
}
