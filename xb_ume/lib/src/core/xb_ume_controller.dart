import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' show FrameTiming;

import 'package:flutter/widgets.dart';

import '../config/xb_ume_config.dart';
import '../models/xb_ume_exception_item.dart';
import '../models/xb_ume_frame_item.dart';
import '../models/xb_ume_log_item.dart';
import '../models/xb_ume_network_item.dart';
import '../models/xb_ume_route_item.dart';
import '../models/xb_ume_snapshot.dart';
import '../models/xb_ume_widget_node.dart';
import '../persistence/xb_ume_persistence.dart';
import 'xb_ring_buffer.dart';
import 'xb_ume_log_file.dart';
import 'xb_ume_inspectable.dart';
import 'xb_ume_log_file_factory.dart';
import 'xb_ume_plugin.dart';
import 'xb_ume_storage_adapter.dart';

class XBUmeController extends ChangeNotifier {
  XBUmeController({
    required this.config,
    required this.persistence,
  })  : _logs = XBRingBuffer<XBUmeLogItem>(config.maxConsoleRecords),
        _routes = XBRingBuffer<XBUmeRouteItem>(config.maxRouteRecords),
        _frames = XBRingBuffer<XBUmeFrameItem>(config.maxPerformanceRecords),
        _exceptions =
            XBRingBuffer<XBUmeExceptionItem>(config.maxExceptionRecords) {
    if (config.logFileEnabled) {
      _logFile = buildXbUmeLogFile(
        dir: config.logFileDir,
        fileName: config.logFileName,
        maxBytes: config.logFileMaxBytes,
        backups: config.logFileBackups,
      );
    }
  }

  final XBUmeConfig config;
  final XBUmePersistence persistence;

  final XBRingBuffer<XBUmeLogItem> _logs;
  final XBRingBuffer<XBUmeRouteItem> _routes;
  final XBRingBuffer<XBUmeFrameItem> _frames;
  final XBRingBuffer<XBUmeExceptionItem> _exceptions;

  /// app 日志落盘（Web 端或关闭时为空）。
  XBUmeLogFile? _logFile;

  final LinkedHashMap<String, XBUmeNetworkItem> _networkItems =
      LinkedHashMap<String, XBUmeNetworkItem>();
  final Map<String, DateTime> _networkStartTimes = <String, DateTime>{};

  final LinkedHashMap<String, XBUmePlugin> _plugins =
      LinkedHashMap<String, XBUmePlugin>();

  final LinkedHashMap<String, XBUmeStorageAdapter> _storageAdapters =
      LinkedHashMap<String, XBUmeStorageAdapter>();

  final LinkedHashMap<String, XBUmeInspectable> _inspectables =
      LinkedHashMap<String, XBUmeInspectable>();

  final ValueNotifier<int> changeTick = ValueNotifier<int>(0);
  final ValueNotifier<bool> panelVisible = ValueNotifier<bool>(false);

  Timer? _persistTimer;
  Timer? _performanceUiTimer;
  Timer? _consoleUiTimer;
  bool _hasPendingPerformanceUiUpdate = false;
  bool _hasPendingConsoleUiUpdate = false;
  int _idSeed = 0;
  bool _restored = false;

  List<XBUmeLogItem> get logs => _logs.toList();
  List<XBUmeRouteItem> get routes => _routes.toList();
  List<XBUmeFrameItem> get frames => _frames.toList();
  List<XBUmeExceptionItem> get exceptions => _exceptions.toList();
  List<XBUmeNetworkItem> get network => _networkItems.values.toList();

  List<XBUmePlugin> get plugins => _plugins.values.toList(growable: false);
  List<XBUmeStorageAdapter> get storageAdapters =>
      _storageAdapters.values.toList(growable: false);
  List<XBUmeInspectable> get inspectables =>
      _inspectables.values.toList(growable: false);

  bool get restored => _restored;

  /// 落盘文件路径（未开启落盘时为 null）。MCP 侧用 `xbume_sandbox` 分页读。
  String? get logFilePath => _logFile?.path;

  /// 立刻把日志落盘缓冲刷到磁盘（进程退出前 / 需要立刻取证时调用）。
  Future<void> flushLogFile() async {
    final logFile = _logFile;
    if (logFile == null) return;
    await logFile.flush();
  }

  void showPanel() => _setPanelVisible(true);

  void hidePanel() => _setPanelVisible(false);

  void togglePanel() => _setPanelVisible(!panelVisible.value);

  void _setPanelVisible(bool visible) {
    if (panelVisible.value == visible) return;
    panelVisible.value = visible;
  }

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

  /// 注册一个「直连会话可见」的字段树（VM 会话看不到这份注册表，走 VM 自身）。
  bool registerInspectable(XBUmeInspectable inspectable) {
    _inspectables[inspectable.inspectId] = inspectable;
    _emitChanged(persist: false);
    return true;
  }

  bool unregisterInspectable(String inspectId) {
    final removed = _inspectables.remove(inspectId);
    if (removed == null) return false;
    _emitChanged(persist: false);
    return true;
  }

