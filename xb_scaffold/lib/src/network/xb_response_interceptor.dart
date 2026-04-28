import 'dart:convert';
import 'package:dio/dio.dart';
import '../xb_print.dart';
import 'xb_dio_config.dart';
export 'xb_dio_config.dart';

bool _needSuperLog(RequestOptions options) {
  final extraValue = options.extra[needSuperLogKey];
  if (extraValue is bool) return extraValue;
  final headerValue = options.headers[needSuperLogKey];
  if (headerValue is bool) return headerValue;
  return true;
}

class XBResponseInterceptor extends Interceptor {
  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final needSuperLog = _needSuperLog(response.requestOptions);
    if (printLog && needSuperLog) {
      try {
        xbLog(
            "response start  ${DateTime.now().microsecondsSinceEpoch}-------\n"
            "method: ${response.requestOptions.method}\n"
            "baseurl: ${response.requestOptions.baseUrl}\n"
            "path: ${response.requestOptions.path}\n"
            "request headers: ${jsonEncode(response.requestOptions.headers)}\n"
            "request data: ${jsonEncode(response.requestOptions.data)}\n"
            "request queryParameters: ${jsonEncode(response.requestOptions.queryParameters)}\n"
            "statusCode: ${response.statusCode}\n"
            "response data: ${jsonEncode(response.data)}\n"
            "response header: \n${response.headers}\n"
            "response end-------\n");
      } catch (e) {
        xbLog("打印响应的时候出错了：$e");
      }
    }
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final needSuperLog = _needSuperLog(err.requestOptions);
    if (printLog && needSuperLog) {
      try {
        xbLog("error start  ${DateTime.now().microsecondsSinceEpoch}-------\n"
            "method: ${err.requestOptions.method}\n"
            "baseurl: ${err.requestOptions.baseUrl}\n"
            "path: ${err.requestOptions.path}\n"
            "request headers: ${jsonEncode(err.requestOptions.headers)}\n"
            "request data: ${jsonEncode(err.requestOptions.data)}\n"
            "request queryParameters: ${jsonEncode(err.requestOptions.queryParameters)}\n"
            "response: ${err.response.toString()}\n"
            "error end-------\n");
      } catch (e) {
        xbLog("打印错误的时候出错了：$e");
      }
    }
    super.onError(err, handler);
  }
}
