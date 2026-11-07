// 直连通道的 SessionApi 实现（P2）：端点映射 + 整形回 VM 原始串格式。
//
// 这一层的唯一契约是「与 VM 表达式输出的原始串逐字节同格式」，所以断言直接
// 比对 `\u0001` / `\u0003` 分隔的字符串——工具/场景/测试里的解析代码都靠它。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/session/agent_client.dart';
import '../bin/src/session/agent_session_api.dart';
import '../bin/src/session/session_api.dart';

const String sep = '\u0001';
const String row = '\u0003';

void main() {
  late HttpServer server;
  late AgentSessionApi api;
  // path -> {query, body}：断言端点与入参。
  late Map<String, Map<String, Object?>> sent;
  // path -> (status, body)。
  late Future<(int, Object?)> Function(HttpRequest req, Map<String, Object?> body)
      serve;

  setUp(() async {
    sent = <String, Map<String, Object?>>{};
    serve = (req, body) async => (404, <String, Object?>{'error': '未打桩'});
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      final decoded = raw.isEmpty
          ? <String, Object?>{}
          : (jsonDecode(raw) as Map).cast<String, Object?>();
      sent[req.uri.path] = <String, Object?>{
        'query': req.uri.queryParameters,
        'body': decoded,
      };
      final (code, payload) = await serve(req, decoded);
      req.response.statusCode = code;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(payload));
      await req.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    api = AgentSessionApi(AgentClient(base), uri: base);
  });

  tearDown(() async {
    await server.close(force: true);
  });

  group('数据面整形', () {
    test('网络摘要列序与 VM 版一致，分隔符进 URL 会被清洗', () async {
      serve = (req, body) async => (200, <String, Object?>{
            'items': <Map<String, Object?>>[
              <String, Object?>{
                'method': 'GET',
                'url': 'https://a.b/c$sep$row',
                'statusCode': '200',
                'status': 'success',
                'durationMs': '12',
                'time': '2026-01-01T00:00:00.000',
                'error': '',
              },
            ],
          });
      final raw = await api.networkRaw(sinceMs: 100, limit: 10);
      expect(
        raw,
        'GET${sep}https://a.b/c  ${sep}200${sep}success${sep}12'
        '${sep}2026-01-01T00:00:00.000$sep$row',
      );
      final q = (sent['/v1/network']!['query'] as Map).cast<String, String>();
      expect(q['limit'], '10');
      expect(q['sinceMs'], '100');
    });

    test('日志 withPath 先插 #path 行，tail=false 按窗口切', () async {
      serve = (req, body) async {
        if (req.uri.path == '/v1/state') {
          return (200, <String, Object?>{'logFilePath': '/tmp/app.log'});
        }
        return (200, <String, Object?>{
          'items': <Map<String, Object?>>[
            for (var i = 0; i < 3; i++)
              <String, Object?>{
                'level': 'info',
                'tag': 't$i',
                'message': 'm$i',
                'time': '2026-01-01T00:00:0$i.000',
              },
          ],
        });
      };
      final tail = await api.consoleRaw(withPath: true);
      expect(tail, startsWith('#path$sep/tmp/app.log$row'));
      expect(tail, contains('info${sep}t2${sep}m2${sep}2026'));
      final win = await api.consoleRaw(limit: 1, offset: 1, tail: false);
      expect(win, 'info${sep}t1${sep}m1${sep}2026-01-01T00:00:01.000$row');
    });

    test('异常行 13 列，时间转毫秒，kind/type 过滤生效', () async {
      serve = (req, body) async => (200, <String, Object?>{
            'items': <Map<String, Object?>>[
              <String, Object?>{
                'time': '2026-01-02T00:00:00.000Z',
                'kind': 'flutter',
                'type': 'StateError',
                'count': 2,
                'message': 'boom',
                'library': 'x',
                'context': 'ctx',
                'stack': '#0 a',
                'widget': 'Home',
                'widgetFile': 'home.dart',
                'widgetLine': '12',
                'widgetColumn': '3',
              },
              <String, Object?>{
                'time': '2026-01-02T00:00:01.000Z',
                'kind': 'platform',
                'type': 'MissingPluginException',
                'message': 'other',
              },
            ],
          });
      final raw = await api.exceptionsRaw(kind: 'flutter');
      final lines = raw.split(row).where((l) => l.isNotEmpty).toList();
      expect(lines.length, 1);
      final f = lines.single.split(sep);
      expect(f.length, 13);
      expect(f[0], '2026-01-02T00:00:00.000Z');
      expect(f[1], '${DateTime.parse('2026-01-02T00:00:00.000Z').millisecondsSinceEpoch}');
      expect(f[3], 'StateError');
      expect(f[4], '2');
      expect(f[8], '#0 a');
      expect(f[11], '12');
      expect(f[12], '3');
      expect(await api.exceptionsRaw(typeContains: 'Missing'), contains('MissingPlugin'));
    });

    test('时间轴按类型拼不同列数', () async {
      serve = (req, body) async => (200, <String, Object?>{
            'items': <Map<String, Object?>>[
              <String, Object?>{
                't': 'route',
                'ms': 1000,
                'action': 'push',
                'name': '/home',
                'prev': '/',
                'phase': 'idle',
              },
              <String, Object?>{
                't': 'net',
                'ms': 2000,
                'method': 'GET',
                'code': '200',
                'dur': '9',
                'status': 'success',
                'url': 'https://a.b',
                'err': '',
              },
              <String, Object?>{'t': 'unknown', 'ms': 3000},
            ],
          });
      final raw = await api.timelineRaw(sinceMs: 500, limit: 10);
      final rows = raw.split(row).where((r) => r.isNotEmpty).toList();
      expect(rows.length, 2);
      final r0 = rows[0].split(sep);
      expect(r0[0], 'route');
      expect(r0[1], '1000');
      expect(r0[2], DateTime.fromMillisecondsSinceEpoch(1000).toIso8601String());
      expect(r0.sublist(3), <String>['push', '/home', '/', 'idle']);
      final r1 = rows[1].split(sep);
      expect(r1.sublist(0, 8), <String>['net', '2000', r1[2], 'GET', '200', '9', 'success', 'https://a.b']);
    });

    test('网络记录只回断言需要的四列，并按 since 过滤', () async {
      serve = (req, body) async => (200, <String, Object?>{
            'items': <Map<String, Object?>>[
              <String, Object?>{
                'method': 'GET',
                'url': 'https://old',
                'statusCode': '200',
                'status': 'success',
                'time': '2026-01-01T00:00:00.000',
              },
              <String, Object?>{
                'method': 'POST',
                'url': 'https://new',
                'statusCode': '500',
                'status': 'failure',
                'time': '2026-01-02T00:00:00.000',
              },
            ],
          });
      final items = await api.networkRecords(
        since: DateTime.parse('2026-01-01T12:00:00.000'),
      );
      expect(items.length, 1);
      expect(items.single, <String, String>{
        'method': 'POST',
        'url': 'https://new',
        'statusCode': '500',
        'status': 'failure',
      });
    });
  });

  group('组件树与画面', () {
    test('findWidget 直接用 app 的 raw，缺字段回 NOT_FOUND', () async {
      serve = (req, body) async => (200, <String, Object?>{
            'raw': <String>[
              '0',
              '1',
              'ElevatedButton',
              '',
              '0,0,10,10',
              'OK',
              '',
            ].join(sep) + row,
          });
      final raw = await api.findWidgetRaw(by: 'type', value: 'ElevatedButton');
      expect(raw, contains('ElevatedButton'));
      final q = (sent['/v1/widgets']!['query'] as Map).cast<String, String>();
      expect(q['by'], 'type');
      expect(q['value'], 'ElevatedButton');
      expect(q['exact'], '0');

      serve = (req, body) async => (200, <String, Object?>{'ok': true});
      expect(await api.findWidgetRaw(by: 'type', value: 'X'), 'NOT_FOUND');
    });

    test('center / assert / pagetext 取 result 与 text', () async {
      serve = (req, body) async {
        if (req.uri.path == '/v1/center') {
          return (200, <String, Object?>{'ok': true, 'result': '10.0,20.0'});
        }
        if (req.uri.path == '/v1/assert') {
          return (200, <String, Object?>{'ok': true, 'result': 'FOUND'});
        }
        return (200, <String, Object?>{'ok': true, 'text': 'a\u0002b'});
      };
      expect(await api.elementCenterRaw(3), '10.0,20.0');
      expect(await api.assertVisibleRaw('Text'), 'FOUND');
      expect(await api.pageTextRaw(limit: 5), 'a\u0002b');
      final cq = (sent['/v1/center']!['query'] as Map).cast<String, String>();
      expect(cq['ref'], '3');
    });

    test('screenInfo 读 dpr/宽/高，读不到返回 null', () async {
      serve = (req, body) async => (200, <String, Object?>{
            'ok': true,
            'dpr': 2.5,
            'width': 400.0,
            'height': 800.0,
          });
      expect(await api.screenInfo(), (400.0, 800.0, 2.5));

      serve = (req, body) async => (500, <String, Object?>{'error': 'boom'});
      expect(await api.screenInfo(), isNull);
    });

    test('screenshot 取 data，ok=false 抛错', () async {
      serve = (req, body) async => (200, <String, Object?>{'ok': true, 'data': 'iVBORw0='});
      expect(await api.screenshotBase64(), 'iVBORw0=');

      serve = (req, body) async =>
          (200, <String, Object?>{'ok': false, 'error': 'app 尚未渲染首帧'});
      expect(api.screenshotBase64(), throwsA(isA<AgentHttpError>()));
    });

    test('wtree 原样返回 app 侧结构', () async {
      serve = (req, body) async => (200, <String, Object?>{
            'ok': true,
            'nodes': <Object?>[
              <String, Object?>{'d': 0, 't': 'MyApp', 'k': '', 'b': null},
            ],
            'dpr': 2,
            'physW': 800,
            'physH': 1600,
          });
      final tree = await api.widgetTreeJson();
      expect(tree['ok'], isTrue);
      expect((tree['nodes'] as List).length, 1);
    });
  });

  group('动作端点', () {
    setUp(() {
      serve = (req, body) async {
        switch (req.uri.path) {
          case '/v1/tap':
            return (200, <String, Object?>{'ok': true, 'result': 'OK'});
          case '/v1/input':
            return (200, <String, Object?>{'ok': true, 'result': 'OK'});
          case '/v1/navigate':
            return (200, <String, Object?>{'ok': true, 'result': 'OK'});
          case '/v1/swipe':
            return (
              200,
              <String, Object?>{'ok': false, 'result': 'BUSY', 'error': '帧中'}
            );
          default:
            return (404, <String, Object?>{'error': '未知端点'});
        }
      };
    });

    test('tap 按 ref 或坐标走同一个端点', () async {
      expect(await api.tapRef(7), 'OK');
      expect(sent['/v1/tap']!['body'], <String, Object?>{'ref': 7});

      expect(await api.tapAt(1.5, 2.5), 'OK');
      expect(sent['/v1/tap']!['body'], <String, Object?>{'x': 1.5, 'y': 2.5});

      expect(await api.tapAt(15, 25, phys: true), 'OK');
      expect(sent['/v1/tap']!['body'], <String, Object?>{
        'x': 15,
        'y': 25,
        'phys': true,
      });
    });

    test('input 用 JSON body 传文本（换行/引号不拆坏）', () async {
      expect(await api.inputText('a\n"b"'), 'OK');
      expect(sent['/v1/input']!['body'], <String, Object?>{'text': 'a\n"b"'});
    });

    test('navigate 传 op/name', () async {
      expect(await api.routeOp('push', name: '/detail'), 'OK');
      expect(sent['/v1/navigate']!['body'],
          <String, Object?>{'op': 'push', 'name': '/detail'});
      expect(await api.routeOp('pop'), 'OK');
      expect(sent['/v1/navigate']!['body'],
          <String, Object?>{'op': 'pop', 'name': ''});
    });

    test('swipe 回 (result, error) 二元组', () async {
      final (result, err) = await api.swipe(
        x1: 1,
        y1: 2,
        x2: 3,
        y2: 4,
        durationMs: 120,
        phys: true,
      );
      expect(result, 'BUSY');
      expect(err, '帧中');
      expect(sent['/v1/swipe']!['body'], <String, Object?>{
        'x1': 1.0,
        'y1': 2.0,
        'x2': 3.0,
        'y2': 4.0,
        'durationMs': 120,
        'phys': true,
      });
    });
  });

  group('路由重放', () {
    Future<List<String>> replay(List<Map<String, Object?>> events) async {
      serve = (req, body) async => (200, <String, Object?>{'items': events});
      return api.routeNames();
    }

    test('push/pop 后栈顶是仍在显示的路由', () async {
      final names = await replay(<Map<String, Object?>>[
        {'action': 'push', 'routeName': '/'},
        {'action': 'push', 'routeName': '/a'},
        {'action': 'push', 'routeName': '/b'},
        {'action': 'pop', 'routeName': '/b', 'previousRouteName': '/a'},
      ]);
      expect(names, <String>['/', '/a']);
    });

    test('replace 换掉旧页，remove 按名剔除', () async {
      expect(
        await replay(<Map<String, Object?>>[
          {'action': 'push', 'routeName': '/'},
          {'action': 'push', 'routeName': '/a'},
          {'action': 'replace', 'routeName': '/b', 'previousRouteName': '/a'},
          {'action': 'push', 'routeName': '/c'},
          {'action': 'remove', 'routeName': '/b', 'previousRouteName': '/c'},
        ]),
        <String>['/', '/c'],
      );
    });

    test('事件窗口被截断时用最新事件兜底', () async {
      expect(
        await replay(<Map<String, Object?>>[
          {'action': 'pop', 'routeName': '/gone', 'previousRouteName': '/home'},
        ]),
        <String>['/home'],
      );
      expect(
        await replay(<Map<String, Object?>>[
          {'action': 'push', 'routeName': '/home'},
        ]),
        <String>['/home'],
      );
      expect(await replay(<Map<String, Object?>>[]), isEmpty);
      expect(await api.topRoute(), isNull);
    });

    test('topRoute 取栈顶', () async {
      serve = (req, body) async => (200, <String, Object?>{
            'items': <Map<String, Object?>>[
              {'action': 'push', 'routeName': '/'},
              {'action': 'push', 'routeName': '/detail'},
            ],
          });
      expect(await api.topRoute(), '/detail');
    });
  });

  group('做不到的语义', () {
    test('路由栈详情 / 帧统计 / 任意求值 抛 SessionApiUnsupported', () async {
      await expectLater(
        api.routeStackRaw(),
        throwsA(isA<SessionApiUnsupported>()
            .having((e) => e.cap, 'cap', 'route:stack')),
      );
      await expectLater(
        api.framesRaw(),
        throwsA(isA<SessionApiUnsupported>().having((e) => e.cap, 'cap', 'perf')),
      );
      await expectLater(
        api.evalRaw('package:flutter/x.dart', '1+1'),
        throwsA(
            isA<SessionApiUnsupported>().having((e) => e.cap, 'cap', 'debug')),
      );
    });

    test('connectSessionApi 按 uri 前缀选实现', () {
      final a = connectSessionApi('http://127.0.0.1:1');
      expect(a.isAgent, isTrue);
      expect(a.vmClient, isNull);
      final v = connectSessionApi('ws://127.0.0.1:2/ws');
      expect(v.isAgent, isFalse);
      expect(v.vmClient, isNotNull);
    });
  });
}