import 'dart:convert';

import 'package:dio/dio.dart';

import '../xb_print.dart';
import 'xb_dio_config.dart';

class XBRequestInterceptor extends Interceptor {
  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    if (printLog) {
      try {
        xbLog("request start-------\n"
            "method: ${options.method}\n"
            "baseurl: ${options.baseUrl}\n"
            "path: ${options.path}\n"
            "data: ${jsonEncode(options.data)}\n"
            "header: ${jsonEncode(options.headers)}\n"
            "request end-------\n");
      } catch (e) {
        xbLog("打印请求的时候出错了：$e");
      }
    }
    super.onRequest(options, handler);
  }
}
