import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' show FrameTiming;

import 'package:flutter/widgets.dart';

import '../config/xb_ume_config.dart';
import '../models/xb_ume_frame_item.dart';
import '../models/xb_ume_log_item.dart';
import '../models/xb_ume_network_item.dart';
import '../models/xb_ume_route_item.dart';
import '../models/xb_ume_snapshot.dart';
import '../models/xb_ume_widget_node.dart';
import '../persistence/xb_ume_persistence.dart';
import 'xb_ring_buffer.dart';
import 'xb_ume_plugin.dart';
import 'xb_ume_storage_adapter.dart';

class XBUmeController extends ChangeNotifier {
  XBUmeController({
    required this.config,
    required this.persistence,
  })  : _logs = XBRingBuffer<XBUmeLogItem>(config.maxConsoleRecords),
        _routes = XBRingBuffer<XBUmeRouteItem>(config.maxRouteRecords),
        _frames = XBRingBuffer<XBUmeFrameItem>(config.maxPerformanceRecords);

  final XBUmeConfig config;
  final XBUmePersistence persistence;

  final XBRingBuffer<XBUmeLogItem> _logs;
  final XBRingBuffer<XBUmeRouteItem> _routes;
  final XBRingBuffer<XBUmeFrameItem> _frames;

  final LinkedHashMap<String, XBUmeNetworkItem> _networkItems =
      LinkedHashMap<String, XBUmeNetworkItem>();
  final Map<String, DateTime> _networkStartTimes = <String, DateTime>{};

  final LinkedHashMap<String, XBUmePlugin> _plugins =
      LinkedHashMap<String, XBUmePlugin>();

  final LinkedHashMap<String, XBUmeStorageAdapter> _storageAdapters =
      LinkedHashMap<String, XBUmeStorageAdapter>();

  final ValueNotifier<int> changeTick = ValueNotifier<int>(0);

  Timer? _persistTimer;
  Timer? _performanceUiTimer;
  bool _hasPendingPerformanceUiUpdate = false;
  int _idSeed = 0;
  bool _restored = false;

  List<XBUmeLogItem> get logs => _logs.toList();
  List<XBUmeRouteItem> get routes => _routes.toList();
  List<XBUmeFrameItem> get frames => _frames.toList();
  List<XBUmeNetworkItem> get network => _networkItems.values.toList();

  List<XBUmePlugin> get plugins => _plugins.values.toList(growable: false);
  List<XBUmeStorageAdapter> get storageAdapters =>
      _storageAdapters.values.toList(growable: false);

  bool get restored => _restored;

  bool registerPlugin(XBUmePlugin plugin) {
    if (!config.isPluginEnabled(plugin.id)) return false;
    if (_plugins.containsKey(plugin.id)) return false;
    _plugins[plugin.id] = plugin;
    plugin.onRegister(this);
    _emitChanged(persist: false);
    return true;
  }

  bool unregisterPlugin(String pluginId) {
    final plugin = _plugins.remove(pluginId);
    if (plugin == null) return false;
    plugin.onUnregister(this);
    _emitChanged(persist: false);
    return true;
  }

  bool registerStorageAdapter(XBUmeStorageAdapter adapter) {
    _storageAdapters[adapter.id] = adapter;
    _emitChanged(persist: false);
    return true;
  }

  bool unregisterStorageAdapter(String adapterId) {
    final removed = _storageAdapters.remove(adapterId);
    if (removed == null) return false;
    _emitChanged(persist: false);
    return true;
  }

  XBUmeStorageAdapter? findStorageAdapter(String adapterId) {
    return _storageAdapters[adapterId];
  }

  String nextId(String prefix) {
    _idSeed += 1;
    return '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_idSeed.toRadixString(16)}';
  }

  void addLog({
    required XBUmeLogLevel level,
    required String tag,
    required String message,
    String? stack,
  }) {
    _logs.add(
      XBUmeLogItem(
        id: nextId('log'),
        time: DateTime.now(),
        level: level,
        tag: tag,
        message: _clip(message),
        stack: stack == null ? null : _clip(stack),
      ),
    );
    _emitChanged();
  }

  void clearLogs() {
    _logs.clear();
    _emitChanged();
  }

  void addRoute({
    required XBUmeRouteAction action,
    required String routeName,
    String? previousRouteName,
  }) {
    _routes.add(
      XBUmeRouteItem(
        id: nextId('route'),
        time: DateTime.now(),
        action: action,
        routeName: routeName,
        previousRouteName: previousRouteName,
      ),
    );
    _emitChanged();
  }

  void clearRoutes() {
    _routes.clear();
    _emitChanged();
  }

