import '../../core/xb_ume_binding.dart';

class XBUmeNetworkReporter {
  static final RegExp _frameRe =
      RegExp(r'^#\d+\s+.*\((.+):\d+:\d+\)$');

  /// 从调用栈提取「请求发起位置」：过滤 dart/flutter 与网络基础设施帧，
  /// 只保留用户代码帧（最多 24 帧）；返回原始栈帧行，首行即发起位置。
  /// [source] 传入网络层记录的调用点栈（如 Dio 的
  /// `RequestOptions.sourceStackTrace`）：Dio 5 的 onRequest 在独立
  /// Future 中执行，直接 StackTrace.current 已丢失用户调用帧。
  static List<String> _captureInitiatorFrames(StackTrace source) {
    try {
      final kept = <String>[];
      for (final raw in source.toString().split('\n')) {
        final line = raw.trimRight();
        final m = _frameRe.firstMatch(line);
        if (m == null) continue;
        final uri = m.group(1)!;
        if (_isInfraFrame(uri)) continue;
        kept.add(line);
        if (kept.length >= 24) break;
      }
      return kept;
    } catch (_) {
      return const <String>[];
    }
  }

  static bool _isInfraFrame(String uri) =>
      uri.startsWith('dart:') ||
      uri.startsWith('package:flutter/') ||
      uri.startsWith('package:dio/') ||
      uri.startsWith('package:http/') ||
      uri.startsWith('package:xb_ume/') ||
      uri.startsWith('package:xb_network/') ||
      uri.startsWith('package:stack_trace/');

  static String begin({
    required String method,
    required Uri url,
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? requestHeaders,
    dynamic requestBody,
    String? requestId,
    StackTrace? sourceStackTrace,
  }) {
    final controller = XBUmeBinding.instanceOrNull?.controller;
    if (controller == null) {
      return requestId ??
          'net-${DateTime.now().microsecondsSinceEpoch}-${method.toUpperCase()}';
    }

    final initiatorFrames =
        _captureInitiatorFrames(sourceStackTrace ?? StackTrace.current);
    return controller.startNetwork(
      method: method,
      url: url,
      queryParameters: queryParameters,
      requestHeaders: requestHeaders,
      requestBody: requestBody,
      requestId: requestId,
      initiator:
          initiatorFrames.isEmpty ? null : initiatorFrames.first,
      initiatorStack:
          initiatorFrames.isEmpty ? null : initiatorFrames.join('\n'),
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
