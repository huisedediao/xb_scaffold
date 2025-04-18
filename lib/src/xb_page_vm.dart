// ignore_for_file: empty_catches, unnecessary_import

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:xb_scaffold/src/utils/xb_import.dart'
    if (dart.library.html) 'package:xb_scaffold/src/utils/xb_import_html.dart';

class XBPageVM<T> extends XBVM<T> with XBLifeCycleMixin {
  XBPageVM({required super.context}) {
    if (_castWidget.needInitLoading(this)) {
      _isShowLoadingWidget = true;
    }
    _addStackListen();
  }

  @override
  void didCreated() {
    super.didCreated();
    final title = (widget as XBPage).setTitle(this);
    if (title.isNotEmpty) {
      _lastHtmlTitle = getDocumentTitle();
      setDocumentTitle(title);
    }
    _pushNotifyAnimationTimer.once(
        duration:
            Duration(milliseconds: _castWidget.pushAnimationMilliseconds(this)),
        onTick: didFinishedPushAnimation);
  }

  final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

  /// 记录上一个网页的标题
  String? _lastHtmlTitle;

  XBPage get _castWidget => widget as XBPage;

  _addStackListen() {
    _stackSubscription = xbRouteStackStream.listen((event) {
      try {
        handleStackChanged(event: event, widget: widget as Widget);
      } catch (e) {
        //
      }
    });
  }

  @mustCallSuper
  didFinishedPushAnimation() {
    _isFinishedPushAnimation = true;
    _executeEnsureAfterPushAnimationTasks();
  }

  /// 添加动画完成后的任务
  addEnsureAfterPushAnimationTask(void Function() fun) {
    XBVoidParamTask task = XBVoidParamTask(execute: fun);
    if (isFinishedPushAnimation) {
      task.run();
    } else {
      _ensureAfterPushAnimationTasks.add(task);
    }
  }

  /// 执行动画完成后的任务
  _executeEnsureAfterPushAnimationTasks() {
    for (var task in _ensureAfterPushAnimationTasks) {
      task.run();
    }
    _ensureAfterPushAnimationTasks.clear();
  }

  /// 确保在动画完成后需要执行的任务
  final List<XBVoidParamTask> _ensureAfterPushAnimationTasks = [];

  /// 是否完成push动画
  bool _isFinishedPushAnimation = false;
  bool get isFinishedPushAnimation => _isFinishedPushAnimation;

  /// push动画定时器
  final XBTimer _pushNotifyAnimationTimer = XBTimer();

  @override
  notify() {
    try {
      if (_castWidget.notifyNeedAfterPushAnimation(this)) {
        if (isFinishedPushAnimation) {
          super.notify();
        } else {
          addEnsureAfterPushAnimationTask(() {
            super.notify();
          });
        }
        return;
      }
      super.notify();
    } catch (e) {
      //
    }
  }

  late StreamSubscription _stackSubscription;

  bool _isShowLoadingWidget = false;

  bool get isShowLoadingWidget => _isShowLoadingWidget;

  GlobalKey<XBFadeWidgetState>? _loadingWidgetFadeKey;

  GlobalKey<XBFadeWidgetState> get loadingWidgetFadeKey {
    _loadingWidgetFadeKey ??= GlobalKey();
    return _loadingWidgetFadeKey!;
  }

  void back<O extends Object?>([O? result]) {
    pop(result);
  }

  String? loadingMsg;

  bool get needShowLoadingWidget {
    try {
      return _castWidget.needLoading(this);
    } catch (e) {
      return false;
    }
  }

  showLoading({String? msg}) {
    loadingMsg = msg;
    try {
      _showLoading();
    } catch (e) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showLoading();
      });
    }
  }

  _showLoading() {
    if (needShowLoadingWidget) {
      if (loadingWidgetFadeKey.currentState == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showLoading();
        });
        return;
      }
      _isShowLoadingWidget = true;
      notify();

      loadingWidgetFadeKey.currentState?.show();
    }
  }

  hideLoading() {
    try {
      if (needShowLoadingWidget) {
        loadingWidgetFadeKey.currentState?.hide(() {
          try {
            _isShowLoadingWidget = false;
            notify();
          } catch (e) {}
        });
      }
    } catch (e) {}
  }

  openDrawer() {
    scaffoldKey.currentState?.openDrawer();
  }

  closeDrawer() {
    scaffoldKey.currentState?.closeDrawer();
  }

  openEndDrawer() {
    scaffoldKey.currentState?.openEndDrawer();
  }

  closeEndDrawer() {
    scaffoldKey.currentState?.closeEndDrawer();
  }

  @override
  void willDispose() {
    super.willDispose();
    if (_lastHtmlTitle != null) {
      setDocumentTitle(_lastHtmlTitle!);
    }
  }

  @override
  void dispose() {
    _stackSubscription.cancel();
    _pushNotifyAnimationTimer.cancel();
    super.dispose();
  }

  /// -------------------- function --------------------
  /// 即将pop
  onWillPop() {
    if (kIsWeb) {
      return _webOnWillPop;
    }
    if (Platform.isAndroid) {
      return _androidOnWillPop;
    } else {
      try {
        if (_castWidget.needIosGestureBack(this) && _canLoadingPop()) {
          return null;
        } else {
          return _iosOnWillPop;
        }
      } catch (e) {
        return null;
      }
    }
  }

  Future<bool> _webOnWillPop() async {
    return true;
  }

  /// ios如果用WillPopScope的onWillPop不为null，则返回手势失效，可以用这个控制iOS是否能够返回
  /// 返回结果无影响，因为只要设置了就不能滑动返回
  Future<bool> _iosOnWillPop() async {
    return false;
  }

  /*
   * 只有 安卓 的 手势返回 操作，这个方法才生效
   * 如果需要控制iOS的滑动返回，在NeedIosGestureUtil中配置
   * */
  Future<bool> _androidOnWillPop() async {
    try {
      return !isShowGoabolLoading &&
          _castWidget.onAndroidPhysicalBack(this) &&
          _canLoadingPop();
    } catch (e) {
      return false;
    }
  }

  /// loading是否允许返回
  bool _canLoadingPop() {
    try {
      return isShowLoadingWidget == false ||
          _castWidget.needResponseNavigationBarLeftWhileLoading(this);
    } catch (e) {
      return true;
    }
  }
}
