import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

final List<String> _pageLogList = [];
List<String> get pageLogList => _pageLogList;

int get _maxLogLen => maxPageLogLen ?? 30;

void recordPageLog(String msg) {
  // 使用设备本地时间：海外/非东八区设备也能得到正确时间戳
  //（旧实现 toUtc().add(hours: 8) 硬编码东八区，海外项目时间戳错误）
  DateTime now = DateTime.now();
  const formatter = XBDateFormat('yyyy-MM-dd HH:mm:ss');
  String formattedTime = formatter.format(now);
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
