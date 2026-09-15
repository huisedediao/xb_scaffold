import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBVM<T> extends ChangeNotifier {
  final BuildContext context;

  T get widget => context.widget as T;

  late XBWidgetState state;

  XBRepository? _repo;

  R? repo<R extends XBRepository>() => _repo as R?;

  void setRepo(XBRepository? value) {
    _repo?.dispose();
    _repo = value;
    _repo?.init();
  }

  Size _widgetSize = Size.zero;
  Size get widgetSize => _widgetSize;

  bool _widgetSizeCallbackScheduled = false;

  /// 更新布局尺寸（框架由 LayoutBuilder 调用，业务方一般无需手动调用），
  /// [widgetSizeDidChanged] 回调延迟到当前帧结束后触发。
  ///
  /// 更新发生在 LayoutBuilder 的 build 期，若同步触发回调，
  /// 业务方在回调里调 notify() 会触发
  /// "setState() or markNeedsBuild() called during build" 断言。
  /// 同一帧内多次尺寸变化合并为一次回调。
  void updateWidgetSize(Size newValue) {
    if (_widgetSize == newValue) {
      return;
    }
    _widgetSize = newValue;
    if (_widgetSizeCallbackScheduled) {
      return;
    }
    _widgetSizeCallbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _widgetSizeCallbackScheduled = false;
      if (mounted) {
        widgetSizeDidChanged();
      }
    });
  }

  /// 保持兼容：等价于 [updateWidgetSize]，回调同样延迟到帧结束后触发
  set widgetSize(Size newValue) => updateWidgetSize(newValue);

  /// 布局尺寸变化回调（帧结束后触发，一帧内多次变化合并为一次）
  void widgetSizeDidChanged() {}

  XBVM({required this.context});

  bool _disposed = false;
  bool get disposed => _disposed;

  /// VM 及其宿主 Widget 是否仍然存活（与 State.mounted 对齐）
  /// 异步回调（网络请求、Future.delayed 等）中访问 context/state 前，
  /// 应先检查此属性，避免页面销毁后使用悬空的 context
  /// ```dart
  /// await api.fetch();
  /// if (!mounted) return;
  /// notify();
  /// ```
  bool get mounted => !disposed && state.mounted;

  /// 已经完成创建
  @mustCallSuper
  void didCreated() {
    String log = "$runtimeType didCreated";
    debugPrint(log);
    recordPageLog(log);
  }

  /// 页面已经build完成
  @mustCallSuper
  void widgetDidBuilt() {
    String log = "$runtimeType pageDidBuilt";
    debugPrint(log);
    recordPageLog(log);
  }

  /// 通知刷新
  notify() {
    if (!mounted) return;
    notifyListeners();
  }

  /// VM 托管的 ValueNotifier 列表，dispose 时统一销毁
  final List<ValueNotifier> _ownedNotifiers = [];

  /// 创建由 VM 托管生命周期的 ValueNotifier（大页面性能优化）
  ///
  /// 倒计时、进度条、动画值这类每帧/每秒变化的高频值，不要放进普通字段
  /// 走 `notify()`（每次 notify 都会重建整个 buildWidget），应使用本方法
  /// 创建 notifier，UI 侧用 `ValueListenableBuilder` 局部订阅，更新时
  /// 只重建订阅该值的 builder，完全绕开 VM notify。
  ///
  /// ```dart
  /// // VM 中：
  /// late final secondsLeft = createNotifier<int>(60);
  /// // UI 中：
  /// ValueListenableBuilder<int>(
  ///   valueListenable: vm.secondsLeft,
  ///   builder: (context, s, _) => Text('$s s'),
  /// )
  /// ```
  ///
  /// VM dispose 时自动销毁创建的 notifier，无需手动清理。
  ValueNotifier<V> createNotifier<V>(V initial) {
    final notifier = ValueNotifier<V>(initial);
    _ownedNotifiers.add(notifier);
    return notifier;
  }

  /// 保管 listen 注册的事件回调，防止被 GC 回收
  /// （XBEventBus 为弱注册，回调须由 listener 自己持有）
  final List<Function> _retainedHandlers = [];

  listen<E>(Function(E) onData) {
    _retainedHandlers.add(onData);
    XBEventBus.addListener<E>(this, onData);
  }

  /// 移除由 [listen] 注册的回调（从保管列表中移除，并注销事件总线）
  void removeListen<E>(Function(E) onData) {
    _retainedHandlers.remove(onData);
    XBEventBus.removeListener(this);
  }

  @mustCallSuper
  void didChangeDependencies() {}

  @mustCallSuper
  void didUpdateWidget(covariant T oldWidget) {}

  @override
  void dispose() {
    _disposeOwnedNotifiers();
    _repo?.dispose();
    String log = "$runtimeType dispose";
    debugPrint(log);
    recordPageLog(log);
    XBEventBus.removeListener(this);
    _retainedHandlers.clear();
    _disposed = true;
    super.dispose();
  }

  /// 销毁由 [createNotifier] 托管的 notifier（先于 super.dispose，
  /// 避免监听方在 VM dispose 后收到已销毁 notifier 的通知）
  void _disposeOwnedNotifiers() {
    for (final notifier in _ownedNotifiers) {
      notifier.dispose();
    }
    _ownedNotifiers.clear();
  }
}
