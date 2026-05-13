import 'xb_ume_network_reporter.dart';

abstract class XBUmeNetworkAdapter {
  String onRequest({
    required String method,
    required Uri url,
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
    dynamic body,
    String? requestId,
  });

  void onProgress(String requestId, double progress);

  void onResponse(
    String requestId, {
    int? statusCode,
    Map<String, dynamic>? headers,
    dynamic body,
  });

  void onError(
    String requestId, {
    Object? error,
    StackTrace? stackTrace,
    int? statusCode,
    Map<String, dynamic>? headers,
    dynamic body,
    bool cancelled,
  });
}

class XBUmeDefaultNetworkAdapter implements XBUmeNetworkAdapter {
  const XBUmeDefaultNetworkAdapter();

  @override
  String onRequest({
    required String method,
    required Uri url,
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
    dynamic body,
    String? requestId,
  }) {
    return XBUmeNetworkReporter.begin(
      method: method,
      url: url,
      queryParameters: queryParameters,
      requestHeaders: headers,
      requestBody: body,
      requestId: requestId,
    );
  }

  @override
  void onProgress(String requestId, double progress) {
    XBUmeNetworkReporter.progress(requestId, progress);
  }

  @override
  void onResponse(
    String requestId, {
    int? statusCode,
    Map<String, dynamic>? headers,
    dynamic body,
  }) {
    XBUmeNetworkReporter.complete(
      requestId,
      statusCode: statusCode,
      responseHeaders: headers,
      responseBody: body,
    );
  }

  @override
  void onError(
    String requestId, {
    Object? error,
    StackTrace? stackTrace,
    int? statusCode,
    Map<String, dynamic>? headers,
    dynamic body,
    bool cancelled = false,
  }) {
    XBUmeNetworkReporter.fail(
      requestId,
      error: error,
      stackTrace: stackTrace,
      statusCode: statusCode,
      responseHeaders: headers,
      responseBody: body,
      cancelled: cancelled,
    );
  }
}
