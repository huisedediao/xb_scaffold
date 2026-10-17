import 'package:flutter/scheduler.dart';
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
      phase: _schedulerPhase(),
      stack: _stackIfSuspicious(),
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
      phase: _schedulerPhase(),
      stack: _stackIfSuspicious(),
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
      phase: _schedulerPhase(),
      stack: _stackIfSuspicious(),
    );
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    controller.addRoute(
      action: XBUmeRouteAction.replace,
      routeName: newRoute == null ? '<null>' : _routeName(newRoute),
      previousRouteName: oldRoute == null ? null : _routeName(oldRoute),
      phase: _schedulerPhase(),
      stack: _stackIfSuspicious(),
    );
  }

  String _routeName(Route<dynamic> route) {
    return route.settings.name ?? '${route.runtimeType}';
  }

  String _schedulerPhase() {
    try {
      return SchedulerBinding.instance.schedulerPhase.name;
    } catch (_) {
      return 'unknown';
    }
  }

  /// idle = 用户事件/任务直接触发（正常）；其余 phase（build/layout/动画帧中）
  /// 触发路由变更是异常重建的高危来源，记录精简堆栈供定位。
  String? _stackIfSuspicious() {
    if (_schedulerPhase() == SchedulerPhase.idle.name) return null;
    final lines = StackTrace.current
        .toString()
        .split('\n')
        .where((l) => l.contains('.dart'))
        .take(12)
        .toList();
    return lines.isEmpty ? null : lines.join('\n');
  }
}
