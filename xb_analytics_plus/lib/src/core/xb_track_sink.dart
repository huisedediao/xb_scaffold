import 'xb_track_event.dart';

abstract class XBTrackSink {
  String get name => runtimeType.toString();

  Future<void> onEvent(XBTrackEvent event) async {
    await onEvents(<XBTrackEvent>[event]);
  }

  Future<void> onEvents(List<XBTrackEvent> events);

  Future<void> close() async {}
}
