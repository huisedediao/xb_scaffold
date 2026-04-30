import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

void xbLog(Object info) {
  if (!kDebugMode) return;
  _logger.d('[${DateTime.now().toIso8601String()}] $info');
}

final Logger _logger = Logger(
  printer: PrettyPrinter(
    methodCount: 0,
    errorMethodCount: 8,
    lineLength: 120,
    colors: true,
    printEmojis: true,
  ),
);
