import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

String xbCategoryNameKey = 'xb_category';
String xbCategoryName = 'xb_route';
String xbHashCodeKey = 'xb_hash_code';

final RouteObserver<ModalRoute<void>> xbSimpleRouteObserver =
    RouteObserver<ModalRoute<void>>();

class XBStackChangedEvent {
  final int type;
  final Route route;
  final Route? previousRoute;

  bool get isPush => type == 0;
  bool get isPop => type == 1;

  XBStackChangedEvent({
    required this.type,
    required this.route,
    this.previousRoute,
  });
}

class XBSimpleNavigatorObserver extends NavigatorObserver {
  final List<Route> _stack = [];

  int _indexOfRoute(Route route) {
    for (int i = _stack.length - 1; i >= 0; i--) {
      if (identical(_stack[i], route)) {
        return i;
      }
    }
    return -1;
  }

  bool topIsType(Type type, [bool ignore = true]) {
    return _topIsType(type, ignore);
  }

  bool _topIsType(Type type, [bool ignore = true, int? hsCode]) {
    return _topNIsType(type, 0, ignore, hsCode);
  }

  bool _topNIsType(Type type, [int n = 0, bool ignore = true, int? hsCode]) {
    final fixN = 1 + n;
    if (_stack.length < fixN) return false;
    final typeStr = '$type';
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
      final tempRoute = _stack[i];
      if (_isXBRoute(tempRoute) || _isGetRoute(tempRoute)) {
        if (routeIndex < n) {
          routeIndex++;
        } else {
          return _getRouteName(tempRoute) == typeStr &&
              (hsCode == null
                  ? true
                  : _isEqualHashCode(route: tempRoute, hsCode: hsCode));
        }
      }
    }
    return false;
  }

  bool stackContainType(Type type, [int? hsCode]) {
    if (_stack.isEmpty) return false;
    for (int i = _stack.length - 1; i >= 0; i--) {
      final tempRoute = _stack[i];
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

  bool routeIsMapWidget({required Route route, required Widget widget}) {
    return _isXBRoute(route) &&
        _isEqualHashCode(route: route, hsCode: widget.hashCode);
  }

  bool isXBRoute(Route route) {
    return _isXBRoute(route);
  }

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

  bool _isGetRoute(Route route) {
    return '${route.runtimeType}'.startsWith('GetPageRoute');
  }

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

  String _getRouteName(Route route) {
    if (_isXBRoute(route)) {
      return route.settings.name!;
    }
    if (_isGetRoute(route)) {
      return route.settings.name!.replaceFirst('/', '');
    }
    return '';
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    _stack.add(route);
    xbSimpleStackStreamController.add(
      XBStackChangedEvent(type: 0, route: route, previousRoute: previousRoute),
    );
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    final idx = _indexOfRoute(route);
    if (idx >= 0) _stack.removeAt(idx);
    xbSimpleStackStreamController.add(
      XBStackChangedEvent(type: 1, route: route, previousRoute: previousRoute),
    );
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    final idx = _indexOfRoute(route);
    if (idx >= 0) _stack.removeAt(idx);
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (oldRoute == null) {
      if (newRoute != null) _stack.add(newRoute);
      return;
    }
    final idx = _indexOfRoute(oldRoute);
    if (idx < 0) {
      if (newRoute != null) _stack.add(newRoute);
      return;
    }
    if (newRoute == null) {
      _stack.removeAt(idx);
    } else {
      _stack[idx] = newRoute;
    }
  }
}

final XBSimpleNavigatorObserver xbSimpleNavigatorObserver =
    XBSimpleNavigatorObserver();

final StreamController<XBStackChangedEvent>
    _xbSimpleRouteStackStreamController =
    StreamController<XBStackChangedEvent>.broadcast();

StreamController<XBStackChangedEvent> get xbSimpleStackStreamController =>
    _xbSimpleRouteStackStreamController;

Stream<XBStackChangedEvent> get xbSimpleRouteStackStream =>
    _xbSimpleRouteStackStreamController.stream;

final GlobalKey<NavigatorState> xbSimpleNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'xb_simple_router_key');

