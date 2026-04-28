class XBWaitTask {
  static String timeout = "XBWaitTask_Timeout";
  static String paramErr = "XBWaitTask_ParamErr";

  /// true 表示执行task成功
  Future<dynamic> execute<T>(
      {required dynamic task,
      required T param,
      int milliseconds = 2000}) async {
    List<Future<dynamic>> tasks = [];
    if (task is Future Function(T)) {
      tasks.add(task(param));
    } else if (task is Future Function()) {
      tasks.add(task());
    } else {
      return paramErr;
    }
    Future timeoutTask() async {
      await Future.delayed(Duration(milliseconds: milliseconds));
      return timeout;
    }

    tasks.add(timeoutTask());
    dynamic result = await Future.any(tasks);
    return result;
  }
}
