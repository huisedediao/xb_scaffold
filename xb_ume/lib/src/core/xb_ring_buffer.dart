import 'dart:collection';

class XBRingBuffer<T> {
  XBRingBuffer(this.capacity) : assert(capacity > 0, 'capacity must be > 0');

  final int capacity;
  final Queue<T> _queue = Queue<T>();

  int get length => _queue.length;
  bool get isEmpty => _queue.isEmpty;

  /// 最近加入的元素（为空时返回 null）。
  T? get last => _queue.isEmpty ? null : _queue.last;

  /// 原地替换最近加入的元素（异常去重合并计数用）。
  void replaceLast(T value) {
    if (_queue.isEmpty) {
      add(value);
      return;
    }
    _queue.removeLast();
    _queue.addLast(value);
  }

  void add(T value) {
    _queue.addLast(value);
    while (_queue.length > capacity) {
      _queue.removeFirst();
    }
  }

  void addAll(Iterable<T> values) {
    for (final value in values) {
      add(value);
    }
  }

  void clear() {
    _queue.clear();
  }

  List<T> toList({bool growable = false}) {
    return List<T>.from(_queue, growable: growable);
  }
}
