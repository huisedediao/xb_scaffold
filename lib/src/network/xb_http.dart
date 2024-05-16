import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBHttp {
  static const String getMethod = "GET";

  static Future<E> request<E>(String url,
      {String method = getMethod,
      Map<String, dynamic>? queryParams, //这个是拼接在url后面的参数
      dynamic bodyParams, //这个是放在body里面的参数
      Map<String, dynamic>? headers,
      CancelToken? cancelToken,
      bool needLog = true}) async {
    final options = Options(method: method, headers: headers);

    if (method == getMethod) {
      if (queryParams != null) {
        String getParamsStr = "";
        queryParams.forEach((key, value) {
          getParamsStr += (getParamsStr.isEmpty) ? "?" : "&";
          getParamsStr += "$key=$value";
        });
      }
    }
    try {
      Response response = await XBDioConfig.dio.request(url,
          cancelToken: cancelToken,
          options: options,
          queryParameters: queryParams,
          data: bodyParams);
      if (response.data is String) {
        _print(info: "response.data is String", needLog: needLog);
        if (response.data == "ok" || response.data.length == 0) {
          _print(info: "response.data is String 1", needLog: needLog);
          return response.data;
        } else {
          _print(info: "response.data is String 2", needLog: needLog);
          try {
            return json.decode(response.data);
          } catch (e) {
            return response.data;
          }
        }
      } else {
        _print(info: "response.data is not String", needLog: needLog);
        return response.data;
      }
    } on DioException catch (e) {
      _print(info: "捕捉到错误：$e", needLog: needLog);
      return Future.error(e);
    }
  }

  static Future<E> get<E>(String url,
      {Map<String, dynamic>? queryParams,
      Map<String, dynamic>? headers,
      CancelToken? cancelToken,
      bool needLog = true}) async {
    return await XBHttp.request(url,
        queryParams: queryParams,
        headers: headers,
        cancelToken: cancelToken,
        needLog: needLog);
  }

  static Future<E> post<E>(String url,
      {Map<String, dynamic>? queryParams,
      dynamic bodyParams,
      Map<String, dynamic>? headers,
      CancelToken? cancelToken,
      Interceptor? inter,
      bool needLog = true}) async {
    return await XBHttp.request(url,
        method: 'POST',
        queryParams: queryParams,
        bodyParams: bodyParams,
        headers: headers,
        cancelToken: cancelToken,
        needLog: needLog);
  }

  static Future<E> put<E>(String url,
      {Map<String, dynamic>? queryParams,
      dynamic bodyParams,
      Map<String, dynamic>? headers,
      CancelToken? cancelToken,
      Interceptor? inter,
      bool needLog = true}) async {
    return await XBHttp.request(url,
        method: 'PUT',
        queryParams: queryParams,
        bodyParams: bodyParams,
        headers: headers,
        cancelToken: cancelToken,
        needLog: needLog);
  }

  static Future<E> delete<E>(String url,
      {Map<String, dynamic>? queryParams,
      dynamic bodyParams,
      Map<String, dynamic>? headers,
      CancelToken? cancelToken,
      Interceptor? inter,
      bool needLog = true}) async {
    return await XBHttp.request(url,
        method: 'DELETE',
        queryParams: queryParams,
        bodyParams: bodyParams,
        headers: headers,
        cancelToken: cancelToken,
        needLog: needLog);
  }

  ///dio 实现文件上传
  ///是编译以后的文件路径，不是asset/.....png这样的
  static Future<E> fileUpload<E>(
    String url,
    String filePath,
    String filename, {
    Map<String, dynamic>? headers,
    bool needLog = true,
    CancelToken? cancelToken,
  }) async {
    xbLog("fileUpload,url:$url,headers:$headers");
    final options = Options(headers: headers);

    ///创建Dio
    Dio dio = Dio();

    Map<String, dynamic> map = {};
    map["file"] = await MultipartFile.fromFile(filePath, filename: filename);

    ///通过FormData
    FormData formData = FormData.fromMap(map);

    ///发送post
    Response response = await dio.post(
      url, data: formData, options: options,
      cancelToken: cancelToken,

      ///这里是发送请求回调函数
      ///[progress] 当前的进度
      ///[total] 总进度
      onSendProgress: (int progress, int total) {
        _print(info: "当前进度是 $progress 总进度是 $total", needLog: needLog);
      },
    );

    ///服务器响应结果
    var data = response.data;

    _print(info: "fileUpload response.data : $data", needLog: needLog);

    return data;
  }

  static _print({required String info, bool needLog = true}) {
    if (needLog == false) return;
    xbLog(info);
  }
}
