enum XBUmeRouteAction {
  push,
  pop,
  replace,
  remove,
}

class XBUmeRouteItem {
  XBUmeRouteItem({
    required this.id,
    required this.time,
    required this.action,
    required this.routeName,
    this.previousRouteName,
    this.phase = 'unknown',
    this.stack,
  });

  final String id;
  final DateTime time;
  final XBUmeRouteAction action;
  final String routeName;
  final String? previousRouteName;

  /// 事件触发时的 SchedulerPhase（idle=事件/任务触发，
  /// persistentCallbacks=build/layout 中触发，transientCallbacks=动画帧中触发）。
  /// 用于排查「layout 阶段触发路由变更」导致的重建异常。
  final String phase;

  /// phase 非 idle 时的精简调用堆栈（定位是谁在 build/layout 中触发了路由操作）。
  final String? stack;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'time': time.toIso8601String(),
      'action': action.name,
      'routeName': routeName,
      'previousRouteName': previousRouteName,
      'phase': phase,
      if (stack != null) 'stack': stack,
    };
  }

  factory XBUmeRouteItem.fromJson(Map<String, dynamic> json) {
    return XBUmeRouteItem(
      id: json['id'] as String? ?? '',
      time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
      action: XBUmeRouteAction.values.firstWhere(
        (e) => e.name == json['action'],
        orElse: () => XBUmeRouteAction.push,
      ),
      routeName: json['routeName'] as String? ?? '',
      previousRouteName: json['previousRouteName'] as String?,
      phase: json['phase'] as String? ?? 'unknown',
      stack: json['stack'] as String?,
    );
  }
}
