import 'dart:convert';

class XBTrackEvent {
  final String eventId;
  final String event;
  final int eventTimeMs;
  final String sessionId;
  final String? userId;
  final String? pageName;
  final String? appVersion;
  final String platform;
  final String schemaVersion;
  final Map<String, dynamic> params;
  final Map<String, dynamic> commonParams;

  const XBTrackEvent({
    required this.eventId,
    required this.event,
    required this.eventTimeMs,
    required this.sessionId,
    required this.platform,
    required this.schemaVersion,
    this.userId,
    this.pageName,
    this.appVersion,
    this.params = const <String, dynamic>{},
    this.commonParams = const <String, dynamic>{},
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'eventId': eventId,
      'event': event,
      'eventTimeMs': eventTimeMs,
      'sessionId': sessionId,
      'userId': userId,
      'pageName': pageName,
      'appVersion': appVersion,
      'platform': platform,
      'schemaVersion': schemaVersion,
      'params': params,
      'commonParams': commonParams,
    };
  }

  String toJsonString() => jsonEncode(toJson());

  int approximateBytes() => utf8.encode(toJsonString()).length;

  XBTrackEvent copyWith({
    String? eventId,
    String? event,
    int? eventTimeMs,
    String? sessionId,
    String? userId,
    bool clearUserId = false,
    String? pageName,
    bool clearPageName = false,
    String? appVersion,
    bool clearAppVersion = false,
    String? platform,
    String? schemaVersion,
    Map<String, dynamic>? params,
    Map<String, dynamic>? commonParams,
  }) {
    return XBTrackEvent(
      eventId: eventId ?? this.eventId,
      event: event ?? this.event,
      eventTimeMs: eventTimeMs ?? this.eventTimeMs,
      sessionId: sessionId ?? this.sessionId,
      userId: clearUserId ? null : (userId ?? this.userId),
      pageName: clearPageName ? null : (pageName ?? this.pageName),
      appVersion: clearAppVersion ? null : (appVersion ?? this.appVersion),
      platform: platform ?? this.platform,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      params: params ?? this.params,
      commonParams: commonParams ?? this.commonParams,
    );
  }

  factory XBTrackEvent.fromJson(Map<String, dynamic> json) {
    final rawParams = json['params'];
    final rawCommonParams = json['commonParams'];
    return XBTrackEvent(
      eventId: '${json['eventId'] ?? ''}',
      event: '${json['event'] ?? ''}',
      eventTimeMs: _toInt(json['eventTimeMs']),
      sessionId: '${json['sessionId'] ?? ''}',
      userId: json['userId']?.toString(),
      pageName: json['pageName']?.toString(),
      appVersion: json['appVersion']?.toString(),
      platform: '${json['platform'] ?? ''}',
      schemaVersion: '${json['schemaVersion'] ?? ''}',
      params: _toMap(rawParams),
      commonParams: _toMap(rawCommonParams),
    );
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  static Map<String, dynamic> _toMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map(
        (key, dynamic item) => MapEntry('$key', item),
      );
    }
    return <String, dynamic>{};
  }
}
