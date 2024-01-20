import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBNavigatorObserver extends NavigatorObserver {
  final List<Route> _stack = [];

  bool isTop(Widget widget) {
    return topIsType(widget.runtimeType);
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

  void showStack() {
    for (int i = _stack.length - 1; i >= 0; i--) {
      Route temp = _stack[i];
      debugPrint("index:$i,route:${_routeInfo(temp)}");
    }
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    _logRouteInfo(route, previousRoute);
    _stack.add(route);
    debugPrint("_stack len:${_stack.length}");
    stackStreamController.add(null);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    _logRouteInfo(route, previousRoute, 1);
    _stack.removeLast();
    debugPrint("_stack len:${_stack.length}");
    stackStreamController.add(null);
  }

  String _routeInfo(Route? route) {
    String ret;
    if (route == null) {
      ret = "null";
    } else if (isXBRoute(route)) {
      ret = route.settings.name!;
    } else {
      ret = route.toString();
    }
    return ret;
  }

  /// type: 0 push；1 pop
  _logRouteInfo(Route route, Route? previousRoute, [int type = 0]) {
    String opera = type == 0 ? "didPush" : "didPop";
    debugPrint(
        "$opera:${_routeInfo(route)},previous:${_routeInfo(previousRoute)}");
  }
}
