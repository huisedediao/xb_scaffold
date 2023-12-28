// typedef XBUniqueListEqual<O> = bool Function<O>(O obj1, O obj2);

class XBUniqueList<T> {
  final List<T> _list = [];

  add({required T obj}) {
    _list.add(obj);
  }

  /// 返回1 ：替换；返回0：添加
  int replaceOrAdd({required T obj, required bool equal(T obj1, T obj2)}) {
    int index = -1;
    for (int i = 0; i < _list.length; i++) {
      T temp = _list[i];
      if (equal(obj, temp)) {
        index = i;
        break;
      }
    }
    if (index != -1) {
      _list[index] = obj;
      return 1;
    } else {
      _list.add(obj);
      return 0;
    }
  }

  addAll(List<T> list) {
    _list.addAll(list);
  }

  replaceOrAddAll(
      {required List<T> list, required bool Function(T obj1, T obj2) equal}) {
    for (var element in list) {
      replaceOrAdd(obj: element, equal: equal);
    }
  }

  Iterable<E> map<E>(E Function(T e) toElement) {
    return _list.map(toElement);
  }

  /// 如果返回true，则停止遍历
  forEach(bool Function(T e) element) {
    for (int i = 0; i < _list.length; i++) {
      bool end = element(_list[i]);
      if (end) {
        break;
      }
    }
  }

  bool remove(T obj) {
    return _list.remove(obj);
  }

  T removeAt(int index) {
    return _list.removeAt(index);
  }

  clear() {
    _list.clear();
  }

  int get length {
    return _list.length;
  }

  T get(int index) {
    return _list[index];
  }

  T operator [](int index) {
    return _list[index];
  }

  bool get isEmpty => _list.isEmpty;

  bool get isNotEmpty => _list.isNotEmpty;

  void operator []=(int index, T value) {
    if (index < 0 || index >= _list.length) {
      throw ArgumentError('index 不合法');
    } else {
      _list[index] = value;
    }
  }
}
