import 'dart:convert';

import 'package:http/http.dart' as http;

import 'xb_ume_network_reporter.dart';

class XBUmeHttpClient extends http.BaseClient {
  XBUmeHttpClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final requestId = XBUmeNetworkReporter.begin(
      method: request.method,
      url: request.url,
      requestHeaders: request.headers.cast<String, dynamic>(),
      requestBody: _requestBody(request),
    );

    try {
      final response = await _inner.send(request);
      final bytes = await response.stream.toBytes();
      XBUmeNetworkReporter.complete(
        requestId,
        statusCode: response.statusCode,
        responseHeaders: response.headers.cast<String, dynamic>(),
        responseBody: _decodeBody(bytes),
      );

      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        response.statusCode,
        contentLength: bytes.length,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (e, s) {
      XBUmeNetworkReporter.fail(requestId, error: e, stackTrace: s);
      rethrow;
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }

  dynamic _requestBody(http.BaseRequest request) {
    if (request is http.Request) {
      return request.body;
    }
    if (request is http.MultipartRequest) {
      return <String, dynamic>{
        'fields': request.fields,
        'files': request.files
            .map(
              (e) => <String, dynamic>{
                'field': e.field,
                'filename': e.filename,
                'length': e.length,
                'contentType': e.contentType.toString(),
              },
            )
            .toList(growable: false),
      };
    }
    return null;
  }

  dynamic _decodeBody(List<int> bytes) {
    if (bytes.isEmpty) return null;
    try {
      final text = utf8.decode(bytes);
      if (text.isEmpty) return null;
      try {
        return json.decode(text);
      } catch (_) {
        return text;
      }
    } catch (_) {
      return '<binary ${bytes.length} bytes>';
    }
  }
}
