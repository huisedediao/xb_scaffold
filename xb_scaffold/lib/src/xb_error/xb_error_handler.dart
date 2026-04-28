import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';

import 'xb_error_isolate_listener_stub.dart'
    if (dart.library.io) 'xb_error_isolate_listener_io.dart';
import 'xb_error_view.dart';

typedef XBErrorReporter = FutureOr<void> Function(
  Object error,
  StackTrace? stackTrace,
);

typedef XBErrorWidgetBuilder = Widget? Function(
  BuildContext context,
  FlutterErrorDetails details,
  String? routeName,
);

class XBErrorHandler {
  XBErrorHandler._();

  static XBErrorReporter? _reporter;
  static XBErrorWidgetBuilder? _errorWidgetBuilder;
  static bool _inited = false;

  /// 防止重复上报同一类异常
  static final List<int> _errorHashList = <int>[];

  static void init({
    XBErrorReporter? reporter,
    XBErrorWidgetBuilder? errorWidgetBuilder,
    bool dumpFlutterErrorToConsole = true,
    bool enableErrorWidget = true,
    bool enablePlatformDispatcherError = true,
    bool enableIsolateError = false,
  }) {
    if (_inited) return;
    _inited = true;

    _reporter = reporter;
    _errorWidgetBuilder = errorWidgetBuilder;

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

    /// root isolate 未捕获异常兜底
    if (enablePlatformDispatcherError) {
      final oldOnError = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        handle(error, stack);
        return oldOnError?.call(error, stack) ?? true;
      };
    }

    /// 页面构建异常兜底 UI
    if (enableErrorWidget) {
      ErrorWidget.builder = (FlutterErrorDetails details) {
        handle(
          details.exception,
          details.stack,
        );
        return Builder(builder: (context) {
          final routeName = ModalRoute.of(context)?.settings.name;
          final customErrorWidget =
              _errorWidgetBuilder?.call(context, details, routeName);
          if (customErrorWidget != null) {
            return customErrorWidget;
          }
          return XBErrorView(
            error: details.exception,
            stackTrace: details.stack,
          );
        });
      };
    }

    /// isolate 异常
    if (enableIsolateError) {
      addXBIsolateErrorListener(handle);
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
