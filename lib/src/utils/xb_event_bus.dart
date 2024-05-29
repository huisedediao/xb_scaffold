import 'dart:async';

class XBEventBus {
  // 事件通道
  static final _controller = StreamController<dynamic>.broadcast();

  // 发送事件
  static void fire(dynamic event) {
    _controller.add(event);
  }

  // 监听事件
  static Stream<dynamic> on<T>() {
    return _controller.stream.where((event) => event is T);
  }

  // 关闭事件通道
  // static void destroy() {
  //   _controller.close();
  // }
}
