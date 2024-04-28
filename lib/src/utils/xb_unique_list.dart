extension XBUniqueList<T> on List<T> {
  int replaceOrAdd(
      {required T obj, required bool Function(T obj1, T obj2) equal}) {
    int index = -1;
    for (int i = 0; i < length; i++) {
      T temp = this[i];
      if (equal(obj, temp)) {
        index = i;
        break;
      }
    }
    if (index != -1) {
      this[index] = obj;
      return 1;
    } else {
      add(obj);
      return 0;
    }
  }

  replaceOrAddAll(
      {required List<T> list, required bool Function(T obj1, T obj2) equal}) {
    for (var element in list) {
      this.replaceOrAdd(obj: element, equal: equal);
    }
  }

  /// 如果返回true，则停止遍历
  forEachCanBreak(bool Function(T e) element) {
    for (int i = 0; i < length; i++) {
      bool end = element(this[i]);
      if (end) {
        break;
      }
    }
  }

  T? firstWhereOrNull(bool Function(T element) test) {
    for (T element in this) {
      if (test(element)) return element;
    }
    return null;
  }

  T? lastWhereOrNull(bool Function(T element) test) {
    var iterator = this.iterator;
    // Potential result during first loop.
    T result;
    do {
      if (!iterator.moveNext()) {
        return null;
      }
      result = iterator.current;
    } while (!test(result));
    // Now `result` is actual result, unless a later one is found.
    while (iterator.moveNext()) {
      var current = iterator.current;
      if (test(current)) result = current;
    }
    return result;
  }
}
