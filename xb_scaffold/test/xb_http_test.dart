import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  tearDown(XBDioConfig.reset);

  test('XBHttp uses configured Dio and request interceptor', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      final fromInterceptor = request.headers.value('x-xb-test') == 'yes';
      request.response.headers.contentType = ContentType.text;
      request.response.write(
        '{"ok":$fromInterceptor,"path":"${request.uri.path}"}',
      );
      await request.response.close();
    });
    addTearDown(() async {
      await subscription.cancel();
      await server.close(force: true);
    });

    XBDioConfig.init(
      baseUrl: 'http://${server.address.address}:${server.port}',
      force: true,
    );

    final response = await XBHttp.get<Map<String, dynamic>>(
      '/status',
      inter: InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['x-xb-test'] = 'yes';
          handler.next(options);
        },
      ),
    );

    expect(response, {'ok': true, 'path': '/status'});
  });
}
