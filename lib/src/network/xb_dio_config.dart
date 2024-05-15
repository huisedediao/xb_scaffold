import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'xb_request_interceptor.dart';
import 'xb_response_interceptor.dart';

int get _timeout => kDebugMode ? 20 : 20;

bool _printLog = true;
bool get printLog => _printLog;

class XBDioConfig {
  static Dio? _dio;
  static Dio get dio {
    assert(_dio != null, "请先调用init方法");
    return _dio!;
  }

  static void init({
    required String baseUrl,
    int? connectTimeout,
    int? sendTimeout,
    int? receiveTimeout,
    XBRequestInterceptor? requestInterceptor,
    XBResponseInterceptor? responseInterceptor,
  }) {
    if (_dio == null) {
      _dio = Dio(
        BaseOptions(
          connectTimeout: Duration(seconds: connectTimeout ?? _timeout),
          sendTimeout: Duration(seconds: sendTimeout ?? _timeout),
          receiveTimeout: Duration(seconds: receiveTimeout ?? _timeout),
        ),
      );
      _dio!.options.baseUrl = baseUrl;
      _dio!.interceptors.addAll([
        requestInterceptor ?? XBRequestInterceptor(),
        responseInterceptor ?? XBResponseInterceptor(),
      ]);
      _printLog = kDebugMode;
    }
  }
}
