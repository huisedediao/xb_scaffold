import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../sinks/xb_console_sink.dart';
import '../sinks/xb_local_store_sink.dart';
import '../sinks/xb_memory_sink.dart';
import '../store/xb_local_track_store.dart';
import 'xb_track_config.dart';
import 'xb_track_event.dart';
import 'xb_track_exporter.dart';
import 'xb_track_sink.dart';
import 'xb_track_store.dart';
import 'xb_track_types.dart';
import 'xb_track_utils.dart';

class XBTrackManager implements XBTrackExporter {
  XBTrackManager._();

  static final XBTrackManager shared = XBTrackManager._();

  final Random _random = Random();
  final List<XBTrackEvent> _queue = <XBTrackEvent>[];

  XBTrackConfig? _config;
  Timer? _flushTimer;
  bool _isFlushing = false;

  String _sessionId = xbTrackGenerateId();
  String? _userId;
  String? _pageName;
  XBTrackCommonParamsProvider? _extraCommonProvider;

  XBMemorySink? _memorySink;
  XBTrackStore? _store;
  final List<XBTrackSink> _sinks = <XBTrackSink>[];

  bool get initialized => _config != null;

  XBTrackConfig get _safeConfig => _config ?? const XBTrackConfig();

  Future<void> init(XBTrackConfig config) async {
    if (_config != null) {
      await close(flushBeforeClose: false);
    } else {
      _queue.clear();
      _sinks.clear();
      _store = null;
      _memorySink = null;
    }
    _applyConfig(config);
  }

  void _applyConfig(XBTrackConfig config) {
    _config = config;
    _sessionId = xbTrackGenerateId();
    _queue.clear();
    _memorySink = null;
    _store = null;
    _sinks.clear();

    if (config.enableConsoleSink) {
      _sinks.add(XBConsoleSink());
    }

    if (config.enableMemorySink) {
      _memorySink = XBMemorySink(maxEvents: config.memoryMaxEvents);
      _sinks.add(_memorySink!);
    }

    if (config.enableLocalStoreSink) {
      final store = config.store ??
          XBLocalTrackStore(
            ioMaxBytes: config.ioMaxBytes,
            webMaxBytes: config.webMaxBytes,
            namespace: config.storeNamespace,
          );
      _store = store;
      _sinks.add(XBLocalStoreSink(store: store));
    }

    _sinks.addAll(config.sinks);

    _flushTimer = Timer.periodic(config.flushInterval, (_) {
      flush();
    });
  }

  void setUser(String? userId) {
    _userId = userId;
  }

  void clearUser() {
    _userId = null;
  }

  void setPageName(String? pageName) {
    _pageName = pageName;
  }

  void setCommonParamsProvider(XBTrackCommonParamsProvider? provider) {
    _extraCommonProvider = provider;
  }

  XBMemorySink? get memorySink => _memorySink;
  XBTrackStore? get store => _store;

  void track(
    String event, {
    Map<String, dynamic>? params,
    String? pageName,
    Map<String, dynamic>? commonParams,
  }) {
    if (_config == null) {
      _applyConfig(const XBTrackConfig());
    }

    final config = _safeConfig;
    if (!config.enabled) return;
    final eventName = event.trim();
    if (eventName.isEmpty) return;

    if (_random.nextDouble() > config.sampleRate) {
      return;
    }

    final sanitizedParams = _sanitizeMap(params ?? const <String, dynamic>{});
    final mergedCommon = <String, dynamic>{
      ..._safeCallMap(config.commonParamsProvider),
      ..._safeCallMap(_extraCommonProvider),
      ...(commonParams ?? const <String, dynamic>{}),
    };
    final sanitizedCommon = _sanitizeMap(mergedCommon);

    final trackEvent = XBTrackEvent(
      eventId: xbTrackGenerateId(),
      event: eventName,
      eventTimeMs: DateTime.now().millisecondsSinceEpoch,
      sessionId: _sessionId,
      userId: _userId,
      pageName: pageName ?? _pageName,
      appVersion: config.appVersion,
      platform: config.platform ?? xbTrackResolvePlatform(),
      schemaVersion: config.schemaVersion,
      params: sanitizedParams,
      commonParams: sanitizedCommon,
    );

    if (trackEvent.approximateBytes() > config.maxEventBytes) {
      _debugDrop('drop oversized event: $eventName');
      return;
    }

    if (_queue.length >= config.maxPendingQueueSize) {
      if (config.dropEventsWhenQueueFull) {
        _debugDrop('drop by full queue: $eventName');
        return;
      }
      _queue.removeAt(0);
    }

    _queue.add(trackEvent);
    if (_queue.length >= config.flushBatchSize) {
      flush();
    }
  }

  Future<void> flush() async {
    final config = _config;
    if (config == null) return;
    if (_isFlushing || _queue.isEmpty) return;

    _isFlushing = true;
    try {
      while (_queue.isNotEmpty) {
        final batchLen = _queue.length < config.flushBatchSize
            ? _queue.length
            : config.flushBatchSize;
        final batch = _queue.sublist(0, batchLen);
        _queue.removeRange(0, batchLen);
        await _dispatchToSinks(batch);
      }
    } finally {
      _isFlushing = false;
    }
  }

