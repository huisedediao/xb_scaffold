import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

xbError(Object info) {
  _handleInfo(info, 1);
}

xbLog(Object info) {
  _handleInfo(info, 0);
}

xbUnDisappear(Object info) {
  _handleInfo(info, 2);
}

final Logger _logger = Logger(
    printer: PrettyPrinter(
        methodCount: 0,
        // number of method calls to be displayed
        errorMethodCount: 8,
        // number of method calls if stacktrace is provided
        lineLength: 120,
        // width of the output
        colors: true,
        // Colorful log messages
        printEmojis: true,
        // Print an emoji for each log message
        printTime: false // Should each log print contain a timestamp
        ));

_handleInfo(Object info, [int type = 0]) {
  int maxLen = 800;
  String infoStr = info.toString();
  int index = 0;
  while ((infoStr.length - index * maxLen) > maxLen) {
    String subStr = infoStr.substring(index * maxLen, index * maxLen + maxLen);
    _print(subStr, type);
    index++;
  }
  if ((infoStr.length - index * maxLen) > 0) {
    String subStr = infoStr.substring(index * maxLen);
    _print(subStr, type);
  }
}

void _print(Object info, int type) {
  String timestamp = DateTime.now().toIso8601String();
  String message = '[$timestamp] $info';
  if (type == 0) {
    if (kDebugMode) {
      _logger.d(message);
    }
  } else if (type == 1) {
    if (kDebugMode) {
      _logger.e(message);
    }
  } else {
    _logger.e(message);
  }
}
