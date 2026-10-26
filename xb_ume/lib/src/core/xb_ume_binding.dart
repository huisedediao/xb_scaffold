import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../config/xb_ume_config.dart';
import '../models/xb_ume_log_item.dart';
import '../persistence/xb_ume_persistence.dart';
import '../persistence/xb_ume_persistence_factory.dart';
import '../plugins/console/xb_ume_console_plugin.dart';
import '../plugins/device/xb_ume_device_plugin.dart';
import '../plugins/inspector/xb_ume_inspector_plugin.dart';
import '../plugins/locator/xb_ume_widget_locator_plugin.dart';
import '../plugins/network/xb_ume_network_plugin.dart';
import '../plugins/performance/xb_ume_performance_plugin.dart';
import '../plugins/route/xb_ume_route_plugin.dart';
import '../plugins/storage/xb_ume_storage_plugin.dart';
import 'xb_process_stats.dart';
import 'xb_ume_controller.dart';
import 'xb_ume_plugin.dart';
import 'xb_ume_route_observer.dart';

class XBUmeBinding {
  XBUmeBinding._({
    required this.controller,
    required this.routeObserver,
    required this.config,
  });

  static XBUmeBinding? _instance;

  static XBUmeBinding ensureInitialized({
    XBUmeConfig config = const XBUmeConfig(),
    XBUmePersistence? persistence,
    List<XBUmePlugin> extraPlugins = const <XBUmePlugin>[],
  }) {
    final existing = _instance;
    if (existing != null) return existing;

    final store =
        persistence ?? buildDefaultXbUmePersistence(config.persistenceFileName);
    final controller = XBUmeController(config: config, persistence: store);
    final binding = XBUmeBinding._(
      controller: controller,
      routeObserver: XBUmeRouteObserver(controller),
      config: config,
    );

    _instance = binding;
    binding._installGlobalHooks();
    binding._registerDefaultPlugins();
    // debug/profile 下向 GUI 暴露进程级 CPU/内存（ext.xbume.processStats）。
    XBUmeProcessStats.install();
    for (final plugin in extraPlugins) {
      controller.registerPlugin(plugin);
    }

    if (config.persistenceEnabled) {
      unawaited(controller.restore());
    }

    return binding;
  }

  static XBUmeBinding get instance {
    return _instance ?? ensureInitialized();
  }

  static XBUmeBinding? get instanceOrNull => _instance;

  final XBUmeController controller;
  final XBUmeRouteObserver routeObserver;
  final XBUmeConfig config;

  DebugPrintCallback? _originDebugPrint;
  FlutterExceptionHandler? _originFlutterError;
  bool Function(Object error, StackTrace stackTrace)? _originPlatformError;

  late final TimingsCallback _timingsCallback = _onFrameTimings;

  void _registerDefaultPlugins() {
    if (config.enableRoute) {
      controller.registerPlugin(XBUmeRoutePlugin());
    }
    if (config.enablePerformance) {
      controller.registerPlugin(XBUmePerformancePlugin());
    }
    if (config.enableNetwork) {
      controller.registerPlugin(XBUmeNetworkPlugin());
    }
    if (config.enableConsole) {
      controller.registerPlugin(XBUmeConsolePlugin());
    }
    if (config.enableInspector) {
      controller.registerPlugin(XBUmeInspectorPlugin());
    }
    if (config.enableWidgetLocator) {
      controller.registerPlugin(XBUmeWidgetLocatorPlugin());
    }
    if (config.enableDevice) {
      controller.registerPlugin(XBUmeDevicePlugin());
    }
    if (config.enableStorage) {
      controller.registerPlugin(XBUmeStoragePlugin());
    }
  }

  void _installGlobalHooks() {
    _installSafeStackDemangler();

    if (config.captureDebugPrint) {
      _originDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        _originDebugPrint?.call(message, wrapWidth: wrapWidth);
        if (message == null || message.isEmpty) return;
        controller.addLog(
          level: XBUmeLogLevel.debug,
          tag: 'debugPrint',
          message: message,
        );
      };
    }

    if (config.captureFlutterError) {
      _originFlutterError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        controller.addLog(
          level: XBUmeLogLevel.error,
          tag: 'FlutterError',
          message: details.exceptionAsString(),
          stack: details.stack?.toString(),
        );
        _originFlutterError?.call(details);
      };
    }

    if (config.capturePlatformError) {
      _originPlatformError = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError =
          (Object error, StackTrace stackTrace) {
        controller.addLog(
          level: XBUmeLogLevel.fatal,
          tag: 'PlatformError',
          message: error.toString(),
          stack: stackTrace.toString(),
        );
        if (_originPlatformError != null) {
          return _originPlatformError!(error, stackTrace);
        }
        return false;
      };
    }

    WidgetsBinding.instance.addTimingsCallback(_timingsCallback);
  }

  /// 让框架的错误上报容忍 VM service 注入产生的栈帧。
  ///
  /// 指针注入与取值都经由 VM eval 执行，异常栈里会出现
  /// `#12     Eval.<anonymous closure> ()` 这种没有 `(file:line)` 的帧；
  /// `FlutterError` 打印时 `StackFrame.fromStackTraceLine` 对它会直接断言失败，
  /// 导致“报错本身崩溃”。该崩溃若发生在一次路由变更（push/pop）的事务中间，
  /// Navigator 会停在过渡态：新页面桥在动画起点、`_debugLocked` 永不复位，
  /// 之后所有 pop 都失效。这里在 debug 下只保留合法帧，其余原样透传。
  static void _installSafeStackDemangler() {
    if (!kDebugMode) return;
    final StackTraceDemangler origin = FlutterError.demangleStackTrace;
    FlutterError.demangleStackTrace = (StackTrace stack) {
      try {
        final kept = origin(stack)
            .toString()
            .split('\n')
            .where((String line) =>
                line.isEmpty || _stackFramePattern.hasMatch(line))
            .join('\n');
        return StackTrace.fromString(kept);
      } catch (_) {
        return stack;
      }
    };
  }

  /// 与框架 `StackFrame.fromStackTraceLine` 的断言同形，保证不触发二次断言。
  static final RegExp _stackFramePattern =
      RegExp(r'^#(\d+) +(.+) \((.+?):?(\d+){0,1}:?(\d+){0,1}\)$');

  void _onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      controller.addFrameTiming(timing);
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_timingsCallback);

    if (_originDebugPrint != null) {
      debugPrint = _originDebugPrint!;
      _originDebugPrint = null;
    }

    if (_originFlutterError != null) {
      FlutterError.onError = _originFlutterError;
      _originFlutterError = null;
    }

    if (_originPlatformError != null) {
      PlatformDispatcher.instance.onError = _originPlatformError;
      _originPlatformError = null;
    }

    controller.dispose();
    _instance = null;
  }
}
