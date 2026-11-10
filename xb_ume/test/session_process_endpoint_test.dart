// IDE 拉起的会话发现：从进程命令行里取 auth code（token）。
//
// flutter_tools 起 dds 时会带上 `--vm-service-uri=http://127.0.0.1:<port>/<token>=/`，
// 裸端口探测只会拿到 403，只能用这条命令行里的 token 拼出可接入的 ws 地址。
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

DiscoveredSession _session(int port, String fp) => DiscoveredSession(
      wsUrl: 'ws://127.0.0.1:$port/ws',
      port: port,
      source: 'port:$port',
      fingerprint: fp,
      name: 'vm',
    );

void main() {
  test('合并发现结果：已接入的实例不会从列表里消失', () {
    // 第 1 轮扫到 A 并接入；第 2 轮扫描因指纹已知扫不到任何东西。
    final first = mergeDiscoveredSessions(
      discovered: <DiscoveredSession>[_session(5000, 'f1')],
      alive: const <DiscoveredSession>[],
    );
    expect(first.map((e) => e.fingerprint), <String>['f1']);

    final second = mergeDiscoveredSessions(
      discovered: const <DiscoveredSession>[],
      alive: <DiscoveredSession>[_session(5000, 'f1')],
    );
    expect(second.map((e) => e.fingerprint), <String>['f1']);
  });

  test('合并发现结果：同指纹去重且本轮结果优先，按端口排序', () {
    final merged = mergeDiscoveredSessions(
      discovered: <DiscoveredSession>[_session(5002, 'f2')],
      alive: <DiscoveredSession>[
        _session(5001, 'f1'),
        _session(5009, 'f2'),
      ],
    );
    expect(merged.map((e) => e.fingerprint).toList(), <String>['f1', 'f2']);
    expect(merged.map((e) => e.port).toList(), <int>[5001, 5002]);
  });

  test('解析 dds 的 --vm-service-uri（带 token）', () {
    final list = parseVmServiceEndpoints(
      '/path/dart development-service '
      '--vm-service-uri=http://127.0.0.1:55636/Fme-K1ZtQl4=/ '
      '--bind-address=127.0.0.1 --bind-port=0',
    );
    expect(list, hasLength(1));
    expect(list.single.port, 55636);
    expect(
      list.single.getVmUri.toString(),
      'http://127.0.0.1:55636/Fme-K1ZtQl4=/getVM',
    );
    expect(list.single.wsUrl, 'ws://127.0.0.1:55636/Fme-K1ZtQl4=/ws');
  });

  test('不带 token 的地址也能解析', () {
    final list = parseVmServiceEndpoints(
      'dart development-service --vm-service-uri=http://127.0.0.1:8181/',
    );
    expect(list.single.wsUrl, 'ws://127.0.0.1:8181/ws');
    expect(list.single.getVmUri.toString(), 'http://127.0.0.1:8181/getVM');
  });

  test('命令行里直接给的 ws 地址（带 token）', () {
    final list = parseVmServiceEndpoints(
      'some-tool --uri ws://127.0.0.1:4321/abc=/ws --verbose',
    );
    expect(list.single.port, 4321);
    expect(list.single.wsUrl, 'ws://127.0.0.1:4321/abc=/ws');
    expect(list.single.getVmUri.toString(), 'http://127.0.0.1:4321/abc=/getVM');
  });

  test('非回环地址不认（设备侧地址本机连不上）', () {
    expect(
      parseVmServiceEndpoints(
        'dart development-service --vm-service-uri=http://10.2.5.201:8080/tok=/',
      ),
      isEmpty,
    );
  });

  test('探测地址里的 getVM 不算 token', () {
    final endpoint = vmEndpointFromHttpUrl('http://127.0.0.1:9000/getVM');
    expect(endpoint, isNotNull);
    expect(endpoint!.wsUrl, 'ws://127.0.0.1:9000/ws');
  });

  test('同一实例出现多行只保留一条，按端口排序', () {
    final list = parseVmServiceEndpoints(
      'a ws://127.0.0.1:9002/x=/ws b --vm-service-uri=http://127.0.0.1:9001/y=/',
    );
    expect(list.map((e) => e.port).toList(), <int>[9001, 9002]);
  });

  test('空串与乱码不崩', () {
    expect(parseVmServiceEndpoints(''), isEmpty);
    expect(parseVmServiceEndpoints('--vm-service-uri=not-a-url'), isEmpty);
    expect(parseVmServiceEndpoints('ws://127.0.0.1:abc/ws'), isEmpty);
  });

  test('裸探测 403、带 token 探测命中（auth code 生效时的真实情形）', () async {
    final server = await _serve((req) {
      if (req.uri.path == '/getVM') {
        req.response.statusCode = 403;
        req.response.close();
        return;
      }
      if (req.uri.path == '/TOK/getVM') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'result': <String, Object?>{
            'type': 'VM',
            'name': 'vm',
            'isolates': <Object?>[
              <String, Object?>{'id': 'isolates/1'},
              <String, Object?>{'id': 'isolates/2'},
            ],
          },
        }));
        req.response.close();
        return;
      }
      req.response.statusCode = 404;
      req.response.close();
    });
    addTearDown(() => server.close(force: true));

    // 端口扫描这条路依旧拿不到（403）。
    expect(await probeVmService(server.port), isNull);

    // 命令行这条路：token 拼进路径后可以命中。
    final endpoint = vmEndpointFromHttpUrl('http://127.0.0.1:${server.port}/TOK/');
    expect(endpoint, isNotNull);
    final probe = await probeVmServiceAt(endpoint!.getVmUri);
    expect(probe, isNotNull);
    expect(probe!.fingerprint, 'isolates/1|isolates/2');
  });
}
