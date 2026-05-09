import 'dart:collection';

import '../core/xb_track_event.dart';
import '../core/xb_track_sink.dart';

class XBMemorySink extends XBTrackSink {
  final int maxEvents;

  XBMemorySink({this.maxEvents = 1000}) : assert(maxEvents > 0);

  final List<XBTrackEvent> _events = <XBTrackEvent>[];

  UnmodifiableListView<XBTrackEvent> get events =>
      UnmodifiableListView<XBTrackEvent>(_events);

  @override
  Future<void> onEvents(List<XBTrackEvent> events) async {
    if (events.isEmpty) return;
    _events.addAll(events);
    final overflow = _events.length - maxEvents;
    if (overflow > 0) {
      _events.removeRange(0, overflow);
    }
  }

  void clear() {
    _events.clear();
  }
}
