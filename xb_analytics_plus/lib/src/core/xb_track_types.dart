import 'dart:async';

typedef XBTrackCommonParamsProvider = Map<String, dynamic> Function();
typedef XBTrackSanitizer = dynamic Function({
  required String key,
  required dynamic value,
});
typedef XBTrackShareRequested = FutureOr<void> Function(String content);
