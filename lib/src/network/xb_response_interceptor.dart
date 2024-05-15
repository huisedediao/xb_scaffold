import 'dart:convert';

import 'package:dio/dio.dart';

import '../xb_print.dart';
import 'xb_dio_config.dart';

class XBResponseInterceptor extends Interceptor {
  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (printLog) {
      try {
        xbLog("response start-------\n"
            "method: ${response.requestOptions.method}\n"
            "baseurl: ${response.requestOptions.baseUrl}\n"
            "path: ${response.requestOptions.path}\n"
            "request headers: ${jsonEncode(response.requestOptions.headers)}\n"
            "request data: ${jsonEncode(response.requestOptions.data)}\n"
            "request queryParameters: ${jsonEncode(response.requestOptions.queryParameters)}\n"
            "statusCode: ${response.statusCode}\n"
            "response data: ${jsonEncode(response.data)}\n"
            // "header: ${response.headers}"
            "response end-------\n");
      } catch (e) {
        xbLog("打印响应的时候出错了：$e");
      }
    }
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (printLog) {
      try {
        xbLog("error start-------\n"
            "method: ${err.requestOptions.method}\n"
            "baseurl: ${err.requestOptions.baseUrl}\n"
            "path: ${err.requestOptions.path}\n"
            "request headers: ${jsonEncode(err.requestOptions.headers)}\n"
            "request data: ${jsonEncode(err.requestOptions.data)}\n"
            "request queryParameters: ${jsonEncode(err.requestOptions.queryParameters)}\n"
            "response: ${err.response.toString()}\n"
            // "header: ${response.headers}"
            "error end-------\n");
      } catch (e) {
        xbLog("打印错误的时候出错了：$e");
      }
    }
    super.onError(err, handler);
  }
}
