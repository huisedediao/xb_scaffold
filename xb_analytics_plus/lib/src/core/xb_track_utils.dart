import 'dart:math';

import 'package:flutter/foundation.dart';

final Random _xbTrackRandom = Random();

String xbTrackGenerateId() {
  final ts = DateTime.now().microsecondsSinceEpoch;
  final rand = _xbTrackRandom.nextInt(1 << 32).toRadixString(16);
  return '${ts}_$rand';
}

String xbTrackResolvePlatform() {
  if (kIsWeb) return 'web';
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.macOS:
      return 'macos';
    case TargetPlatform.windows:
      return 'windows';
    case TargetPlatform.linux:
      return 'linux';
    case TargetPlatform.fuchsia:
      return 'fuchsia';
  }
}

dynamic xbTrackNormalizeJsonValue(dynamic value, {int depth = 0}) {
  if (depth >= 8) return '$value';
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is DateTime) {
    return value.toIso8601String();
  }
  if (value is Map) {
    final map = <String, dynamic>{};
    value.forEach((key, dynamic v) {
      map['$key'] = xbTrackNormalizeJsonValue(v, depth: depth + 1);
    });
    return map;
  }
  if (value is Iterable) {
    return value
        .map(
            (dynamic item) => xbTrackNormalizeJsonValue(item, depth: depth + 1))
        .toList();
  }
  return '$value';
}
