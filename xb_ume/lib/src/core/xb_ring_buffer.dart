import 'dart:collection';

class XBRingBuffer<T> {
  XBRingBuffer(this.capacity) : assert(capacity > 0, 'capacity must be > 0');

  final int capacity;
  final Queue<T> _queue = Queue<T>();

  int get length => _queue.length;
  bool get isEmpty => _queue.isEmpty;

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
