// 直连服务探测（P0）：/v1/hello 的解析与「非本服务」的负例。
//
// 起一个本地 HttpServer 冒充 app 内的直连服务，验证发现层只认
// `service=xbume-agent` 的响应，字段缺失时不炸、类型不对时不误判。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/session/discovery.dart';

Future<HttpServer> _serve(
  FutureOr<void> Function(HttpRequest) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  return server;
}

void _json(HttpRequest req, Object body) {
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  req.response.close();
}

void main() {
  test('解析 hello：包名 / 版本 / 能力 / vmPort / 混淆标记', () async {
    final server = await _serve((req) {
      _json(req, <String, Object?>{
        'service': 'xbume-agent',
        'appId': 'com.example.app',
        'packageName': 'com.example.app',
        'bootId': 'boot-9',
        'version': '0.9.6',
        'obfuscated': true,
        'caps': <String>['inspect', 'fs', 'act'],
        // 有些实现会把它当字符串吐出来。
        'vmPort': '40000',
      });
    });
    addTearDown(() => server.close(force: true));

    final agent = await probeAgent(server.port);
    expect(agent, isNotNull);
    expect(agent!.packageName, 'com.example.app');
    expect(agent.version, '0.9.6');
    expect(agent.obfuscated, isTrue);
    expect(agent.caps, <String>['inspect', 'fs', 'act']);
    expect(agent.vmPort, 40000);
    expect(agent.baseUrl, 'http://127.0.0.1:${server.port}');
    // 没有转发映射时 deviceId 为空，指纹用端口兑底（同一端口重启才变）。
    expect(agent.fingerprint, 'agent:port:${server.port}:com.example.app:boot-9');
  });

  test('缺字段也能解析（bootId 为空 → 指纹仍稳定）', () async {
    final server = await _serve((req) {
      _json(req, <String, Object?>{'service': 'xbume-agent'});
    });
    addTearDown(() => server.close(force: true));

    final agent = await probeAgent(server.port);
    expect(agent, isNotNull);
    expect(agent!.packageName, isEmpty);
    expect(agent.obfuscated, isFalse);
    expect(agent.caps, isEmpty);
    expect(agent.vmPort, isNull);
  });

  test('其他 HTTP 服务不误判（没有 service 标记）', () async {
    final server = await _serve((req) => _json(req, <String, Object?>{
          'hello': 'world',
        }));
    addTearDown(() => server.close(force: true));

    expect(await probeAgent(server.port), isNull);
  });

  test('返回非 JSON 不崩', () async {
    final server = await _serve((req) {
      req.response.headers.contentType = ContentType.html;
      req.response.write('<html>not a service</html>');
      req.response.close();
    });
    addTearDown(() => server.close(force: true));

    expect(await probeAgent(server.port), isNull);
  });

  test('端口无人监听时返回 null（不抛异常）', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close(force: true);
    expect(await probeAgent(port), isNull);
  });
}