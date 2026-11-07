// 直连会话的路由栈（`/v1/route/stack`）。
//
// release 包没有 VM，读不到 `NavigatorState._history`；能拿到的只有 app 内
// `XBUmeRouteObserver` 记录的 push / pop / replace / remove 事件。这里按事件
// 重放出一个**近似栈**，并明确标注 `approx`——调用方不得把它当成真实栈
// （尤其是依赖 `route.isCurrent` / `isPresent` 的判断）。
//
// 源码定位（locate）在直连下是启发式：用路由名推类名，再到本机项目源码里找
// 声明，由 IDE 侧完成（`srclocate:heuristic`）。
library;

import '../core/xb_ume_controller.dart';
import '../models/xb_ume_route_item.dart';

/// 重放事件流得到的近似路由栈（栈底 → 栈顶）。
List<String> replayRouteStack(Iterable<XBUmeRouteItem> events) {
  final stack = <String>[];
  for (final e in events) {
    switch (e.action) {
      case XBUmeRouteAction.push:
        stack.add(e.routeName);
      case XBUmeRouteAction.pop:
      case XBUmeRouteAction.remove:
        _removeTopmost(stack, e.routeName);
      case XBUmeRouteAction.replace:
        final old = e.previousRouteName;
        if (old != null && old.isNotEmpty) {
          final at = stack.lastIndexOf(old);
          if (at >= 0) {
            stack[at] = e.routeName;
            break;
          }
        }
        stack.add(e.routeName);
    }
  }
  return stack;
}

/// 移除栈里最靠上的同名路由（同名多次 push 时只弹最后那层）。
void _removeTopmost(List<String> stack, String name) {
  final at = stack.lastIndexOf(name);
  if (at >= 0) {
    stack.removeAt(at);
    return;
  }
  // 名字对不上（如路由被 replace 过）：退化成弹栈顶。
  if (stack.isNotEmpty) stack.removeLast();
}

/// `/v1/route/stack` 的响应：形状对齐 GUI `/api/routestack`，另带事件视界。
Map<String, Object?> agentRouteStackJson(
  XBUmeController controller, {
  int eventLimit = 50,
}) {
  final events = controller.routes;
  final stack = replayRouteStack(events);
  final recent = events.length <= eventLimit
      ? events
      : events.sublist(events.length - eventLimit);
  return <String, Object?>{
    'ok': true,
    'approx': true,
    'navigators': <Map<String, Object?>>[
      <String, Object?>{
        'index': 0,
        'approx': true,
        'routes': <Map<String, Object?>>[
          for (var i = 0; i < stack.length; i++)
            <String, Object?>{
              'name': stack[i],
              'type': '事件近似',
              'args': '',
              'current': i == stack.length - 1,
            },
        ],
      },
    ],
    'events': <Map<String, Object?>>[
      for (final e in recent)
        <String, Object?>{
          'action': e.action.name,
          'routeName': e.routeName,
          if (e.previousRouteName != null) 'previousRouteName': e.previousRouteName,
          'time': e.time.toIso8601String(),
        },
    ],
    'note': '直连会话没有 Navigator 内部栈：这里按路由事件重放近似，'
        '顺序与真实栈可能有偏差（op 改栈、读 isPresent 仍需 VM）',
  };
}

