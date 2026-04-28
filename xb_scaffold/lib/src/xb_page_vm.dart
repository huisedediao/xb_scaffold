import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBPageVM<T> extends XBVM<T> with RouteAware {
  XBPageVM({required super.context}) {
    if (_castWidget.needInitLoading(context)) {
      _isShowLoadingWidget = true;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    xbRouteObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void didCreated() {
    super.didCreated();
    final title = (widget as XBPage).setTitle(context);
    if (title.isNotEmpty) {
      _lastHtmlTitle = getDocumentTitle();
      setDocumentTitle(title);
    }
    _pushNotifyAnimationTimer.once(
        duration: Duration(
            milliseconds: _castWidget.pushAnimationMilliseconds(context)),
        onTick: didFinishedPushAnimation);
  }

  final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

  /// 页面在栈顶
  bool isTop = false;

  /// 记录上一个网页的标题
  String? _lastHtmlTitle;

  XBPage get _castWidget => widget as XBPage;

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
    if (disposed) return;
    if (_castWidget.notifyNeedAfterPushAnimation(context)) {
      if (isFinishedPushAnimation) {
        super.notify();
      } else {
        addEnsureAfterPushAnimationTask(() {
          if (!disposed) {
            super.notify();
          }
        });
      }
      return;
    }
    super.notify();
  }

  bool _isShowLoadingWidget = false;
  bool _loadingShowScheduled = false;

  bool get isShowLoadingWidget => _isShowLoadingWidget;

  GlobalKey<XBFadeWidgetState>? _loadingWidgetFadeKey;

  GlobalKey<XBFadeWidgetState> get loadingWidgetFadeKey {
    _loadingWidgetFadeKey ??= GlobalKey();
    return _loadingWidgetFadeKey!;
  }

  void back<O extends Object?>([O? result]) {
    xbNavigatorState.pop(result);
  }

  String? loadingMsg;

  bool get needShowLoadingWidget => _castWidget.needLoading(context);

  showLoading({String? msg}) {
    loadingMsg = msg;
    _showLoading();
  }

  void _scheduleShowLoading() {
    if (_loadingShowScheduled || disposed) return;
    _loadingShowScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadingShowScheduled = false;
      if (!disposed) {
        _showLoading();
      }
    });
  }

  _showLoading() {
    if (disposed || !needShowLoadingWidget) return;
    final fadeState = loadingWidgetFadeKey.currentState;
    if (fadeState == null) {
      _scheduleShowLoading();
      return;
    }
    _isShowLoadingWidget = true;
    notify();
    fadeState.show();
  }

  hideLoading() {
    if (disposed || !needShowLoadingWidget) return;
    final fadeState = loadingWidgetFadeKey.currentState;
    if (fadeState == null) {
      _isShowLoadingWidget = false;
      notify();
      return;
    }
    fadeState.hide(() {
      if (disposed) return;
      _isShowLoadingWidget = false;
      notify();
    });
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

  /// 即将隐藏，从展示状态变成被覆盖状态
  @mustCallSuper
  void willHide() {
    String log = "$runtimeType willHide";
    debugPrint(log);
    recordPageLog(log);
  }

  /// 即将展示，从被覆盖状态变成展示状态
  @mustCallSuper
  void willShow() {
    String log = "$runtimeType willShow";
    debugPrint(log);
    recordPageLog(log);
  }

  /// 即将销毁
  @mustCallSuper
  void willDispose() {
    String log = "$runtimeType willDispose";
    debugPrint(log);
    recordPageLog(log);
  }

  // 页面已入栈（可访问 this 和 context）
  @override
  @mustCallSuper
  void didPush() {
    isTop = true;
  }

  /// Called when the current route has been popped off.
  @override
  @mustCallSuper
  void didPop() {
    if (_lastHtmlTitle != null) {
      setDocumentTitle(_lastHtmlTitle!);
    }
    isTop = false;
    willDispose();
  }

  /// Called when a new route has been pushed, and the current route is no
  /// longer visible.
  @override
  @mustCallSuper
  void didPushNext() {
    isTop = false;
    willHide();
  }

  // 上一个页面出栈，当前页面重新可见
  @override
  @mustCallSuper
  void didPopNext() {
    isTop = true;
    willShow();
  }

  @override
  void dispose() {
    xbRouteObserver.unsubscribe(this);
    _pushNotifyAnimationTimer.cancel();
    super.dispose();
  }

  /// -------------------- function --------------------
  /// 即将pop
  onWillPop() {
    if (kIsWeb) {
      return _webOnWillPop;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _androidOnWillPop;

      case TargetPlatform.iOS:
        if (_castWidget.needIosGestureBack(context) && _canLoadingPop()) {
          return null;
        }
        return _iosOnWillPop;

      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return null;

      default:
        if (isHarmony) {
          return _androidOnWillPop;
        }
        return null;
    }
  }

  Future<bool> _webOnWillPop() async {
    return true;
  }

  /// iOS 侧滑返回：当 PopScope 需要拦截返回（canPop=false）时，系统侧滑返回会失效，可通过该逻辑控制
  /// 返回结果无影响，因为只要设置了就不能滑动返回
  Future<bool> _iosOnWillPop() async {
    return false;
  }

  /*
   * 只有 安卓 的 手势返回 操作，这个方法才生效
   * 如果需要控制iOS的滑动返回，在NeedIosGestureUtil中配置
   * */
  Future<bool> _androidOnWillPop() async {
    return !isShowGoabolLoading &&
        _castWidget.onAndroidPhysicalBack(context) &&
        _canLoadingPop();
  }

  /// loading是否允许返回
  bool _canLoadingPop() {
    return isShowLoadingWidget == false ||
        _castWidget.needResponseNavigationBarLeftWhileLoading(context);
  }
}
