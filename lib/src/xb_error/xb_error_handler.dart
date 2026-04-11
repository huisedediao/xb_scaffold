import 'dart:async';
import 'dart:isolate';
import 'package:flutter/material.dart';

import 'xb_error_view.dart';

typedef XBErrorReporter = FutureOr<void> Function(
  Object error,
  StackTrace? stackTrace,
);

class XBErrorHandler {
  XBErrorHandler._();

  static XBErrorReporter? _reporter;
  static bool _inited = false;

  /// 防止重复上报同一类异常
  static final List<int> _errorHashList = <int>[];

  static void init({
    XBErrorReporter? reporter,
    bool dumpFlutterErrorToConsole = true,
    bool enableErrorWidget = true,
    bool enableIsolateError = false,
  }) {
    if (_inited) return;
    _inited = true;

    _reporter = reporter;

    /// Flutter 框架异常
    FlutterError.onError = (FlutterErrorDetails details) {
      if (dumpFlutterErrorToConsole) {
        FlutterError.presentError(details);
      }

      handle(
        details.exception,
        details.stack,
      );

      final stack = details.stack ?? StackTrace.current;
      Zone.current.handleUncaughtError(details.exception, stack);
    };

    /// 页面构建异常兜底 UI
    if (enableErrorWidget) {
      ErrorWidget.builder = (FlutterErrorDetails details) {
        handle(
          details.exception,
          details.stack,
        );
        return XBErrorView(
          error: details.exception,
          stackTrace: details.stack,
        );
      };
    }

    /// isolate 异常
    if (enableIsolateError) {
      Isolate.current.addErrorListener(
        RawReceivePort((dynamic pair) async {
          try {
            final list = pair as List<dynamic>;
            final error = list.isNotEmpty ? list[0] : 'Unknown isolate error';
            final stack = list.length > 1
                ? StackTrace.fromString(list[1].toString())
                : StackTrace.current;
            await handle(error, stack);
          } catch (e, s) {
            debugPrint('XBErrorHandler isolate parse error: $e');
            debugPrint('$s');
          }
        }).sendPort,
      );
    }
  }

  static Future<void> handle(
    Object error,
    StackTrace? stackTrace,
  ) async {
    try {
      final hash = _buildHash(error, stackTrace);
      if (_errorHashList.contains(hash)) return;

      _errorHashList.add(hash);
      if (_errorHashList.length > 300) {
        _errorHashList.removeAt(0);
      }

      debugPrint('XBErrorHandler catch error: $error');
      if (stackTrace != null) {
        debugPrint('$stackTrace');
      }

      await _reporter?.call(error, stackTrace);
    } catch (e, s) {
      debugPrint('XBErrorHandler report error: $e');
      debugPrint('$s');
    }
  }

  static int _buildHash(Object error, StackTrace? stackTrace) {
    final stackStr = stackTrace?.toString() ?? '';
    final key = '${error.runtimeType}|$error|$stackStr';
    return key.hashCode;
  }
}
