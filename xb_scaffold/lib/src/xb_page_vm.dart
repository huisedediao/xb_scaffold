import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBPageVM<T> extends XBVM<T> with RouteAware {
  XBPageVM({required super.context}) {
    // loading 显隐/文案走 ValueNotifier 局部订阅（xb_page 中 ValueListenableBuilder），
    // 变化只重建遮罩子树，不触发整页 rebuild；
    // needInitLoading 在构造期确定，直接作为显隐初值，首帧由 XBFadeWidget.initShow 承担
    isShowLoadingWidgetNotifier =
        createNotifier<bool>(_castWidget.needInitLoading(context));
    loadingMsgNotifier = createNotifier<String?>(null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)!;
    xbRouteObserver.subscribe(this, route);
    // 只绑一次；须在此处而非 didCreated 中调用（ModalRoute.of 依赖 InheritedWidget，
    // initState 期间不可调用），此时 push 转场进行中，监听不会错过 completed
    if (_statusListener == null && !isFinishedPushAnimation) {
      _bindPushAnimation(route);
    }
  }

  @override
  void didCreated() {
    super.didCreated();
    final title = (widget as XBPage).setTitle(context);
    if (title.isNotEmpty) {
      _lastHtmlTitle = getDocumentTitle();
      setDocumentTitle(title);
    }
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

  /// 监听 Route 转场动画的精确结束时机（旧实现为固定定时器猜测）
  Animation<double>? _routeAnimation;
  void Function(AnimationStatus)? _statusListener;

  void _bindPushAnimation(ModalRoute<dynamic> route) {
    final animation = route.animation;

    // 无转场动画，或零时长转场：立即视为完成
    //（ModalRoute 继承自 TransitionRoute，transitionDuration 恒可用）
    if (animation == null || route.transitionDuration == Duration.zero) {
      didFinishedPushAnimation();
      return;
    }

    void listener(AnimationStatus status) {
      if (status == AnimationStatus.completed) {
        // 转场真正结束：精确触发排队任务
        _unbindPushAnimation();
        didFinishedPushAnimation();
      } else if (status == AnimationStatus.dismissed) {
        // 转场被打断回退（如手势返回取消 push），页面即将 pop，
        // 排队任务随 VM 销毁废弃，不再执行
        _unbindPushAnimation();
      }
    }

    _statusListener = listener;
    _routeAnimation = animation;
    animation.addStatusListener(listener);

    // 不能在绑定时读 isCompleted：路由 install 阶段 animation 是指向
    // kAlwaysCompleteAnimation 的占位 ProxyAnimation（永远 completed），
    // 真正的转场 controller 稍后才挂上，会误判正常转场为已完成。
    // 故延迟到下一帧，此时占位已被替换，status 反映真实动画状态；
    // 用于兜底绑定前动画已真正完成的极端场景（如首帧极度延迟）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_statusListener == listener &&
          !isFinishedPushAnimation &&
          animation.status == AnimationStatus.completed) {
        _unbindPushAnimation();
        didFinishedPushAnimation();
      }
    });
  }

  void _unbindPushAnimation() {
    if (_routeAnimation != null && _statusListener != null) {
      _routeAnimation!.removeStatusListener(_statusListener!);
    }
    _routeAnimation = null;
    _statusListener = null;
  }

  @override
  notify() {
    if (!mounted) return;
    if (_castWidget.notifyNeedAfterPushAnimation(context)) {
      if (isFinishedPushAnimation) {
        super.notify();
      } else {
        addEnsureAfterPushAnimationTask(() {
          if (mounted) {
            super.notify();
          }
        });
      }
      return;
    }
    super.notify();
  }

  /// loading 遮罩显隐（页面级）。UI 用 ValueListenableBuilder 局部订阅，
  /// 高频显隐不经过 [notify]，避免整页重建
  late final ValueNotifier<bool> isShowLoadingWidgetNotifier;

  /// loading 提示文案，同上走局部订阅
  late final ValueNotifier<String?> loadingMsgNotifier;

  bool get isShowLoadingWidget => isShowLoadingWidgetNotifier.value;

  String? get loadingMsg => loadingMsgNotifier.value;

  void _setLoadingVisible(bool visible) {
    if (isShowLoadingWidgetNotifier.value == visible) return;
    isShowLoadingWidgetNotifier.value = visible;
  }

  bool _loadingShowScheduled = false;

  GlobalKey<XBFadeWidgetState>? _loadingWidgetFadeKey;

  GlobalKey<XBFadeWidgetState> get loadingWidgetFadeKey {
    _loadingWidgetFadeKey ??= GlobalKey();
    return _loadingWidgetFadeKey!;
  }

  void back<O extends Object?>([O? result]) {
    xbNavigatorState.maybePop(result);
  }

  bool get needShowLoadingWidget => _castWidget.needLoading(context);

  showLoading({String? msg}) {
    if (!mounted || !needShowLoadingWidget) return;
    final msgChanged = loadingMsgNotifier.value != msg;
    loadingMsgNotifier.value = msg;
    // 已在显示且文案未变时早退，避免无谓的动画重启与重建
    if (!msgChanged && isShowLoadingWidget) return;
    _showLoading();
  }

  void _scheduleShowLoading() {
    if (_loadingShowScheduled || !mounted) return;
    _loadingShowScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadingShowScheduled = false;
      if (mounted) {
        _showLoading();
      }
    });
  }

  _showLoading() {
    if (!mounted || !needShowLoadingWidget) return;
    final fadeState = loadingWidgetFadeKey.currentState;
    if (fadeState == null) {
      _scheduleShowLoading();
      return;
    }
    _setLoadingVisible(true);
    fadeState.show();
  }

  hideLoading() {
    if (!mounted || !needShowLoadingWidget) return;
    // 未显示早退
    if (!isShowLoadingWidget) return;
    final fadeState = loadingWidgetFadeKey.currentState;
    if (fadeState == null) {
      _setLoadingVisible(false);
      return;
    }
    fadeState.hide(() {
      if (!mounted) return;
      _setLoadingVisible(false);
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
    _unbindPushAnimation();
    super.dispose();
  }
}