NavigatorState get xbSimpleNavigatorState {
  final state = xbSimpleNavigatorKey.currentState;
  if (state == null) {
    throw StateError(
      'xbSimpleNavigatorState is not ready. Bind xbSimpleNavigatorKey to your app navigator.',
    );
  }
  return state;
}

Route<T> _buildRoute<T extends Object?>(Widget newPage, [int style = 0]) {
  final routeSetting = RouteSettings(
    name: '${newPage.runtimeType}',
    arguments: {
      xbCategoryNameKey: xbCategoryName,
      xbHashCodeKey: newPage.hashCode,
    },
  );
  if (style == 0) {
    return CupertinoPageRoute<T>(
      settings: routeSetting,
      builder: (context) => newPage,
    );
  }
  return MaterialPageRoute<T>(
    settings: routeSetting,
    builder: (context) => newPage,
  );
}

abstract class XBRouteDriver {
  Future<T?> push<T extends Object?>(Widget newPage, [int style = 0]);
  void pop<O extends Object?>([O? result]);
  Future<T?> replace<T extends Object?>(Widget newPage, [int style = 0]);
  void popToRoot();
  Future<T?> pushAndClearStack<T extends Object?>(Widget newPage,
      [int style = 0]);
  void popUntilType(Type type);
  bool isXBRoute(Route route);
  bool topIsType(Type type);
  bool stackContainType(Type type);
  bool routeIsMapWidget({required Route route, required Widget widget});
}

typedef XBPushFn = Future<Object?> Function(Widget newPage, int style);
typedef XBPopFn = void Function(Object? result);
typedef XBReplaceFn = Future<Object?> Function(Widget newPage, int style);
typedef XBPopToRootFn = void Function();
typedef XBPushAndClearStackFn = Future<Object?> Function(
    Widget newPage, int style);
typedef XBPopUntilTypeFn = void Function(Type type);
typedef XBRouteJudgeFn = bool Function(Route route);
typedef XBTopIsTypeFn = bool Function(Type type);
typedef XBStackContainTypeFn = bool Function(Type type);
typedef XBRouteIsMapWidgetFn = bool Function(
    {required Route route, required Widget widget});

class XBInjectedRouteDriver implements XBRouteDriver {
  final XBPushFn onPush;
  final XBPopFn onPop;
  final XBReplaceFn onReplace;
  final XBPopToRootFn onPopToRoot;
  final XBPushAndClearStackFn onPushAndClearStack;
  final XBPopUntilTypeFn onPopUntilType;
  final XBRouteJudgeFn onIsXBRoute;
  final XBTopIsTypeFn onTopIsType;
  final XBStackContainTypeFn onStackContainType;
  final XBRouteIsMapWidgetFn onRouteIsMapWidget;

  const XBInjectedRouteDriver({
    required this.onPush,
    required this.onPop,
    required this.onReplace,
    required this.onPopToRoot,
    required this.onPushAndClearStack,
    required this.onPopUntilType,
    required this.onIsXBRoute,
    required this.onTopIsType,
    required this.onStackContainType,
    required this.onRouteIsMapWidget,
  });

  @override
  Future<T?> push<T extends Object?>(Widget newPage, [int style = 0]) async {
    final result = await onPush(newPage, style);
    return result as T?;
  }

  @override
  void pop<O extends Object?>([O? result]) => onPop(result);

  @override
  Future<T?> replace<T extends Object?>(Widget newPage, [int style = 0]) async {
    final result = await onReplace(newPage, style);
    return result as T?;
  }

  @override
  void popToRoot() => onPopToRoot();

  @override
  Future<T?> pushAndClearStack<T extends Object?>(Widget newPage,
      [int style = 0]) async {
    final result = await onPushAndClearStack(newPage, style);
    return result as T?;
  }

