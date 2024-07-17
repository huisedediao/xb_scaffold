class XBWaitTask {
  /// true 表示执行task成功
  Future<bool> execute<T>(
      {required Future Function(T) task,
      required T param,
      int milliseconds = 2000}) async {
    Future timeoutTask() async {
      await Future.delayed(Duration(milliseconds: milliseconds));
      return 'Timeout';
    }

    dynamic result = await Future.any([task(param), timeoutTask()]);

    if ('Timeout' == result) {
      return false;
    } else {
      return true;
    }
  }
}
