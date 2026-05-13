import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

const int _maxChunkLen = 800;

void xbError(Object info) {
  _handleInfo(info, _XBPrintType.error);
}

void xbLog(Object info) {
  _handleInfo(info, _XBPrintType.log);
}

void xbUnDisappear(Object info) {
  _handleInfo(info, _XBPrintType.unDisappear);
}

void xbDebug(Object info) {
  _handleInfo(info, _XBPrintType.debug);
}

void xbInfo(Object info) {
  _handleInfo(info, _XBPrintType.info);
}

void xbWarn(Object info) {
  _handleInfo(info, _XBPrintType.warn);
}

void xbFatal(Object info) {
  _handleInfo(info, _XBPrintType.fatal);
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
));

void _handleInfo(Object info, [_XBPrintType type = _XBPrintType.log]) {
  final infoStr = info.toString();
  var index = 0;
  while ((infoStr.length - index * _maxChunkLen) > _maxChunkLen) {
    final subStr = infoStr.substring(
      index * _maxChunkLen,
      index * _maxChunkLen + _maxChunkLen,
    );
    _print(subStr, type);
    index += 1;
  }
  if ((infoStr.length - index * _maxChunkLen) > 0) {
    final subStr = infoStr.substring(index * _maxChunkLen);
    _print(subStr, type);
  }
}

void _print(Object info, _XBPrintType type) {
  final timestamp = DateTime.now().toIso8601String();
  final message = '[$timestamp] $info';
  switch (type) {
    case _XBPrintType.log:
    case _XBPrintType.debug:
      if (kDebugMode) {
        _logger.d(message);
      }
      return;
    case _XBPrintType.error:
      if (kDebugMode) {
        _logger.e(message);
      }
      return;
    case _XBPrintType.unDisappear:
      _logger.e(message);
      return;
    case _XBPrintType.info:
      if (kDebugMode) {
        _logger.i(message);
      }
      return;
    case _XBPrintType.warn:
      if (kDebugMode) {
        _logger.w(message);
      }
      return;
    case _XBPrintType.fatal:
      _logger.f(message);
      return;
  }
}

enum _XBPrintType {
  log,
  error,
  unDisappear,
  debug,
  info,
  warn,
  fatal,
}
