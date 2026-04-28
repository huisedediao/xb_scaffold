import 'dart:async';

class XBEventBus {
  static final Map<dynamic, List<StreamSubscription>> _map = {};
  static StreamController? _controller;
  static StreamController get controller {
    _controller ??= StreamController<dynamic>.broadcast();
    return _controller!;
  }

  static void setController(StreamController controller) {
    _controller ??= controller;
  }

  static void fire(dynamic event) {
    controller.add(event);
  }

  static Stream<T> on<T>() {
    if (T == dynamic) {
      return controller.stream as Stream<T>;
    } else {
      return controller.stream.where((event) => event is T).cast<T>();
    }
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
