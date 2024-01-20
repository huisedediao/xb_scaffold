extension XBStackList<T> on List<T> {
  void push(T value) => add(value);

  T get pop => removeLast();

  T get top => last;
}
