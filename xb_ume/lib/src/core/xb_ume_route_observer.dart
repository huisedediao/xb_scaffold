import 'package:flutter/widgets.dart';

import '../models/xb_ume_route_item.dart';
import 'xb_ume_controller.dart';

class XBUmeRouteObserver extends NavigatorObserver {
  XBUmeRouteObserver(this.controller);

  final XBUmeController controller;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    controller.addRoute(
      action: XBUmeRouteAction.push,
      routeName: _routeName(route),
      previousRouteName:
          previousRoute == null ? null : _routeName(previousRoute),
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    controller.addRoute(
      action: XBUmeRouteAction.pop,
      routeName: _routeName(route),
      previousRouteName:
          previousRoute == null ? null : _routeName(previousRoute),
    );
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    controller.addRoute(
      action: XBUmeRouteAction.remove,
      routeName: _routeName(route),
      previousRouteName:
          previousRoute == null ? null : _routeName(previousRoute),
    );
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    controller.addRoute(
      action: XBUmeRouteAction.replace,
      routeName: newRoute == null ? '<null>' : _routeName(newRoute),
      previousRouteName: oldRoute == null ? null : _routeName(oldRoute),
    );
  }

  String _routeName(Route<dynamic> route) {
    return route.settings.name ?? '${route.runtimeType}';
  }
}
