import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

final List<String> _pageLogList = [];
List<String> get pageLogList => _pageLogList;

int get _maxLogLen => maxPageLogLen ?? 30;

void recordPageLog(String msg) {
  _pageLogList.insert(0, msg);
  if (_pageLogList.length > _maxLogLen) {
    _pageLogList.removeLast();
  }
}

String pageLogInfo() {
  return _pageLogList.join('\n');
}

showPageLog() {
  debugPrint("\nxb page log ===============================================");
  debugPrint(pageLogInfo());
  debugPrint("===============================================xb log\n");
}
