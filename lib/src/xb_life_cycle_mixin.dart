import 'package:flutter/material.dart';
import '../xb_scaffold.dart';
import 'xb_navigator_observer.dart';

mixin XBLifeCycleMixin {
  handleStackChanged(
      {required XBStackChangedEvent event, required Widget widget}) {
    if (!isXBRoute(event.route)) {
      // 如果pop或者push的不是XBRoute，不处理
      return;
    }
    if (event.isPush) {
      /// 不能用routeIsMapWidget判断，因为如果是根节点，无法判断
      if (topSecondIsWidget(widget)) {
        willHide();
      }
    } else {
      if (topIsWidget(widget)) {
        willShow();
        return;
      }
      if (routeIsMapWidget(route: event.route, widget: widget)) {
        willDispose();
      }
    }
  }

  /// 即将隐藏，从展示状态变成被覆盖状态
  @mustCallSuper
  void willHide() {
    String log = "$runtimeType willHide";
    debugPrint(log);
    recordLog(log);
  }

  /// 即将展示，从被覆盖状态变成展示状态
  @mustCallSuper
  void willShow() {
    String log = "$runtimeType willShow";
    debugPrint(log);
    recordLog(log);
  }

  /// 即将销毁
  @mustCallSuper
  void willDispose() {
    String log = "$runtimeType willDispose";
    debugPrint(log);
    recordLog(log);
  }
}
