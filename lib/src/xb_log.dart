import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

final List<String> _logList = [];
List<String> get logList => _logList;

int get _maxLogLen => maxLogLen ?? 30;

void recordLog(String msg) {
  _logList.insert(0, msg);
  if (_logList.length > _maxLogLen) {
    _logList.removeLast();
  }
}

String logInfo() {
  return _logList.join('\n');
}

showLog() {
  debugPrint("\nxb log ===============================================");
  debugPrint(logInfo());
  debugPrint("===============================================xb log\n");
}
