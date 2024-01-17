import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBNavigatorObserver extends NavigatorObserver {
  final List<Route> _stack = [];

  bool get topIsXBRoute {
    final arg = _stack.last.settings.arguments;
    if (arg == null || arg is! Map) {
      return false;
    }
    final tempName = arg[xbCategoryNameKey];
    return tempName != null && tempName is String && tempName == xbCategoryName;
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    _stack.add(route);
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    super.didPop(route, previousRoute);
    _stack.remove(route);
  }
}
