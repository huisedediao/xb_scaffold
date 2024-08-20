extension XBUniqueList<T> on List<T> {
  /// obj1为新添加的对象（也就是obj），obj2为原来已经存在的对象
  /// 返回值为null，表示为添加
  /// 返回值不为null，表示替换，返回的值为被替换的对象
  T? replaceOrAdd(
      {required T obj, required bool Function(T newObj, T oldObj) equal}) {
    int index = -1;
    for (int i = 0; i < length; i++) {
      T temp = this[i];
      if (equal(obj, temp)) {
        index = i;
        break;
      }
    }
    if (index != -1) {
      T oldObj = this[index];
      this[index] = obj;
      return oldObj;
    } else {
      add(obj);
      return null;
    }
  }

  /// obj1为list中的对象，obj2为原来已经存在的对象
  /// 返回所有被替换掉的对象
  List<T> replaceOrAddAll(
      {required List<T> list,
      required bool Function(T newObj, T oldObj) equal}) {
    List<T> ret = [];
    for (var element in list) {
      final replaceOrAddRet = this.replaceOrAdd(obj: element, equal: equal);
      if (replaceOrAddRet != null) {
        ret.add(replaceOrAddRet);
      }
    }
    return ret;
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

  T? get firstOrNull {
    if (isEmpty) {
      return null;
    } else {
      return first;
    }
  }
}