  @override
  void popUntilType(Type type) => onPopUntilType(type);

  @override
  bool isXBRoute(Route route) => onIsXBRoute(route);

  @override
  bool topIsType(Type type) => onTopIsType(type);

  @override
  bool stackContainType(Type type) => onStackContainType(type);

  @override
  bool routeIsMapWidget({required Route route, required Widget widget}) =>
      onRouteIsMapWidget(route: route, widget: widget);
}

class _XBNavigatorRouteDriver implements XBRouteDriver {
  const _XBNavigatorRouteDriver();

  @override
  Future<T?> push<T extends Object?>(Widget newPage, [int style = 0]) {
    return xbSimpleNavigatorState.push(_buildRoute<T>(newPage, style));
  }

  @override
  void pop<O extends Object?>([O? result]) {
    xbSimpleNavigatorState.pop(result);
  }

  @override
  Future<T?> replace<T extends Object?>(Widget newPage, [int style = 0]) {
    return xbSimpleNavigatorState
        .pushReplacement<T, Object?>(_buildRoute<T>(newPage, style));
  }

  @override
  void popToRoot() {
    xbSimpleNavigatorState.popUntil((route) => route.isFirst);
  }

  @override
  Future<T?> pushAndClearStack<T extends Object?>(Widget newPage,
      [int style = 0]) {
    return xbSimpleNavigatorState.pushAndRemoveUntil<T>(
      _buildRoute<T>(newPage, style),
      (route) => route.isFirst,
    );
  }

  @override
  void popUntilType(Type type) {
    final expected = '$type';
    xbSimpleNavigatorState.popUntil((route) {
      if (route.isFirst) return true;
      final routeName = route.settings.name;
      if (routeName == null || routeName.isEmpty) return false;
      if (routeName == expected || routeName == '/$expected') return true;
      final normalized =
          routeName.startsWith('/') ? routeName.substring(1) : routeName;
      return normalized == expected;
    });
  }

  @override
  bool isXBRoute(Route route) => xbSimpleNavigatorObserver.isXBRoute(route);

  @override
  bool topIsType(Type type) => xbSimpleNavigatorObserver.topIsType(type);

  @override
  bool stackContainType(Type type) =>
      xbSimpleNavigatorObserver.stackContainType(type);

  @override
  bool routeIsMapWidget({required Route route, required Widget widget}) {
    return xbSimpleNavigatorObserver.routeIsMapWidget(
      route: route,
      widget: widget,
    );
  }
}

XBRouteDriver _xbRouteDriver = const _XBNavigatorRouteDriver();

void configureXBRouteDriver(XBRouteDriver driver) {
  _xbRouteDriver = driver;
}

void resetXBRouteDriver() {
  _xbRouteDriver = const _XBNavigatorRouteDriver();
}

XBRouteDriver get xbRouteDriver => _xbRouteDriver;

bool isXBRoute(Route route) => _xbRouteDriver.isXBRoute(route);

bool topIsType(Type type) => _xbRouteDriver.topIsType(type);

bool stackContainType(Type type) => _xbRouteDriver.stackContainType(type);

bool routeIsMapWidget({required Route route, required Widget widget}) =>
    _xbRouteDriver.routeIsMapWidget(route: route, widget: widget);

Future<T?> push<T extends Object?>(Widget newPage, [int style = 0]) =>
    _xbRouteDriver.push<T>(newPage, style);

void pop<O extends Object?>([O? result]) => _xbRouteDriver.pop(result);

Future<T?> replace<T extends Object?>(Widget newPage, [int style = 0]) =>
    _xbRouteDriver.replace<T>(newPage, style);

void popToRoot() => _xbRouteDriver.popToRoot();

Future<T?> pushAndClearStack<T extends Object?>(Widget newPage,
        [int style = 0]) =>
    _xbRouteDriver.pushAndClearStack<T>(newPage, style);

void popUntilType(Type type) => _xbRouteDriver.popUntilType(type);
