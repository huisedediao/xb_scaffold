typedef XBRefreshTaskFunc = void Function(dynamic params);

class XBRefreshTask {
  final dynamic params;
  final XBRefreshTaskFunc execute;
  XBRefreshTask({required this.params, required this.execute});
}
