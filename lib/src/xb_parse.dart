// 通用的解析方法，使用泛型T来决定返回值类型
T? xbParse<T>(dynamic object, [int trueValue = 1]) {
  if (object == null) return null;

  try {
    if (T == int) {
      return int.tryParse(object.toString()) as T?;
    } else if (T == double) {
      return double.tryParse(object.toString()) as T?;
    } else if (T == String) {
      return object.toString() as T?;
    } else if (T == bool) {
      if (object is bool) {
        return object as T?;
      }
      final temp = xbParse<int>(object);
      return (temp == trueValue) as T?;
    }
  } catch (e) {
    return null;
  }
  return null;
}

// 通用的解析列表方法，使用泛型T来决定列表元素类型
List<T>? xbParseList<T>(dynamic object, [int trueValue = 1]) {
  if (object == null || (object is List) == false) return null;

  List<T> ret = [];
  try {
    for (var item in object) {
      T? value = xbParse<T>(item, trueValue);
      if (value != null) {
        ret.add(value);
      }
    }
    return ret;
  } catch (e) {
    return null;
  }
}