  Future<void> _dispatchToSinks(List<XBTrackEvent> events) async {
    if (events.isEmpty || _sinks.isEmpty) return;
    for (final sink in _sinks) {
      try {
        await sink.onEvents(events);
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('XBTrack sink ${sink.name} failed: $e');
          debugPrint('$s');
        }
      }
    }
  }

  Future<void> trackError(
    Object error,
    StackTrace? stackTrace, {
    String event = 'app_error',
    Map<String, dynamic>? extra,
  }) async {
    track(
      event,
      params: <String, dynamic>{
        'error': '$error',
        'stackTrace': '${stackTrace ?? ''}',
        ...?extra,
      },
    );
    await flush();
  }

  Future<void> clearLocal() async {
    _memorySink?.clear();
    await _store?.clear();
  }

  Future<List<XBTrackEvent>> readLocalLatest({
    int limit = 100,
    int offset = 0,
  }) async {
    final local = _store;
    if (local == null) {
      final mem = _memorySink;
      if (mem == null) return <XBTrackEvent>[];
      final events = mem.events.toList().reversed.toList();
      final start = offset < events.length ? offset : events.length;
      final end =
          (start + limit) < events.length ? (start + limit) : events.length;
      return events.sublist(start, end);
    }
    return local.readLatest(limit: limit, offset: offset);
  }

  @override
  Future<String> exportAsJson({int? limit}) async {
    final events = await _readForExport(limit: limit);
    final list = events.map((e) => e.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(list);
  }

  @override
  Future<String> exportAsText({int? limit}) async {
    final events = await _readForExport(limit: limit);
    final buffer = StringBuffer();
    for (final event in events) {
      buffer.writeln(event.toJsonString());
    }
    return buffer.toString();
  }

  Future<void> requestShareLatest({int? limit}) async {
    final config = _config;
    if (config == null || config.onShareRequested == null) return;
    final content = await exportAsJson(limit: limit);
    await config.onShareRequested!(content);
  }

  Future<List<XBTrackEvent>> _readForExport({int? limit}) async {
    final local = _store;
    if (local != null) {
      if (limit == null) {
        return local.readAll();
      }
      return local.readLatest(limit: limit, offset: 0);
    }

    final mem = _memorySink;
    if (mem == null) return <XBTrackEvent>[];
    final list = mem.events.toList();
    if (limit == null || limit >= list.length) {
      return list;
    }
    return list.sublist(list.length - limit);
  }

  Future<void> close({bool flushBeforeClose = true}) async {
    _flushTimer?.cancel();
    _flushTimer = null;

    if (flushBeforeClose) {
      await flush();
    } else {
      _queue.clear();
    }

    for (final sink in _sinks) {
      try {
        await sink.close();
      } catch (_) {}
    }
    _sinks.clear();
    _store = null;
    _memorySink = null;
    _config = null;
    _isFlushing = false;
  }

  Map<String, dynamic> _safeCallMap(XBTrackCommonParamsProvider? provider) {
    if (provider == null) return <String, dynamic>{};
    try {
      return provider();
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Map<String, dynamic> _sanitizeMap(Map<String, dynamic> raw) {
    final config = _safeConfig;
    final lowerSensitive = config.sensitiveKeys
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();

    final sanitized = <String, dynamic>{};
    raw.forEach((key, dynamic value) {
      final k = key.trim();
      if (k.isEmpty) return;
      final lower = k.toLowerCase();
      if (lowerSensitive.contains(lower)) {
        sanitized[k] = config.sensitiveValueMask;
        return;
      }
      dynamic nextValue =
          _sanitizeValue(key: k, value: value, sensitiveKeys: lowerSensitive);
      if (config.sanitizer != null) {
        try {
          nextValue = config.sanitizer!(key: k, value: nextValue);
        } catch (_) {}
      }
      sanitized[k] = xbTrackNormalizeJsonValue(nextValue);
    });
    return sanitized;
  }

  dynamic _sanitizeValue({
    required String key,
    required dynamic value,
    required Set<String> sensitiveKeys,
  }) {
    final config = _safeConfig;
    final lowerKey = key.toLowerCase();
    if (sensitiveKeys.contains(lowerKey)) {
      return config.sensitiveValueMask;
    }

    final normalized = xbTrackNormalizeJsonValue(value);

    if (normalized is Map<String, dynamic>) {
      final map = <String, dynamic>{};
      normalized.forEach((nestedKey, dynamic nestedValue) {
        map[nestedKey] = _sanitizeValue(
          key: nestedKey,
          value: nestedValue,
          sensitiveKeys: sensitiveKeys,
        );
      });
      return map;
    }

    if (normalized is List) {
      return normalized
          .map((dynamic item) => _sanitizeValue(
                key: key,
                value: item,
                sensitiveKeys: sensitiveKeys,
              ))
          .toList();
    }

    return normalized;
  }

  void _debugDrop(String message) {
    final config = _config;
    if (config == null || !config.debugPrintDropReason) return;
    if (kDebugMode) {
      debugPrint('XBTrack: $message');
    }
  }
}
