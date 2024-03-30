import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBNavigatorObserver extends NavigatorObserver {
  final List<Route> _stack = [];

  bool topIsWidget(Widget widget, [bool ignore = true]) {
    return _topIsType(widget.runtimeType, ignore, widget.hashCode);
  }

  bool topIsType(Type type, [bool ignore = true]) {
    return _topIsType(type, ignore);
  }

  /// ignore: 是否忽略XBRoute以外的路由
  /// ignore为true，则从栈顶往下找到第一个XBRoute进行判断，否则直接取栈顶元素判断
  /// hsCode如果不为空，则再判断hashCode是否相等
  bool _topIsType(Type type, [bool ignore = true, int? hsCode]) {
    if (_stack.isEmpty) return false;
    String typeStr = '$type';
    if (ignore == false) {
      return isXBRoute(_stack.last, hsCode) &&
          _stack.last.settings.name == typeStr;
    }
    for (int i = _stack.length - 1; i >= 0; i--) {
      Route tempRoute = _stack[i];
      if (isXBRoute(tempRoute, hsCode)) {
        if (tempRoute.settings.name == typeStr) {
          return true;
        } else {
          return false;
        }
      }
    }
    return false;
  }

  bool stackContainWidget(Widget widget) {
    return _stackContainType(widget.runtimeType, widget.hashCode);
  }

  bool stackContainType(Type type, [int? hsCode]) {
    return _stackContainType(type);
  }

  bool _stackContainType(Type type, [int? hsCode]) {
    if (_stack.isEmpty) return false;
    for (int i = _stack.length - 1; i >= 0; i--) {
      Route tempRoute = _stack[i];
      if (isXBRoute(tempRoute, hsCode)) {
        if (tempRoute.settings.name == '$type') {
          return true;
        }
      }
    }
    return false;
  }

  /// 判断是否是XBRoute
  /// hsCode如果不为空，则再判断hashCode是否相等
  /// 忽略hashCode碰撞
  bool isXBRoute(Route route, [int? hsCode]) {
    final arg = route.settings.arguments;
    if (arg == null || arg is! Map) {
      return false;
    }
    final tempCategoryName = arg[xbCategoryNameKey];
    final isXBRouteType = tempCategoryName != null &&
        tempCategoryName is String &&
        tempCategoryName == xbCategoryName;
    if (hsCode != null) {
      final tempHashCode = arg[xbHashCodeKey];
      final isSameCode =
          tempHashCode != null && tempHashCode is int && tempHashCode == hsCode;
      return isXBRouteType && isSameCode;
    }
    return isXBRouteType;
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
    xbStackStreamController.add(null);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    _logRouteInfo(route, previousRoute, 1);
    _stack.removeLast();
    debugPrint("_stack len:${_stack.length}");
    xbStackStreamController.add(null);
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
