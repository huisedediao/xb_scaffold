import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/xb_track_event.dart';
import '../core/xb_track_store.dart';
import 'xb_local_store_backend.dart';

class XBLocalTrackStore implements XBTrackStore {
  final int ioMaxBytes;
  final int webMaxBytes;
  final String namespace;

  XBLocalTrackStore({
    required this.ioMaxBytes,
    required this.webMaxBytes,
    required this.namespace,
  });

  late final XBLocalStoreBackend _backend =
      createXBLocalStoreBackend(namespace: namespace);

  Future<void>? _initFuture;
  Future<void> _ops = Future<void>.value();
  int _bytesCache = 0;
  int _countCache = 0;

  int get _maxBytes => kIsWeb ? webMaxBytes : ioMaxBytes;

  Future<void> _ensureInited() {
    _initFuture ??= () async {
      await _backend.init();
      final lines = await _backend.readLines();
      _countCache = lines.length;
      _bytesCache = _calculateLinesBytes(lines);
    }();
    return _initFuture!;
  }

  Future<T> _lock<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _ops = _ops.then((_) async {
      try {
        final result = await action();
        completer.complete(result);
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  @override
  Future<void> appendMany(List<XBTrackEvent> events) {
    if (events.isEmpty) return Future<void>.value();
    return _lock(() async {
      await _ensureInited();
      final lines = events.map((e) => e.toJsonString()).toList();
      await _backend.appendLines(lines);
      _countCache += lines.length;
      _bytesCache += _calculateLinesBytes(lines);
      await _trimToMaxBytes();
    });
  }

  @override
  Future<int> approximateBytes() {
    return _lock(() async {
      await _ensureInited();
      return _bytesCache;
    });
  }

  @override
  Future<void> clear() {
    return _lock(() async {
      await _ensureInited();
      await _backend.clear();
      _bytesCache = 0;
      _countCache = 0;
    });
  }

  @override
  Future<void> close() {
    return _lock(() async {
      await _ensureInited();
      await _backend.close();
    });
  }

  @override
  Future<int> count() {
    return _lock(() async {
      await _ensureInited();
      return _countCache;
    });
  }

  @override
  Future<List<XBTrackEvent>> readAll() {
    return _lock(() async {
      await _ensureInited();
      final lines = await _backend.readLines();
      return _decodeLines(lines);
    });
  }

  @override
  Future<List<XBTrackEvent>> readLatest({
    int limit = 100,
    int offset = 0,
  }) {
    return _lock(() async {
      await _ensureInited();
      final lines = await _backend.readLines();
      if (lines.isEmpty || limit <= 0) return <XBTrackEvent>[];

      final maxStart = lines.length - 1 - offset;
      if (maxStart < 0) return <XBTrackEvent>[];

      final takeCount = limit < (maxStart + 1) ? limit : (maxStart + 1);
      final selected = <String>[];
      for (int i = 0; i < takeCount; i++) {
        selected.add(lines[maxStart - i]);
      }
      return _decodeLines(selected);
    });
  }

  Future<void> _trimToMaxBytes() async {
    if (_bytesCache <= _maxBytes) return;
    final lines = await _backend.readLines();
    if (lines.isEmpty) {
      _bytesCache = 0;
      _countCache = 0;
      return;
    }

    final retained = <String>[];
    int retainedBytes = 0;

    for (int i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      final lineBytes = utf8.encode(line).length + 1;
      if (retainedBytes + lineBytes > _maxBytes) {
        break;
      }
      retained.insert(0, line);
      retainedBytes += lineBytes;
    }

    await _backend.overwriteLines(retained);
    _bytesCache = retainedBytes;
    _countCache = retained.length;
  }

  List<XBTrackEvent> _decodeLines(List<String> lines) {
    final events = <XBTrackEvent>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          events.add(XBTrackEvent.fromJson(decoded));
          continue;
        }
        if (decoded is Map) {
          final map = decoded.map((key, dynamic value) {
            return MapEntry('$key', value);
          });
          events.add(XBTrackEvent.fromJson(map));
        }
      } catch (_) {
        // ignore malformed line
      }
    }
    return events;
  }

  int _calculateLinesBytes(List<String> lines) {
    int total = 0;
    for (final line in lines) {
      total += utf8.encode(line).length + 1;
    }
    return total;
  }
}
