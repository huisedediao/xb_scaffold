import 'xb_track_event.dart';

abstract class XBTrackStore {
  Future<void> appendMany(List<XBTrackEvent> events);

  Future<List<XBTrackEvent>> readLatest({
    int limit = 100,
    int offset = 0,
  });

  Future<List<XBTrackEvent>> readAll();

  Future<int> count();

  Future<int> approximateBytes();

  Future<void> clear();

  Future<void> close();
}
