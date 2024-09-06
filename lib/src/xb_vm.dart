import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBVM<T> extends ChangeNotifier {
  final BuildContext context;

  T get widget => context.widget as T;

  late XBWidgetState state;

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
    try {
      notifyListeners();
      // ignore: empty_catches
    } catch (e) {}
  }

  listen<E>(Function(E) onData) {
    XBEventBus.addListener<E>(this, onData);
  }

  @mustCallSuper
  void didChangeDependencies() {}

  @mustCallSuper
  void didUpdateWidget(covariant T oldWidget) {}

  @override
  void dispose() {
    String log = "$runtimeType dispose";
    debugPrint(log);
    recordPageLog(log);
    XBEventBus.removeListener(this);
    _disposed = true;
    super.dispose();
  }
}
