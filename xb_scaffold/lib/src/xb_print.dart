import 'package:flutter/foundation.dart';

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
  final message = '$_ansiReset${type._ansiColor}[$timestamp] $info$_ansiReset';
  switch (type) {
    case _XBPrintType.log:
    case _XBPrintType.debug:
    case _XBPrintType.error:
    case _XBPrintType.info:
    case _XBPrintType.warn:
      if (kDebugMode) {
        debugPrint(message);
      }
      return;
    case _XBPrintType.unDisappear:
    case _XBPrintType.fatal:
      debugPrint(message);
      return;
  }
}

const _ansiReset = '\x1B[0m';

enum _XBPrintType {
  log(''),
  error('\x1B[31m'),
  unDisappear('\x1B[31m'),
  debug(''),
  info('\x1B[34m'),
  warn('\x1B[33m'),
  fatal('\x1B[31m');

  final String _ansiColor;
  const _XBPrintType(this._ansiColor);
}
