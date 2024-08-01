typedef XBTaskFunc = void Function(dynamic params);

class XBTask {
  final dynamic params;
  final XBTaskFunc execute;
  XBTask({required this.params, required this.execute});

  run() {
    execute(params);
  }
}

class XBVoidParamTask {
  final void Function() execute;
  XBVoidParamTask({required this.execute});

  run() {
    execute();
  }
}
