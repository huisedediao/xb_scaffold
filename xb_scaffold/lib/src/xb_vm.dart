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
  set widgetSize(Size newValue) {
    if (_widgetSize == newValue) {
      return;
    }
    _widgetSize = newValue;
    widgetSizeDidChanged();
  }

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
    _repo?.dispose();
    String log = "$runtimeType dispose";
    debugPrint(log);
    recordPageLog(log);
    XBEventBus.removeListener(this);
    _retainedHandlers.clear();
    _disposed = true;
    super.dispose();
  }
}
