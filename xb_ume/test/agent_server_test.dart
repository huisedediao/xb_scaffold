// 直连 Agent 服务（P1）：端点形状、token 校验、只读边界。
//
// 这里起真实 HttpServer（回环），断言「GUI 代理过去时能直接渲染」的字段：
// 网络摘要/详情的形状与 /api/network 完全一致，异常/日志带完整字段。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/agent/xb_ume_agent.dart';
import 'package:xb_ume/xb_ume.dart';

class _MemoryPersistence implements XBUmePersistence {
  @override
  Future<Map<String, dynamic>?> load() async => null;

  @override
  Future<void> save(Map<String, dynamic> json) async {}
}

XBUmeController _controller() => XBUmeController(
      config: const XBUmeConfig(persistenceEnabled: false, logFileEnabled: false),
      persistence: _MemoryPersistence(),
    );

void main() {
  // 不初始化 TestWidgetsFlutterBinding：它会把 HttpClient 换成「一律 400」的
  // mock（HttpOverrides），真实回环请求就发不出去了。这里只用到 controller
  // 的纯数据能力，不需要 widget binding。
  late XBUmeController controller;
  late XBUmeAgentServer server;

  Future<Map<String, Object?>> call(
    String path, {
    String method = 'GET',
    String? token,
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    final client = HttpClient();
    try {
      final uri =
          Uri.parse('${server.baseUrl}$path').replace(queryParameters: query);
      final req = await client.openUrl(method, uri);
      if (token != null) req.headers.set('x-xbume-token', token);
      if (body != null) {
        final payload = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.headers.contentLength = payload.length;
        req.add(payload);
      } else if (method == 'POST') {
        req.headers.contentLength = 0;
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final parsed = text.isEmpty ? <String, Object?>{} : jsonDecode(text);
      return <String, Object?>{
        'status': res.statusCode,
        'body': parsed is Map ? parsed : <String, Object?>{'raw': parsed},
      };
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    // 兜底：万一将来有人加了 binding 初始化，也保证走真实 HttpClient。
    HttpOverrides.global = null;
    controller = _controller();
    final started = await startXBUmeAgentServer(
      controller: controller,
      options: const XBUmeAgentOptions(
        enabled: true,
        port: 0,
        appId: 'demo',
        packageName: 'com.demo.app',
      ),
    );
    expect(started, isNotNull, reason: '端口 0 应能绑到系统分配端口');
    server = started!;
  });

  tearDown(() async {
    await server.close();
    controller.dispose();
  });

  test('默认关闭：不写 --dart-define 时编译期开关为假', () {
    expect(kXBUmeAgentDefaultEnabled, isFalse);
    expect(XBUmeAgentOptions.fromEnvironment().enabled, isFalse);
  });

  test('默认关闭：enabled=false 不起服务', () async {
    final none = await startXBUmeAgentServer(
      controller: controller,
      options: const XBUmeAgentOptions(),
    );
    expect(none, isNull);
  });

  group('hello / state', () {
    test('hello 自报服务标识、包名与能力', () async {
      final r = await call('/v1/hello');
      final body = r['body'] as Map;
      expect(r['status'], 200);
      expect(body['service'], 'xbume-agent');
      expect(body['protocol'], 1);
      expect(body['packageName'], 'com.demo.app');
      expect((body['caps'] as List), contains('inspect'));
      expect(body['bootId'], isNotEmpty);
    });

    test('state 给缓冲区条数与能力，不含业务内容', () async {
      controller.addLog(
        level: XBUmeLogLevel.info,
        tag: 't',
        message: 'hi',
      );
      final body = (await call('/v1/state'))['body'] as Map;
      expect(body['logs'], 1);
      expect(body['exceptions'], 0);
      expect(body['caps'], contains('inspect'));
      expect(body['logFilePath'], '');
    });
  });

  group('日志与异常', () {
    test('日志支持 level / keyword / limit 过滤', () async {
      controller.addLog(level: XBUmeLogLevel.info, tag: 'a', message: 'one');
      controller.addLog(level: XBUmeLogLevel.error, tag: 'b', message: 'two');
      controller.addLog(level: XBUmeLogLevel.info, tag: 'a', message: 'three');

      final all = (await call('/v1/logs'))['body'] as Map;
      expect(all['total'], 3);
      expect((all['items'] as List).length, 3);

      final errs = (await call('/v1/logs', query: {'level': 'error'}))['body']
          as Map;
      expect((errs['items'] as List).length, 1);
      expect(((errs['items'] as List).first as Map)['message'], 'two');

      final byKw = (await call('/v1/logs', query: {'keyword': 'three'}))
          ['body'] as Map;
      expect((byKw['items'] as List).length, 1);

      final last = (await call('/v1/logs', query: {'limit': '2'}))['body']
          as Map;
      final items = last['items'] as List;
      expect(items.length, 2);
      expect((items.last as Map)['message'], 'three');
    });

    test('异常带类型/摘要/签名/次数，与 GUI 卡片字段对应', () async {
      controller.addException(
        error: StateError('boom'),
        message: 'boom detail',
        context: 'While building X',
      );
      final body = (await call('/v1/exceptions'))['body'] as Map;
      final item = (body['items'] as List).first as Map;
      expect(item['type'], 'StateError');
      expect(item['message'], 'boom detail');
      expect(item['context'], 'While building X');
      expect(item['signature'], isNotEmpty);
      expect(item['count'], 1);
      expect(item['time'], isNotEmpty);
    });
  });

  group('网络', () {
    test('列表字段与 /api/network 同形（状态码/耗时为字符串）', () async {
      final id = controller.startNetwork(
        method: 'get',
        url: Uri.parse('https://api.example.com/user?id=1'),
        requestHeaders: <String, dynamic>{'Authorization': 'secret'},
      );
      controller.completeNetwork(id, statusCode: 200, responseBody: '{"ok":1}');

      final body = (await call('/v1/network'))['body'] as Map;
      final item = (body['items'] as List).single as Map;
      expect(item['id'], id);
      expect(item['method'], 'GET');
      expect(item['url'], 'https://api.example.com/user?id=1');
      expect(item['statusCode'], '200');
      expect(item['status'], 'success');
      expect(item['error'], '');
      expect(item['durationMs'], isA<String>());
    });

    test('详情把头拍成 [{k,v}]，敏感头已打码', () async {
      final id = controller.startNetwork(
        method: 'GET',
        url: Uri.parse('https://api.example.com/x'),
        requestHeaders: <String, dynamic>{'Authorization': 'secret'},
      );
      final body = (await call('/v1/network/detail', query: {'id': id}))
          ['body'] as Map;
      final headers = (body['requestHeaders'] as List).cast<Map>();
      expect(headers.any((h) => h['k'] == 'Authorization'), isTrue);
      expect(
        headers.firstWhere((h) => h['k'] == 'Authorization')['v'],
        '***',
      );
      expect(body['initiatorStack'], '');
    });

    test('清空只接受 POST', () async {
      final denied = await call('/v1/network/clear');
      expect(denied['status'], 405);
      controller.startNetwork(method: 'GET', url: Uri.parse('https://a.b/c'));
      final ok = await call('/v1/network/clear', method: 'POST');
      expect(ok['status'], 200);
      expect(controller.network, isEmpty);
    });

    test('未知 id 返回 404 而不是空对象', () async {
      final r = await call('/v1/network/detail', query: {'id': 'nope'});
      expect(r['status'], 404);
      expect('${(r['body'] as Map)['error']}', contains('不存在'));
    });
  });

  group('路由 / 时间轴', () {
    test('时间轴条目字段与 GUI _tlItems 一致', () async {
      controller.addRoute(
        action: XBUmeRouteAction.push,
        routeName: '/home',
        previousRouteName: '/',
        phase: 'idle',
      );
      final id = controller.startNetwork(
        method: 'POST',
        url: Uri.parse('https://api.example.com/order'),
      );
      controller.failNetwork(id, statusCode: 500, error: 'boom');

      final body = (await call('/v1/timeline'))['body'] as Map;
      final items = (body['items'] as List).cast<Map>();
      expect(items.length, 2);
      final route = items.firstWhere((e) => e['t'] == 'route');
      expect(route['action'], 'push');
      expect(route['name'], '/home');
      expect(route['prev'], '/');
      expect(route['phase'], 'idle');
      expect(route['ms'], isA<int>());

      final net = items.firstWhere((e) => e['t'] == 'net');
      expect(net['method'], 'POST');
      expect(net['code'], '500');
      expect(net['status'], 'failure');
      expect(net['err'], 'boom');
    });

    test('路由事件单独可读，limit 取末尾', () async {
      for (var i = 0; i < 3; i++) {
        controller.addRoute(action: XBUmeRouteAction.push, routeName: '/p$i');
      }
      final body = (await call('/v1/routes', query: {'limit': '2'}))['body']
          as Map;
      final items = (body['items'] as List).cast<Map>();
      expect(items.length, 2);
      expect(items.last['routeName'], '/p2');
    });
  });

  group('安全边界', () {
    test('token 非空时数据端点必须带 token，hello 例外', () async {
      final guarded = await startXBUmeAgentServer(
        controller: controller,
        options: const XBUmeAgentOptions(
          enabled: true,
          port: 0,
          token: 'tk-123',
        ),
      );
      expect(guarded, isNotNull);
      final base = guarded!.baseUrl;
      Future<int> code(String path, {String? token}) async {
        final client = HttpClient();
        try {
          final req = await client.getUrl(Uri.parse('$base$path'));
          if (token != null) req.headers.set('x-xbume-token', token);
          final res = await req.close();
          await res.drain<void>();
          return res.statusCode;
        } finally {
          client.close(force: true);
        }
      }

      expect(await code('/v1/hello'), 200);
      expect(await code('/v1/state'), 401);
      expect(await code('/v1/state', token: 'bad'), 401);
      expect(await code('/v1/state', token: 'tk-123'), 200);
      await guarded.close();
    });

    test('未知端点 404；没有 eval / 执行类端点', () async {
      expect((await call('/v1/eval'))['status'], 404);
      expect((await call('/v1/exec'))['status'], 404);
      expect((await call('/v1/state', method: 'DELETE'))['status'], 405);
    });

    test('动作端点只收 POST（GET 405），不做任意求值', () async {
      for (final p in <String>[
        '/v1/tap',
        '/v1/input',
        '/v1/swipe',
        '/v1/navigate',
      ]) {
        final r = await call(p);
        expect(r['status'], 405, reason: '$p 应只支持 POST');
        expect('${(r['body'] as Map)['error']}', contains('POST'));
      }
    });

    test('动作端点缺参 400，且不需要求值/文件写入', () async {
      expect((await call('/v1/tap', method: 'POST'))['status'], 400);
      expect((await call('/v1/input', method: 'POST'))['status'], 400);
      expect((await call('/v1/swipe', method: 'POST'))['status'], 400);
      expect(
        (await call('/v1/navigate', method: 'POST', body: {'op': 'push'}))['status'],
        400,
      );
      expect((await call('/v1/widgets'))['status'], 400);
      expect((await call('/v1/center'))['status'], 400);
      expect((await call('/v1/assert'))['status'], 400);
    });

    test('无渲染树时返回结构化失败，不是 500', () async {
      // 本测试不初始化 widget binding：只验证「没首帧就不抛」的兜底分支。
      final wtree = await call('/v1/wtree');
      expect(wtree['status'], 200);
      expect((wtree['body'] as Map)['ok'], isFalse);
    });

    test('clear 只清指定缓冲，别的照旧', () async {
      controller.addLog(level: XBUmeLogLevel.info, tag: 't', message: 'x');
      controller.addRoute(action: XBUmeRouteAction.push, routeName: '/a');
      final r = await call('/v1/clear', method: 'POST', query: {'what': 'logs'});
      expect(r['status'], 200);
      expect(controller.logs, isEmpty);
      expect(controller.routes, isNotEmpty);
      final bad = await call('/v1/clear', method: 'POST', query: {'what': 'db'});
      expect(bad['status'], 400);
    });
  });
}