import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 内置 HTTP 客户端，使用 dart:io HttpClient，无需额外依赖。
///
/// 使用者也可通过 [EchoConfig.customSender] 注入自定义发送器（如 Dio）。
class EchoHttpClient {
  /// 向 Echo 服务器发送 POST 请求。
  ///
  /// [url] 完整的接口地址，如 "http://144.168.61.190:3000/echo"
  /// [body] 请求体（JSON）
  /// [timeout] 超时时间，默认 3 秒
  ///
  /// 返回 true 表示发送成功（HTTP 200），false 表示失败。
  static Future<bool> post(
    String url,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = timeout;

      final request = await client.postUrl(Uri.parse(url));
      request.headers.set('Content-Type', 'application/json');
      request.write(jsonEncode(body));

      final response = await request.close().timeout(
            timeout,
            onTimeout: () => throw TimeoutException('Request timeout'),
          );

      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client?.close();
    }
  }

  /// 连通性检查：GET 请求目标服务器，确认可访问。
  static Future<bool> checkConnectivity(
    String echoHost, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = timeout;

      final request = await client.getUrl(Uri.parse(echoHost));
      final response = await request.close().timeout(
            timeout,
            onTimeout: () => throw TimeoutException('Connectivity check timeout'),
          );

      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client?.close();
    }
  }
}
