import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
export 'xb_dio_config.dart';
export 'xb_request_interceptor.dart';
export 'xb_response_interceptor.dart';

class XBHttp {
  static const String getMethod = "GET";

  static Future<E> request<E>(String url,
      {String method = getMethod,
      Map<String, dynamic>? queryParams, //这个是拼接在url后面的参数
      dynamic bodyParams, //这个是放在body里面的参数
      Map<String, dynamic>? headers,
      CancelToken? cancelToken,
      Interceptor? inter,
      bool needLog = true}) async {
    final options = Options(
      method: method,
      headers: headers,
      extra: {needSuperLogKey: needLog},
    );
    final dio = _configuredDio(inter);
    try {
      final response = await dio.request<dynamic>(url,
          cancelToken: cancelToken,
          options: options,
          queryParameters: queryParams,
          data: bodyParams);
      return _decodeData<E>(response.data);
    } on DioException catch (e, s) {
      _print(info: "request err：$e", needLog: needLog);
      Error.throwWithStackTrace(e, s);
    }
  }

  static Future<E> get<E>(String url,
      {Map<String, dynamic>? queryParams,
      Map<String, dynamic>? headers,
      CancelToken? cancelToken,
      Interceptor? inter,
      bool needLog = true}) async {
    return XBHttp.request(url,
        queryParams: queryParams,
        headers: headers,
        cancelToken: cancelToken,
        inter: inter,
        needLog: needLog);
  }

  static Future<E> post<E>(String url,
      {Map<String, dynamic>? queryParams,
      dynamic bodyParams,
      Map<String, dynamic>? headers,
      CancelToken? cancelToken,
      Interceptor? inter,
      bool needLog = true}) async {
    return XBHttp.request(url,
        method: 'POST',
        queryParams: queryParams,
        bodyParams: bodyParams,
        headers: headers,
        cancelToken: cancelToken,
        inter: inter,
        needLog: needLog);
  }

  static Future<E> put<E>(String url,
      {Map<String, dynamic>? queryParams,
      dynamic bodyParams,
      Map<String, dynamic>? headers,
      CancelToken? cancelToken,
      Interceptor? inter,
      bool needLog = true}) async {
    return XBHttp.request(url,
        method: 'PUT',
        queryParams: queryParams,
        bodyParams: bodyParams,
        headers: headers,
        cancelToken: cancelToken,
        inter: inter,
        needLog: needLog);
  }

  static Future<E> delete<E>(String url,
      {Map<String, dynamic>? queryParams,
      dynamic bodyParams,
      Map<String, dynamic>? headers,
      CancelToken? cancelToken,
      Interceptor? inter,
      bool needLog = true}) async {
    return XBHttp.request(url,
        method: 'DELETE',
        queryParams: queryParams,
        bodyParams: bodyParams,
        headers: headers,
        cancelToken: cancelToken,
        inter: inter,
        needLog: needLog);
  }

  /// dio 实现文件上传
  /// 是编译以后的文件路径，不是asset/.....png这样的
  static Future<E> fileUploadFromPath<E>(
    String url,
    String filePath,
    String filename, {
    Map<String, dynamic>? headers,
    bool needLog = true,
    CancelToken? cancelToken,
    Interceptor? inter,
  }) async {
    return _fileUpload(
        url, await MultipartFile.fromFile(filePath, filename: filename),
        headers: headers,
        needLog: needLog,
        cancelToken: cancelToken,
        inter: inter);
  }

  static Future<E> fileUploadFromBytes<E>(
    String url,
    Uint8List bytes,
    String filename, {
    Map<String, dynamic>? headers,
    bool needLog = true,
    CancelToken? cancelToken,
    Interceptor? inter,
  }) async {
    return _fileUpload(url, MultipartFile.fromBytes(bytes, filename: filename),
        headers: headers,
        needLog: needLog,
        cancelToken: cancelToken,
        inter: inter);
  }

  static Future<E> _fileUpload<E>(
    String url,
    MultipartFile multipartFile, {
    Map<String, dynamic>? headers,
    bool needLog = true,
    CancelToken? cancelToken,
    Duration? sendTimeout,
    Duration? receiveTimeout,
    Interceptor? inter,
  }) async {
    try {
      final options = Options(
          headers: headers,
          extra: {needSuperLogKey: needLog},
          sendTimeout: sendTimeout ?? const Duration(seconds: 60),
          receiveTimeout: receiveTimeout ?? const Duration(seconds: 60));

      final dio = _uploadDio(inter);

      final formData = FormData.fromMap({"file": multipartFile});

      /// 发送post
      final response = await dio.post<dynamic>(
        url, data: formData, options: options,
        cancelToken: cancelToken,

        /// 这里是发送请求回调函数
        /// [progress] 当前的进度
        /// [total] 总进度
        onSendProgress: (int progress, int total) {
          _print(info: "当前进度是 $progress 总进度是 $total", needLog: needLog);
        },
      );

      /// 服务器响应结果
      final data = response.data;

      _print(info: "fileUpload response.data : $data", needLog: needLog);

      return _decodeData<E>(data);
    } catch (e, s) {
      _print(info: "fileUpload err：$e", needLog: needLog);
      Error.throwWithStackTrace(e, s);
    }
  }

  static Dio _configuredDio(Interceptor? interceptor) {
    return _dioWithInterceptor(XBDioConfig.dio, interceptor);
  }

  static Dio _uploadDio(Interceptor? interceptor) {
    final dio = XBDioConfig.dioOrNull;
    if (dio != null) {
      return _dioWithInterceptor(dio, interceptor);
    }
    final uploadDio = Dio();
    if (interceptor != null) {
      uploadDio.interceptors.add(interceptor);
    }
    return uploadDio;
  }

  static Dio _dioWithInterceptor(Dio dio, Interceptor? interceptor) {
    if (interceptor == null) return dio;
    final requestDio = Dio(dio.options.copyWith());
    requestDio.httpClientAdapter = dio.httpClientAdapter;
    requestDio.transformer = dio.transformer;
    requestDio.interceptors.addAll(dio.interceptors);
    requestDio.interceptors.add(interceptor);
    return requestDio;
  }

  static E _decodeData<E>(dynamic data) {
    dynamic resolvedData;
    if (data is String) {
      try {
        resolvedData = json.decode(data);
      } on FormatException {
        resolvedData = data;
      }
    } else {
      resolvedData = data;
    }
    return resolvedData as E;
  }

  static void _print({required String info, bool needLog = true}) {
    if (needLog == false) return;
    xbLog(info);
  }
}
