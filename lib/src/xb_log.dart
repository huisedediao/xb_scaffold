import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

final List<String> _pageLogList = [];
List<String> get pageLogList => _pageLogList;

int get _maxLogLen => maxPageLogLen ?? 30;

void recordPageLog(String msg) {
  DateTime now = DateTime.now();
  var formatter = DateFormat('yyyy-MM-dd HH:mm:ss');
  String formattedTime =
      formatter.format(now.toUtc().add(const Duration(hours: 8)));
  msg = "$msg $formattedTime";
  _pageLogList.insert(0, msg);
  if (_pageLogList.length > _maxLogLen) {
    _pageLogList.removeLast();
  }
}

String pageLogInfo({String separator = '\n'}) {
  return _pageLogList.join(separator);
}

showPageLog() {
  debugPrint("\nxb page log ===============================================");
  debugPrint(pageLogInfo());
  debugPrint("===============================================xb log\n");
}
