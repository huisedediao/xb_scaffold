import 'core/xb_track_config.dart';
import 'core/xb_track_event.dart';
import 'core/xb_track_manager.dart';
import 'core/xb_track_types.dart';

Future<void> initXBTrack(XBTrackConfig config) {
  return XBTrackManager.shared.init(config);
}

void xbTrack(
  String event, {
  Map<String, dynamic>? params,
  String? pageName,
  Map<String, dynamic>? commonParams,
}) {
  XBTrackManager.shared.track(
    event,
    params: params,
    pageName: pageName,
    commonParams: commonParams,
  );
}

Future<void> xbTrackError(
  Object error,
  StackTrace? stackTrace, {
  String event = 'app_error',
  Map<String, dynamic>? extra,
}) {
  return XBTrackManager.shared.trackError(
    error,
    stackTrace,
    event: event,
    extra: extra,
  );
}

void xbSetTrackUser(String userId) {
  XBTrackManager.shared.setUser(userId);
}

void xbClearTrackUser() {
  XBTrackManager.shared.clearUser();
}

void xbSetTrackPage(String? pageName) {
  XBTrackManager.shared.setPageName(pageName);
}

void xbSetTrackCommonParamsProvider(XBTrackCommonParamsProvider? provider) {
  XBTrackManager.shared.setCommonParamsProvider(provider);
}

Future<String> xbExportTrackAsJson({int? limit}) {
  return XBTrackManager.shared.exportAsJson(limit: limit);
}

Future<String> xbExportTrackAsText({int? limit}) {
  return XBTrackManager.shared.exportAsText(limit: limit);
}

Future<void> xbShareTrackExport({int? limit}) {
  return XBTrackManager.shared.requestShareLatest(limit: limit);
}

Future<List<XBTrackEvent>> xbReadTrackLocalLatest({
  int limit = 100,
  int offset = 0,
}) {
  return XBTrackManager.shared.readLocalLatest(limit: limit, offset: offset);
}

Future<void> xbClearTrackLocal() {
  return XBTrackManager.shared.clearLocal();
}

Future<void> xbFlushTrack() {
  return XBTrackManager.shared.flush();
}

void xbTrackPageView(String pageName, {Map<String, dynamic>? params}) {
  xbSetTrackPage(pageName);
  xbTrack(
    'page_view',
    pageName: pageName,
    params: <String, dynamic>{...?params},
  );
}

void xbTrackPageHide(String pageName, {Map<String, dynamic>? params}) {
  xbTrack(
    'page_hide',
    pageName: pageName,
    params: <String, dynamic>{...?params},
  );
}

void xbTrackPageLeave(
  String pageName, {
  required int durationMs,
  Map<String, dynamic>? params,
}) {
  xbTrack(
    'page_leave',
    pageName: pageName,
    params: <String, dynamic>{'durationMs': durationMs, ...?params},
  );
}

void xbTrackAppForeground({Map<String, dynamic>? params}) {
  xbTrack('app_foreground', params: params);
}

void xbTrackAppBackground({Map<String, dynamic>? params}) {
  xbTrack('app_background', params: params);
}

void xbTrackTap(String trackId, {Map<String, dynamic>? params}) {
  xbTrack('tap', params: <String, dynamic>{'trackId': trackId, ...?params});
}

Future<void> closeXBTrack({bool flushBeforeClose = true}) {
  return XBTrackManager.shared.close(flushBeforeClose: flushBeforeClose);
}
