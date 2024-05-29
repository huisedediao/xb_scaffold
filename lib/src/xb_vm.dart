import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBVM<T> extends ChangeNotifier {
  final BuildContext context;

  T get widget => context.widget as T;

  late XBWidgetState state;

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
