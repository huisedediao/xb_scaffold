import 'package:flutter/foundation.dart';

import '../core/xb_track_event.dart';
import '../core/xb_track_sink.dart';

class XBConsoleSink extends XBTrackSink {
  final String prefix;

  XBConsoleSink({this.prefix = 'XBTrack'});

  @override
  Future<void> onEvents(List<XBTrackEvent> events) async {
    for (final event in events) {
      debugPrint('$prefix ${event.toJsonString()}');
    }
  }
}
