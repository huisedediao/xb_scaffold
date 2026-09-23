import 'package:flutter/widgets.dart';

import '../core/xb_track_manager.dart';

/// 页面序列采集：标准 [NavigatorObserver]，零生态依赖。
///
/// 用法：
/// ```dart
/// final routeTracker = XBRouteTracker();
/// MaterialApp(navigatorObservers: [routeTracker], ...)
/// ```
///
/// 产出 `page_enter` / `page_exit`（含 durationMs 停留时长）事件，
/// 与 auto_click 同一时间轴，天然构成操作路径序列。
///
/// 非标准路由（自研路由等）可用 [reportEnter]/[reportExit] 手动兜底。
class XBRouteTracker extends NavigatorObserver {
  XBRouteTracker({
    this.enterEvent = 'page_enter',
    this.exitEvent = 'page_exit',
  });

  /// 进入页面事件名。
  final String enterEvent;

  /// 离开页面事件名。
  final String exitEvent;

  String? _currentPage;
  int? _currentPageEnterAtMs;

  /// 当前页面名（未进入任何页面时为 null）。
  String? get currentPage => _currentPage;

  String _pageNameOf(Route<dynamic> route) {
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    // 未命名路由降级为路由类型名，保证事件可区分。
    return route.runtimeType.toString();
  }

  void _handleEnter(String pageName) {
    _currentPage = pageName;
    _currentPageEnterAtMs = DateTime.now().millisecondsSinceEpoch;
    _track(enterEvent, pageName);
  }

  void _handleExit(String pageName) {
    final enterAt = _currentPageEnterAtMs;
    final durationMs =
        enterAt == null ? null : DateTime.now().millisecondsSinceEpoch - enterAt;
    _track(exitEvent, pageName, durationMs: durationMs);
    _currentPage = null;
    _currentPageEnterAtMs = null;
  }

  void _track(String event, String pageName, {int? durationMs}) {
    try {
      XBTrackManager.shared.track(
        event,
        pageName: pageName,
        params: <String, dynamic>{
          'pageName': pageName,
          if (durationMs != null) 'durationMs': durationMs,
        },
      );
    } catch (_) {
      // 采集异常不影响导航。
    }
  }

  /// 手动兜底：进入页面（自研路由、无 navigatorObservers 可挂时使用）。
  void reportEnter(String pageName) => _handleEnter(pageName);

  /// 手动兜底：离开页面。
  void reportExit(String pageName) => _handleExit(pageName);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (previousRoute != null) {
      _handleExit(_pageNameOf(previousRoute));
    }
    _handleEnter(_pageNameOf(route));
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _handleExit(_pageNameOf(route));
    if (previousRoute != null) {
      _handleEnter(_pageNameOf(previousRoute));
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (oldRoute != null) {
      _handleExit(_pageNameOf(oldRoute));
    }
    if (newRoute != null) {
      _handleEnter(_pageNameOf(newRoute));
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _handleExit(_pageNameOf(route));
    if (previousRoute != null) {
      _handleEnter(_pageNameOf(previousRoute));
    }
  }
}
