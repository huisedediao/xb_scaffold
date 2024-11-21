import 'dart:convert';
import 'package:dio/dio.dart';
import '../xb_print.dart';
import 'xb_dio_config.dart';
export 'xb_dio_config.dart';

class XBRequestInterceptor extends Interceptor {
  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    options.headers
        .addAll({'requestId': DateTime.now().microsecondsSinceEpoch});
    bool needSuperLog = true;
    Map<String, dynamic> requestHeaders = options.headers;
    if (requestHeaders.containsKey(needSuperLogKey)) {
      needSuperLog = requestHeaders[needSuperLogKey];
    }
    if (printLog && needSuperLog) {
      try {
        xbLog("request start  ${DateTime.now().microsecondsSinceEpoch}-------\n"
            "method: ${options.method}\n"
            "baseurl: ${options.baseUrl}\n"
            "path: ${options.path}\n"
            "data: ${jsonEncode(options.data)}\n"
            "queryParameters: ${jsonEncode(options.queryParameters)}\n"
            "header: ${jsonEncode(options.headers)}\n"
            "request end-------\n");
      } catch (e) {
        xbLog("打印请求的时候出错了：$e");
      }
    }
    super.onRequest(options, handler);
  }
}