  void addFrameTiming(FrameTiming timing) {
    final buildMs = timing.buildDuration.inMicroseconds / 1000;
    final rasterMs = timing.rasterDuration.inMicroseconds / 1000;
    final totalMs = timing.totalSpan.inMicroseconds / 1000;
    _frames.add(
      XBUmeFrameItem(
        id: nextId('frame'),
        time: DateTime.now(),
        buildMs: buildMs,
        rasterMs: rasterMs,
        totalMs: totalMs,
        isJank: totalMs >= 16.7,
      ),
    );
    _emitPerformanceChanged();
  }

  void clearFrames() {
    _frames.clear();
    _emitChanged();
  }

  String startNetwork({
    required String method,
    required Uri url,
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? requestHeaders,
    dynamic requestBody,
    String? requestId,
  }) {
    final id = requestId ?? nextId('net');
    final item = XBUmeNetworkItem(
      id: id,
      time: DateTime.now(),
      method: method.toUpperCase(),
      url: url.toString(),
      queryParameters: _sanitizeMap(queryParameters),
      requestHeaders: _sanitizeHeaders(requestHeaders),
      requestBody: _sanitizeBody(requestBody),
      status: XBUmeNetworkStatus.pending,
    );

    _networkStartTimes[id] = item.time;
    _networkItems[id] = item;
    _trimNetworkItems();
    _emitChanged();
    return id;
  }

  void updateNetworkProgress(String requestId, double progress) {
    final old = _networkItems[requestId];
    if (old == null) return;
    _networkItems[requestId] = old.copyWith(progress: progress);
    _emitChanged();
  }

  void completeNetwork(
    String requestId, {
    int? statusCode,
    Map<String, dynamic>? responseHeaders,
    dynamic responseBody,
  }) {
    final old = _networkItems[requestId];
    if (old == null) return;
    final durationMs = _networkDurationMs(requestId);
    _networkItems[requestId] = old.copyWith(
      statusCode: statusCode,
      responseHeaders: _sanitizeHeaders(responseHeaders),
      responseBody: _sanitizeBody(responseBody),
      durationMs: durationMs,
      status: XBUmeNetworkStatus.success,
      clearProgress: true,
    );
    _emitChanged();
  }

  void failNetwork(
    String requestId, {
    Object? error,
    StackTrace? stackTrace,
    int? statusCode,
    Map<String, dynamic>? responseHeaders,
    dynamic responseBody,
    bool cancelled = false,
  }) {
    final old = _networkItems[requestId];
    if (old == null) return;
    final durationMs = _networkDurationMs(requestId);
    _networkItems[requestId] = old.copyWith(
      statusCode: statusCode,
      responseHeaders: _sanitizeHeaders(responseHeaders),
      responseBody: _sanitizeBody(responseBody),
      durationMs: durationMs,
      error: error?.toString(),
      stack: stackTrace?.toString(),
      status:
          cancelled ? XBUmeNetworkStatus.cancelled : XBUmeNetworkStatus.failure,
      clearProgress: true,
    );
    _emitChanged();
  }

  void clearNetwork() {
    _networkItems.clear();
    _networkStartTimes.clear();
    _emitChanged();
  }

  Future<void> restore() async {
    if (!config.persistenceEnabled || _restored) return;
    final json = await persistence.load();
    if (json == null) {
      _restored = true;
      return;
    }

    final snapshot = XBUmeSnapshot.fromJson(json);
    for (final item in snapshot.logs) {
      _logs.add(XBUmeLogItem.fromJson(item));
    }
    for (final item in snapshot.routes) {
      _routes.add(XBUmeRouteItem.fromJson(item));
    }
    for (final item in snapshot.frames) {
      _frames.add(XBUmeFrameItem.fromJson(item));
    }
    for (final item in snapshot.network) {
      final networkItem = XBUmeNetworkItem.fromJson(item);
      _networkItems[networkItem.id] = networkItem;
    }
    _trimNetworkItems();
    _restored = true;
    _emitChanged(persist: false);
  }

  Future<void> persistNow() async {
    if (!config.persistenceEnabled) return;
    final snapshot = XBUmeSnapshot(
      createdAt: DateTime.now(),
      logs: logs.map((e) => e.toJson()).toList(growable: false),
      routes: routes.map((e) => e.toJson()).toList(growable: false),
      frames: frames.map((e) => e.toJson()).toList(growable: false),
      network: network.map((e) => e.toJson()).toList(growable: false),
    );
    await persistence.save(snapshot.toJson());
  }

