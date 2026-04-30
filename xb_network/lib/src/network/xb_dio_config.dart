import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'xb_request_interceptor.dart';
import 'xb_response_interceptor.dart';

const int _timeout = 20;

bool _printLog = true;
bool get printLog => _printLog;

const String needSuperLogKey = 'needSuperLog';

class XBDioConfig {
  static Dio? _dio;
  static Dio? get dioOrNull => _dio;
  static bool get isInitialized => _dio != null;

  static Dio get dio {
    assert(_dio != null, '请先调用init方法');
    return _dio!;
  }

  static void init({
    required String baseUrl,
    int? connectTimeout,
    int? sendTimeout,
    int? receiveTimeout,
    XBRequestInterceptor? requestInterceptor,
    XBResponseInterceptor? responseInterceptor,
    bool force = false,
  }) {
    if (_dio != null && !force) return;
    if (force) {
      _dio?.close(force: true);
    }
    _dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: Duration(seconds: connectTimeout ?? _timeout),
        sendTimeout: Duration(seconds: sendTimeout ?? _timeout),
        receiveTimeout: Duration(seconds: receiveTimeout ?? _timeout),
      ),
    );
    _dio!.interceptors.addAll([
      requestInterceptor ?? XBRequestInterceptor(),
      responseInterceptor ?? XBResponseInterceptor(),
    ]);
    _printLog = kDebugMode;
  }

  static void reset() {
    _dio?.close(force: true);
    _dio = null;
    _printLog = true;
  }
}
