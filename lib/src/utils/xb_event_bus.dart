import 'dart:async';

class XBEventBus {
  static final Map<dynamic, List<StreamSubscription>> _map = {};
  static final _controller = StreamController<dynamic>.broadcast();

  static void fire(dynamic event) {
    _controller.add(event);
  }

  static Stream<dynamic> on<T>() {
    return _controller.stream.where((event) => event is T);
  }

  static void addListener<T>(dynamic listener, Function(T data) onData) {
    final subscription = on<T>().listen((event) {
      onData(event);
    });
    _map[listener] ??= [];
    _map[listener]!.add(subscription);
  }

  /// 如果listener是XBVM类型，可以不调用removeListener
  static void removeListener(dynamic listener) {
    if (_map.containsKey(listener)) {
      for (StreamSubscription element in _map[listener] ?? []) {
        element.cancel();
      }
      _map.remove(listener);
    }
  }

  // static void destroy() {
  //   _controller.close();
  // }
}
