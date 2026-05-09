import '../core/xb_track_event.dart';
import '../core/xb_track_sink.dart';
import '../core/xb_track_store.dart';

class XBLocalStoreSink extends XBTrackSink {
  final XBTrackStore store;

  XBLocalStoreSink({required this.store});

  @override
  Future<void> onEvents(List<XBTrackEvent> events) {
    return store.appendMany(events);
  }

  @override
  Future<void> close() {
    return store.close();
  }
}
