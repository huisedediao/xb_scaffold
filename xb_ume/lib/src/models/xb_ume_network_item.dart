enum XBUmeNetworkStatus {
  pending,
  success,
  failure,
  cancelled,
}

class XBUmeNetworkItem {
  XBUmeNetworkItem({
    required this.id,
    required this.time,
    required this.method,
    required this.url,
    this.queryParameters,
    this.requestHeaders,
    this.requestBody,
    this.responseHeaders,
    this.responseBody,
    this.statusCode,
    this.durationMs,
    this.error,
    this.stack,
    this.status = XBUmeNetworkStatus.pending,
    this.progress,
  });

  final String id;
  final DateTime time;
  final String method;
  final String url;
  final Map<String, dynamic>? queryParameters;
  final Map<String, dynamic>? requestHeaders;
  final dynamic requestBody;
  final Map<String, dynamic>? responseHeaders;
  final dynamic responseBody;
  final int? statusCode;
  final int? durationMs;
  final String? error;
  final String? stack;
  final XBUmeNetworkStatus status;
  final double? progress;

  XBUmeNetworkItem copyWith({
    DateTime? time,
    String? method,
    String? url,
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? requestHeaders,
    dynamic requestBody,
    Map<String, dynamic>? responseHeaders,
    dynamic responseBody,
    int? statusCode,
    int? durationMs,
    String? error,
    String? stack,
    XBUmeNetworkStatus? status,
    double? progress,
    bool clearProgress = false,
  }) {
    return XBUmeNetworkItem(
      id: id,
      time: time ?? this.time,
      method: method ?? this.method,
      url: url ?? this.url,
      queryParameters: queryParameters ?? this.queryParameters,
      requestHeaders: requestHeaders ?? this.requestHeaders,
      requestBody: requestBody ?? this.requestBody,
      responseHeaders: responseHeaders ?? this.responseHeaders,
      responseBody: responseBody ?? this.responseBody,
      statusCode: statusCode ?? this.statusCode,
      durationMs: durationMs ?? this.durationMs,
      error: error ?? this.error,
      stack: stack ?? this.stack,
      status: status ?? this.status,
      progress: clearProgress ? null : (progress ?? this.progress),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'time': time.toIso8601String(),
      'method': method,
      'url': url,
      'queryParameters': queryParameters,
      'requestHeaders': requestHeaders,
      'requestBody': requestBody,
      'responseHeaders': responseHeaders,
      'responseBody': responseBody,
      'statusCode': statusCode,
      'durationMs': durationMs,
      'error': error,
      'stack': stack,
      'status': status.name,
      'progress': progress,
    };
  }

  factory XBUmeNetworkItem.fromJson(Map<String, dynamic> json) {
    return XBUmeNetworkItem(
      id: json['id'] as String? ?? '',
      time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
      method: json['method'] as String? ?? 'GET',
      url: json['url'] as String? ?? '',
      queryParameters:
          (json['queryParameters'] as Map?)?.cast<String, dynamic>(),
      requestHeaders: (json['requestHeaders'] as Map?)?.cast<String, dynamic>(),
      requestBody: json['requestBody'],
      responseHeaders:
          (json['responseHeaders'] as Map?)?.cast<String, dynamic>(),
      responseBody: json['responseBody'],
      statusCode: json['statusCode'] as int?,
      durationMs: json['durationMs'] as int?,
      error: json['error'] as String?,
      stack: json['stack'] as String?,
      status: XBUmeNetworkStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => XBUmeNetworkStatus.pending,
      ),
      progress: (json['progress'] as num?)?.toDouble(),
    );
  }
}
