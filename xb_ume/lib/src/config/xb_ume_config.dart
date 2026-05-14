import 'package:flutter/material.dart';

class XBUmeConfig {
  final bool enable;

  final bool enableConsole;
  final bool enableRoute;
  final bool enablePerformance;
  final bool enableNetwork;
  final bool enableInspector;
  final bool enableWidgetLocator;
  final bool enableDevice;
  final bool enableStorage;

  final bool captureDebugPrint;
  final bool captureFlutterError;
  final bool capturePlatformError;

  final int maxConsoleRecords;
  final int maxRouteRecords;
  final int maxPerformanceRecords;
  final int maxNetworkRecords;

  final int networkBodyMaxLength;
  final int maxInspectorNodes;
  final Duration performanceUiUpdateInterval;
  final Duration consoleUiUpdateInterval;
  final bool inspectorAutoCaptureOnOpen;

  final Offset floatingInitialOffset;
  final Size panelSize;

  final bool persistenceEnabled;
  final String persistenceFileName;
  final Duration persistenceDebounce;

  final Set<String> disabledPluginIds;
  final Set<String>? onlyEnablePluginIds;

  final Set<String> sensitiveKeys;

  const XBUmeConfig({
    this.enable = true,
    this.enableConsole = true,
    this.enableRoute = true,
    this.enablePerformance = true,
    this.enableNetwork = true,
    this.enableInspector = true,
    this.enableWidgetLocator = true,
    this.enableDevice = true,
    this.enableStorage = true,
    this.captureDebugPrint = true,
    this.captureFlutterError = true,
    this.capturePlatformError = true,
    this.maxConsoleRecords = 400,
    this.maxRouteRecords = 300,
    this.maxPerformanceRecords = 600,
    this.maxNetworkRecords = 300,
    this.networkBodyMaxLength = 65536,
    this.maxInspectorNodes = 1500,
    this.performanceUiUpdateInterval = const Duration(milliseconds: 240),
    this.consoleUiUpdateInterval = const Duration(milliseconds: 120),
    this.inspectorAutoCaptureOnOpen = false,
    this.floatingInitialOffset = const Offset(16, 180),
    this.panelSize = const Size(980, 640),
    this.persistenceEnabled = false,
    this.persistenceFileName = 'xb_ume_snapshot.json',
    this.persistenceDebounce = const Duration(seconds: 1),
    this.disabledPluginIds = const <String>{},
    this.onlyEnablePluginIds,
    this.sensitiveKeys = const <String>{
      'authorization',
      'cookie',
      'set-cookie',
      'token',
      'access_token',
      'refresh_token',
      'password',
      'secret',
      'apikey',
      'api-key',
    },
  });

  bool isPluginEnabled(String pluginId) {
    if (disabledPluginIds.contains(pluginId)) return false;
    final allowList = onlyEnablePluginIds;
    if (allowList == null) return true;
    return allowList.contains(pluginId);
  }

  XBUmeConfig copyWith({
    bool? enable,
    bool? enableConsole,
    bool? enableRoute,
    bool? enablePerformance,
    bool? enableNetwork,
    bool? enableInspector,
    bool? enableWidgetLocator,
    bool? enableDevice,
    bool? enableStorage,
    bool? captureDebugPrint,
    bool? captureFlutterError,
    bool? capturePlatformError,
    int? maxConsoleRecords,
    int? maxRouteRecords,
    int? maxPerformanceRecords,
    int? maxNetworkRecords,
    int? networkBodyMaxLength,
    int? maxInspectorNodes,
    Duration? performanceUiUpdateInterval,
    Duration? consoleUiUpdateInterval,
    bool? inspectorAutoCaptureOnOpen,
    Offset? floatingInitialOffset,
    Size? panelSize,
    bool? persistenceEnabled,
    String? persistenceFileName,
    Duration? persistenceDebounce,
    Set<String>? disabledPluginIds,
    Set<String>? onlyEnablePluginIds,
    Set<String>? sensitiveKeys,
  }) {
    return XBUmeConfig(
      enable: enable ?? this.enable,
      enableConsole: enableConsole ?? this.enableConsole,
      enableRoute: enableRoute ?? this.enableRoute,
      enablePerformance: enablePerformance ?? this.enablePerformance,
      enableNetwork: enableNetwork ?? this.enableNetwork,
      enableInspector: enableInspector ?? this.enableInspector,
      enableWidgetLocator: enableWidgetLocator ?? this.enableWidgetLocator,
      enableDevice: enableDevice ?? this.enableDevice,
      enableStorage: enableStorage ?? this.enableStorage,
      captureDebugPrint: captureDebugPrint ?? this.captureDebugPrint,
      captureFlutterError: captureFlutterError ?? this.captureFlutterError,
      capturePlatformError: capturePlatformError ?? this.capturePlatformError,
      maxConsoleRecords: maxConsoleRecords ?? this.maxConsoleRecords,
      maxRouteRecords: maxRouteRecords ?? this.maxRouteRecords,
      maxPerformanceRecords:
          maxPerformanceRecords ?? this.maxPerformanceRecords,
      maxNetworkRecords: maxNetworkRecords ?? this.maxNetworkRecords,
      networkBodyMaxLength: networkBodyMaxLength ?? this.networkBodyMaxLength,
      maxInspectorNodes: maxInspectorNodes ?? this.maxInspectorNodes,
      performanceUiUpdateInterval:
          performanceUiUpdateInterval ?? this.performanceUiUpdateInterval,
      consoleUiUpdateInterval:
          consoleUiUpdateInterval ?? this.consoleUiUpdateInterval,
      inspectorAutoCaptureOnOpen:
          inspectorAutoCaptureOnOpen ?? this.inspectorAutoCaptureOnOpen,
      floatingInitialOffset:
          floatingInitialOffset ?? this.floatingInitialOffset,
      panelSize: panelSize ?? this.panelSize,
      persistenceEnabled: persistenceEnabled ?? this.persistenceEnabled,
      persistenceFileName: persistenceFileName ?? this.persistenceFileName,
      persistenceDebounce: persistenceDebounce ?? this.persistenceDebounce,
      disabledPluginIds: disabledPluginIds ?? this.disabledPluginIds,
      onlyEnablePluginIds: onlyEnablePluginIds ?? this.onlyEnablePluginIds,
      sensitiveKeys: sensitiveKeys ?? this.sensitiveKeys,
    );
  }
}
