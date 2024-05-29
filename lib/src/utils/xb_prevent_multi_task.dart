class XBPreventMultiTask {
  final int intervalMilliseconds;
  XBPreventMultiTask({required this.intervalMilliseconds});
  DateTime _dateTime = DateTime.now();

  execute(void Function() task) {
    final now = DateTime.now();
    if (now.difference(_dateTime).inMilliseconds > intervalMilliseconds) {
      task();
      _dateTime = now;
    }
  }
}
