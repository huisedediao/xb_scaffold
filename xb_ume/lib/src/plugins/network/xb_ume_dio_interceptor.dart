import 'package:dio/dio.dart';

import 'xb_ume_network_reporter.dart';

class XBUmeDioInterceptor extends Interceptor {
  static const String _requestIdKey = 'xb_ume_request_id';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final requestId = XBUmeNetworkReporter.begin(
      method: options.method,
      url: options.uri,
      queryParameters: options.queryParameters.cast<String, dynamic>(),
      requestHeaders: options.headers.cast<String, dynamic>(),
      requestBody: options.data,
    );
    options.extra[_requestIdKey] = requestId;
    super.onRequest(options, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final requestId = response.requestOptions.extra[_requestIdKey]?.toString();
    if (requestId != null && requestId.isNotEmpty) {
      XBUmeNetworkReporter.complete(
        requestId,
        statusCode: response.statusCode,
        responseHeaders: response.headers.map,
        responseBody: response.data,
      );
    }
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final requestId = err.requestOptions.extra[_requestIdKey]?.toString();
    if (requestId != null && requestId.isNotEmpty) {
      XBUmeNetworkReporter.fail(
        requestId,
        error: err,
        stackTrace: err.stackTrace,
        statusCode: err.response?.statusCode,
        responseHeaders: err.response?.headers.map,
        responseBody: err.response?.data,
        cancelled: err.type == DioExceptionType.cancel,
      );
    }
    super.onError(err, handler);
  }
}