  List<XBUmeWidgetNode> buildWidgetTreeSnapshot({int? maxNodes}) {
    final limit = maxNodes ?? config.maxInspectorNodes;
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const <XBUmeWidgetNode>[];

    final nodes = <XBUmeWidgetNode>[];

    void visit(Element element, int depth) {
      if (nodes.length >= limit) return;
      try {
        final widget = element.widget;
        String? renderSummary;
        final render = element.renderObject;
        if (render is RenderBox) {
          if (render.hasSize) {
            renderSummary =
                'RenderBox(size=${render.size.width.toStringAsFixed(1)}x${render.size.height.toStringAsFixed(1)})';
          } else {
            renderSummary = 'RenderBox(size=<unlaid>)';
          }
        } else if (render != null) {
          renderSummary = '${render.runtimeType}';
        }

        final children = <Element>[];
        element.visitChildren(children.add);

        nodes.add(
          XBUmeWidgetNode(
            depth: depth,
            widgetType: '${widget.runtimeType}',
            key: widget.key?.toString(),
            renderSummary: renderSummary,
            childCount: children.length,
          ),
        );

        for (final child in children) {
          if (nodes.length < limit) {
            visit(child, depth + 1);
          }
        }
      } catch (_) {
        // Ignore unstable tree nodes in debug mode to avoid blocking UI.
      }
    }

    try {
      visit(root, 0);
    } catch (_) {
      // Ignore whole-tree failures and return collected subset.
    }
    return nodes;
  }

  Map<String, dynamic> exportAllAsJson() {
    return XBUmeSnapshot(
      createdAt: DateTime.now(),
      logs: logs.map((e) => e.toJson()).toList(growable: false),
      routes: routes.map((e) => e.toJson()).toList(growable: false),
      frames: frames.map((e) => e.toJson()).toList(growable: false),
      network: network.map((e) => e.toJson()).toList(growable: false),
    ).toJson();
  }

  String exportAllAsPrettyJson() {
    return const JsonEncoder.withIndent('  ').convert(exportAllAsJson());
  }

  void _trimNetworkItems() {
    while (_networkItems.length > config.maxNetworkRecords) {
      final firstKey = _networkItems.keys.first;
      _networkItems.remove(firstKey);
      _networkStartTimes.remove(firstKey);
    }
  }

  int? _networkDurationMs(String requestId) {
    final start = _networkStartTimes.remove(requestId);
    if (start == null) return null;
    return DateTime.now().difference(start).inMilliseconds;
  }

  void _emitChanged({bool persist = true}) {
    changeTick.value = changeTick.value + 1;
    notifyListeners();
    if (persist) {
      _schedulePersist();
    }
  }

  void _emitPerformanceChanged() {
    _hasPendingPerformanceUiUpdate = true;
    if (_performanceUiTimer != null) return;

    _performanceUiTimer = Timer(config.performanceUiUpdateInterval, () {
      _performanceUiTimer = null;
      if (!_hasPendingPerformanceUiUpdate) return;
      _hasPendingPerformanceUiUpdate = false;
      _emitChanged();
    });
  }

  void _schedulePersist() {
    if (!config.persistenceEnabled) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(config.persistenceDebounce, () {
      unawaited(persistNow());
    });
  }

  Map<String, dynamic>? _sanitizeHeaders(Map<String, dynamic>? headers) {
    return _sanitizeMap(headers);
  }

  Map<String, dynamic>? _sanitizeMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final result = <String, dynamic>{};
    map.forEach((key, value) {
      final lowerKey = key.toLowerCase();
      if (_isSensitiveKey(lowerKey)) {
        result[key] = '***';
      } else {
        result[key] = _sanitizeAny(value, keyHint: lowerKey);
      }
    });
    return result;
  }

  dynamic _sanitizeBody(dynamic body) {
    return _sanitizeAny(body);
  }

  dynamic _sanitizeAny(dynamic value, {String? keyHint}) {
    if (keyHint != null && _isSensitiveKey(keyHint)) {
      return '***';
    }

    if (value == null) return null;

    if (value is Map) {
      final map = <String, dynamic>{};
      value.forEach((key, val) {
        final keyString = key.toString();
        map[keyString] =
            _sanitizeAny(val, keyHint: keyString.toLowerCase().trim());
      });
      return map;
    }

    if (value is Iterable) {
      return value.map((e) => _sanitizeAny(e)).toList(growable: false);
    }

    if (value is String) {
      return _clip(value);
    }

    if (value is num || value is bool) {
      return value;
    }

    final text = value.toString();
    return _clip(text);
  }

  bool _isSensitiveKey(String key) {
    return config.sensitiveKeys.contains(key.toLowerCase().trim());
  }

  String _clip(String text) {
    if (text.length <= config.networkBodyMaxLength) return text;
    return '${text.substring(0, config.networkBodyMaxLength)}...<clipped>';
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _performanceUiTimer?.cancel();
    for (final plugin in _plugins.values) {
      plugin.onUnregister(this);
    }
    changeTick.dispose();
    super.dispose();
  }
}
