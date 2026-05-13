import '../../core/xb_ume_binding.dart';

class XBUmeNetworkReporter {
  static String begin({
    required String method,
    required Uri url,
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? requestHeaders,
    dynamic requestBody,
    String? requestId,
  }) {
    final controller = XBUmeBinding.instanceOrNull?.controller;
    if (controller == null) {
      return requestId ??
          'net-${DateTime.now().microsecondsSinceEpoch}-${method.toUpperCase()}';
    }

    return controller.startNetwork(
      method: method,
      url: url,
      queryParameters: queryParameters,
      requestHeaders: requestHeaders,
      requestBody: requestBody,
      requestId: requestId,
    );
  }

  static void progress(String requestId, double progress) {
    final controller = XBUmeBinding.instanceOrNull?.controller;
    if (controller == null) return;
    controller.updateNetworkProgress(requestId, progress);
  }

  static void complete(
    String requestId, {
    int? statusCode,
    Map<String, dynamic>? responseHeaders,
    dynamic responseBody,
  }) {
    final controller = XBUmeBinding.instanceOrNull?.controller;
    if (controller == null) return;
    controller.completeNetwork(
      requestId,
      statusCode: statusCode,
      responseHeaders: responseHeaders,
      responseBody: responseBody,
    );
  }

  static void fail(
    String requestId, {
    Object? error,
    StackTrace? stackTrace,
    int? statusCode,
    Map<String, dynamic>? responseHeaders,
    dynamic responseBody,
    bool cancelled = false,
  }) {
    final controller = XBUmeBinding.instanceOrNull?.controller;
    if (controller == null) return;
    controller.failNetwork(
      requestId,
      error: error,
      stackTrace: stackTrace,
      statusCode: statusCode,
      responseHeaders: responseHeaders,
      responseBody: responseBody,
      cancelled: cancelled,
    );
  }
}
