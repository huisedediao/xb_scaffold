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
    return _topNIsType(type, 0, ignore, hsCode);
  }

  /// 栈顶之下第一个是widget
  bool topSecondIsWidget(Widget widget, [bool ignore = true]) {
    return topNIsWidget(widget, 1, ignore);
  }

  /// 栈顶之下第n是widget
  bool topNIsWidget(Widget widget, [int n = 0, bool ignore = true]) {
    return _topNIsType(widget.runtimeType, n, ignore, widget.hashCode);
  }

  /// 栈顶之下第n是type类型
  bool _topNIsType(Type type, [int n = 0, bool ignore = true, int? hsCode]) {
    int fixN = 1 + n;
    if (_stack.length < fixN) return false;
    String typeStr = '$type';
    if (ignore == false) {
      final tempRoute = _stack[_stack.length - fixN];
      return (_isXBRoute(tempRoute) &&
              (hsCode == null
                  ? true
                  : _isEqualHashCode(route: tempRoute, hsCode: hsCode))) &&
          tempRoute.settings.name == typeStr;
    }
    int routeIndex = 0;
    for (int i = _stack.length - 1; i >= 0; i--) {
      Route tempRoute = _stack[i];
      if (_isXBRoute(tempRoute)) {
        if (routeIndex < n) {
          routeIndex++;
        } else {
          if (tempRoute.settings.name == typeStr &&
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
      if (_isXBRoute(tempRoute) &&
          (hsCode == null
              ? true
              : _isEqualHashCode(route: tempRoute, hsCode: hsCode))) {
        if (tempRoute.settings.name == '$type') {
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
    _stack.removeLast();
    debugPrint("_stack len:${_stack.length}");
    xbStackStreamController.add(changedInfo);
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

  _logRouteInfo(XBStackChangedEvent info) {
    String opera = info.isPush ? "didPush" : "didPop";
    String log =
        "$opera:${_routeInfo(info.route)},previous:${_routeInfo(info.previousRoute)}";
    debugPrint(log);
    recordPageLog(log);
  }
}