  XBUmeInspectable? findInspectable(String inspectId) {
    final direct = _inspectables[inspectId];
    if (direct != null) return direct;
    // 允许按类型名找（GUI 里可能出现 name 而非 id）。
    for (final it in _inspectables.values) {
      if (it.inspectType == inspectId) return it;
    }
    return null;
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
    final now = DateTime.now();
    final clipped = _clip(message);
    final clippedStack = stack == null ? null : _clip(stack);
    _logs.add(
      XBUmeLogItem(
        id: nextId('log'),
        time: now,
        level: level,
        tag: tag,
        message: clipped,
        stack: clippedStack,
      ),
    );
    // 落盘与内存缓冲同一份内容：AI 用 sandbox 读到的东西跟 Console Tab 一致。
    _logFile?.append(
      time: now,
      level: level.name,
      tag: tag,
      message: clipped,
      stack: clippedStack,
    );
    _emitConsoleChanged();
  }

  void clearLogs() {
    _consoleUiTimer?.cancel();
    _consoleUiTimer = null;
    _hasPendingConsoleUiUpdate = false;
    _logs.clear();
    // 清屏只清内存：落盘文件留一条分隔标记，之前的证据不会被误删。
    _logFile?.append(
      time: DateTime.now(),
      level: 'info',
      tag: 'xb_ume',
      message: '---- console cleared（内存缓冲已清，落盘文件继续追加）----',
    );
    _emitChanged();
  }

  /// 记录一条结构化异常。
  ///
  /// 相同签名（类型 + 摘要 + 栈首帧）且 10 秒内重复发生的不再新增条目，
  /// 只原地累加 count 并刷新时间——回放/连续帧报错时不会把缓冲刷满。
  void addException({
    required Object error,
    XBUmeExceptionKind kind = XBUmeExceptionKind.app,
    StackTrace? stack,
    String? message,
    String? library,
    String? context,
    String? widget,
    String? widgetFile,
    int? widgetLine,
    int? widgetColumn,
  }) {
    final now = DateTime.now();
    final type = error.runtimeType.toString();
    final text = _clip(message ?? error.toString(), max: 2000);
    final stackText = stack == null ? null : _clip(stack.toString(), max: 8000);
    final firstFrame = _firstStackFrame(stackText);
    final signature = '$type|$text|$firstFrame';
    final last = _exceptions.last;
    if (last != null &&
        last.signature == signature &&
        now.difference(last.time).inMilliseconds < 10000) {
      _exceptions.replaceLast(last.copyWith(time: now, count: last.count + 1));
    } else {
      _exceptions.add(
        XBUmeExceptionItem(
          id: nextId('exc'),
          time: now,
          kind: kind,
          type: type,
          message: text,
          signature: signature,
          stack: stackText,
          library: library,
          context: context == null ? null : _clip(context, max: 500),
          widget: widget == null || widget.isEmpty ? null : _clip(widget, max: 200),
          widgetFile: widgetFile == null || widgetFile.isEmpty
              ? null
              : _clip(widgetFile, max: 500),
          widgetLine: widgetLine,
          widgetColumn: widgetColumn,
        ),
      );
    }
    _emitChanged();
  }

  void clearExceptions() {
    _exceptions.clear();
    _emitChanged();
  }

  /// 栈首帧（`#0 ...` 行），用于去重签名。
  String _firstStackFrame(String? stackText) {
    if (stackText == null) return '';
    for (final line in stackText.split('\n')) {
      final t = line.trim();
      if (t.startsWith('#')) return t.length > 200 ? t.substring(0, 200) : t;
    }
    return '';
  }

  void addRoute({
    required XBUmeRouteAction action,
    required String routeName,
    String? previousRouteName,
    String phase = 'unknown',
    String? stack,
  }) {
    _routes.add(
      XBUmeRouteItem(
        id: nextId('route'),
        time: DateTime.now(),
        action: action,
        routeName: routeName,
        previousRouteName: previousRouteName,
        phase: phase,
        stack: stack,
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
    String? initiator,
    String? initiatorStack,
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
      initiator: initiator,
      initiatorStack: initiatorStack,
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

  void _emitConsoleChanged() {
    _hasPendingConsoleUiUpdate = true;
    if (_consoleUiTimer != null) return;

    _consoleUiTimer = Timer(config.consoleUiUpdateInterval, () {
      _consoleUiTimer = null;
      if (!_hasPendingConsoleUiUpdate) return;
      _hasPendingConsoleUiUpdate = false;
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

  String _clip(String text, {int? max}) {
    final limit = max ?? config.networkBodyMaxLength;
    if (text.length <= limit) return text;
    return '${text.substring(0, limit)}...<clipped>';
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _performanceUiTimer?.cancel();
    _consoleUiTimer?.cancel();
    for (final plugin in _plugins.values) {
      plugin.onUnregister(this);
    }
    final logFile = _logFile;
    _logFile = null;
    if (logFile != null) unawaited(logFile.close());
    panelVisible.dispose();
    changeTick.dispose();
    super.dispose();
  }
}
