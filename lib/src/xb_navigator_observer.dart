import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBStackChangedEvent {
  /// type: 0 push；1 pop
  final int type;
  final Route route;
  final Route? previousRoute;

  bool get isPush => type == 0;
  bool get isPop => type == 1;

  XBStackChangedEvent(
      {required this.type, required this.route, this.previousRoute});
}

class XBNavigatorObserver extends NavigatorObserver {
  final List<Route> _stack = [];

  int _indexOfRoute(Route route) {
    for (int i = _stack.length - 1; i >= 0; i--) {
      if (identical(_stack[i], route)) {
        return i;
      }
    }
    return -1;
  }

  void _safeRemoveRoute({required Route route, required String source}) {
    if (_stack.isEmpty) {
      xbError("$source: stack empty, route=${_routeInfo(route)}");
      return;
    }

    if (identical(_stack.last, route)) {
      _stack.removeLast();
      return;
    }

    final routeIndex = _indexOfRoute(route);
    if (routeIndex >= 0) {
      _stack.removeAt(routeIndex);
      xbError(
          "$source: stack drift fixed, removedAt=$routeIndex, route=${_routeInfo(route)}");
      return;
    }

    xbError("$source: route not found, route=${_routeInfo(route)}");
  }

  bool topIsType(Type type, [bool ignore = true]) {
    return _topIsType(type, ignore);
  }

  /// ignore: 是否忽略XBRoute以外的路由
  /// ignore为true，则从栈顶往下找到第一个XBRoute进行判断，否则直接取栈顶元素判断
  /// hsCode如果不为空，则再判断hashCode是否相等
  bool _topIsType(Type type, [bool ignore = true, int? hsCode]) {
    return _topNIsType(type, 0, ignore, hsCode);
  }

  /// 栈顶之下第n是type类型
  bool _topNIsType(Type type, [int n = 0, bool ignore = true, int? hsCode]) {
    int fixN = 1 + n;
    if (_stack.length < fixN) return false;
    String typeStr = '$type';
    if (ignore == false) {
      final tempRoute = _stack[_stack.length - fixN];
      return ((_isXBRoute(tempRoute) || _isGetRoute(tempRoute)) &&
              (hsCode == null
                  ? true
                  : _isEqualHashCode(route: tempRoute, hsCode: hsCode))) &&
          _getRouteName(tempRoute) == typeStr;
    }
    int routeIndex = 0;
    for (int i = _stack.length - 1; i >= 0; i--) {
      Route tempRoute = _stack[i];
      if (_isXBRoute(tempRoute) || _isGetRoute(tempRoute)) {
        if (routeIndex < n) {
          routeIndex++;
        } else {
          if (_getRouteName(tempRoute) == typeStr &&
              (hsCode == null
                  ? true
                  : _isEqualHashCode(route: tempRoute, hsCode: hsCode))) {
            return true;
          } else {
            return false;
          }
        }
      }
    }
    return false;
  }

  bool stackContainType(Type type, [int? hsCode]) {
    return _stackContainType(type);
  }

  bool _stackContainType(Type type, [int? hsCode]) {
    if (_stack.isEmpty) return false;
    for (int i = _stack.length - 1; i >= 0; i--) {
      Route tempRoute = _stack[i];
      if ((_isXBRoute(tempRoute) || _isGetRoute(tempRoute)) &&
          (hsCode == null
              ? true
              : _isEqualHashCode(route: tempRoute, hsCode: hsCode))) {
        if (_getRouteName(tempRoute) == '$type') {
          return true;
        }
      }
    }
    return false;
  }

  /// 判断路由是否映射Widget
  /// 必须是XBRoute
  bool routeIsMapWidget({required Route route, required Widget widget}) {
    return _isXBRoute(route) &&
        _isEqualHashCode(route: route, hsCode: widget.hashCode);
  }

  /// 判断是否是XBRoute
  bool isXBRoute(Route route) {
    return _isXBRoute(route);
  }

  /// 判断是否是XBRoute
  bool _isXBRoute(Route route) {
    final arg = route.settings.arguments;
    if (arg == null || arg is! Map) {
      return false;
    }
    final tempCategoryName = arg[xbCategoryNameKey];
    return tempCategoryName != null &&
        tempCategoryName is String &&
        tempCategoryName == xbCategoryName;
  }

  /// 判断是否是GetRoute
  bool _isGetRoute(Route route) {
    return "${route.runtimeType}".startsWith("GetPageRoute");
  }

  /// 判断hashCode是否相等
  bool _isEqualHashCode({required Route route, required int hsCode}) {
    final arg = route.settings.arguments;
    if (arg == null || arg is! Map) {
      return false;
    }
    final tempHashCode = arg[xbHashCodeKey];
    return tempHashCode != null &&
        tempHashCode is int &&
        tempHashCode == hsCode;
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
    final changedInfo = XBStackChangedEvent(
        type: 0, route: route, previousRoute: previousRoute);
    _logRouteInfo(changedInfo);
    _stack.add(route);
    debugPrint("_stack len:${_stack.length}");
    xbStackStreamController.add(changedInfo);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    final changedInfo = XBStackChangedEvent(
        type: 1, route: route, previousRoute: previousRoute);
    _logRouteInfo(changedInfo);
    _safeRemoveRoute(route: route, source: "didPop");
    debugPrint("_stack len:${_stack.length}");
    xbStackStreamController.add(changedInfo);
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    String log =
        "didRemove:${_routeInfo(route)},previous:${_routeInfo(previousRoute)}";
    xbError(log);
    recordPageLog(log);
    _safeRemoveRoute(route: route, source: "didRemove");
    debugPrint("_stack len:${_stack.length}");
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    String log =
        "didReplace:new=${_routeInfo(newRoute)},old=${_routeInfo(oldRoute)}";
    xbError(log);
    recordPageLog(log);

    if (oldRoute == null) {
      if (newRoute != null) {
        _stack.add(newRoute);
        xbError("didReplace: oldRoute is null, append new route.");
      }
      debugPrint("_stack len:${_stack.length}");
      return;
    }

    final oldRouteIndex = _indexOfRoute(oldRoute);
    if (oldRouteIndex < 0) {
      if (newRoute != null) {
        _stack.add(newRoute);
        xbError("didReplace: oldRoute not found, append new route.");
      } else {
        xbError("didReplace: oldRoute not found and newRoute is null.");
      }
      debugPrint("_stack len:${_stack.length}");
      return;
    }

    if (newRoute == null) {
      _stack.removeAt(oldRouteIndex);
    } else {
      _stack[oldRouteIndex] = newRoute;
    }

    debugPrint("_stack len:${_stack.length}");
  }

  String _routeInfo(Route? route) {
    String ret;
    if (route == null) {
      ret = "null";
    } else if (isXBRoute(route) || _isGetRoute(route)) {
      ret = _getRouteName(route);
    } else {
      ret = route.toString();
    }
    return ret;
  }

  String _getRouteName(Route route) {
    if (_isXBRoute(route)) {
      return route.settings.name!;
    }
    if (_isGetRoute(route)) {
      return route.settings.name!.replaceFirst("/", "");
    }
    return "";
  }

  _logRouteInfo(XBStackChangedEvent info) {
    String opera = info.isPush ? "didPush" : "didPop";
    String log =
        "$opera:${_routeInfo(info.route)},previous:${_routeInfo(info.previousRoute)}";
    xbError(log);
    recordPageLog(log);
  }
}
