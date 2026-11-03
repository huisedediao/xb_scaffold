// 新增 MCP 工具的三个入口：调试器直连、GUI 桥、工具箱控制。
//
// 这一层不碰真机：起一个本地 HTTP 服务冒充工具箱，验证
//   1) 工具注册表（分组 / 唯一性 / 关键参数）符合 --tool-groups 语义；
//   2) GuiBridge 的请求成形（GET query / POST 双写 / bodyOnly / 令牌重试 /
//      二进制 token 二次请求）与错误转译；
//   3) 桥接工具真的把参数转发到对应 /api/*（用 action + 显式 uri 绕过会话）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/registry.dart';
import '../bin/src/mcp/bridge_tools.dart';
import '../bin/src/mcp/debug_tools.dart';
import '../bin/src/mcp/device_tools.dart';
import '../bin/src/mcp/gui_bridge.dart';
import '../bin/src/mcp/protocol.dart';
import '../bin/src/mcp/scenario_service.dart';
import '../bin/src/mcp/session_registry.dart';
import '../bin/src/mcp/toolbox_tools.dart';
import '../bin/src/mcp/tools.dart';

/// 冒充工具箱：记录每个请求，按路径回固定 JSON。
class _FakeGui {
  _FakeGui._(this.server);

  final HttpServer server;
  final List<Map<String, Object?>> seen = <Map<String, Object?>>[];
  int _downCalls = 0;

  int get port => server.port;

  static Future<_FakeGui> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeGui._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> _handle(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    seen.add(<String, Object?>{
      'method': req.method,
      'path': req.uri.path,
      'query': req.uri.queryParameters,
      'body': body,
      'token': req.headers.value('x-xbume-token'),
    });
    final res = req.response;
    res.headers.contentType = ContentType.json;
    void json(Object? v) => res.write(jsonEncode(v));

    switch (req.uri.path) {
      case '/api/version':
        json(<String, Object?>{'version': 'test', 'port': server.port});
      case '/api/timeline/clear':
        json(<String, Object?>{'ok': true});
      case '/api/storage/list':
        json(<String, Object?>{
          'pkg': 'com.example.demo',
          'os': 'macos',
          'files': <String>['/tmp/a.plist', '/tmp/b.plist'],
        });
      case '/api/storage/write':
        json(<String, Object?>{'ok': true, 'file': '/tmp/a.plist', 'applied': true});
      case '/api/sandbox/download':
        _downCalls++;
        if (_downCalls == 1) {
          json(<String, Object?>{'token': 'tk-1'});
        } else if (req.uri.queryParameters['token'] == 'tk-1') {
          res.headers.contentType = ContentType.binary;
          res.add(<int>[1, 2, 3, 4, 5]);
        } else {
          res.statusCode = HttpStatus.forbidden;
          json(<String, Object?>{'error': 'bad token'});
        }
      case '/api/network/replay':
        json(<String, Object?>{
          'statusCode': 200,
          'url': 'https://api.test/v1/login',
          'headers': <String, Object?>{'content-type': 'application/json'},
          'body': '{"ok":true}',
        });
      case '/api/db/query':
        json(<String, Object?>{
          'columns': <String>['id', 'name'],
          'rows': <Object?>[
            <Object?>[1, 'a'],
            <Object?>[2, 'b'],
          ],
          'ms': 3,
        });
      case '/api/deny':
        res.statusCode = HttpStatus.forbidden;
        json(<String, Object?>{'error': '未授权'});
      case '/api/boom':
        res.statusCode = HttpStatus.badGateway;
        json(<String, Object?>{'error': 'VM 连接失败'});
      default:
        json(<String, Object?>{'ok': true, 'path': req.uri.path});
    }
    await res.close();
  }

  Future<void> close() => server.close(force: true);
}

McpToolContext _ctx(_FakeGui gui) {
  final sessions = SessionRegistry(skipPorts: <int>{gui.port});
  return McpToolContext(
    sessions: sessions,
    scenarios: ScenarioService(sessions),
    devices: DeviceRegistry.fromSpec('none'),
    guiBridge: GuiBridge(port: gui.port, timeout: const Duration(seconds: 5)),
  );
}

McpTool _tool(List<McpTool> all, String name) =>
    all.firstWhere((t) => t.name == name);

void main() {
  final all = <McpTool>[
    ...coreTools(),
    ...deviceTools(),
    ...debugTools(),
    ...bridgeTools(),
    ...toolboxTools(),
  ];
  final byName = <String, McpTool>{for (final t in all) t.name: t};

  group('工具注册', () {
    test('调试器 6 件套在 debug 组，默认不暴露', () {
      final names = <String>[
        'xbume_debug_attach',
        'xbume_debug_state',
        'xbume_debug_breakpoints',
        'xbume_debug_control',
        'xbume_debug_inspect',
        'xbume_debug_output',
      ];
      for (final n in names) {
        expect(byName[n], isNotNull, reason: '$n 未注册');
        expect(byName[n]!.group, ToolGroup.debug);
      }
      expect(ToolGroup.optIn, contains(ToolGroup.debug));
      expect(ToolGroup.defaultExtra, isNot(contains(ToolGroup.debug)));
      // 断点 action 与 DebugHub 的 op 对得上（少一层翻译）。
      final actions = ((byName['xbume_debug_breakpoints']!.inputSchema['properties']
              as Map)['action'] as Map)['enum'] as List;
      expect(
        actions.cast<String>(),
        containsAll(<String>[
          'add',
          'remove',
          'update',
          'toggle',
          'toggleAll',
          'list',
          'saved',
          'savedAll',
          'remember',
          'forget',
          'forgetSaved',
          'enableSaved',
        ]),
      );
      final ctl = ((byName['xbume_debug_control']!.inputSchema['properties']
              as Map)['action'] as Map)['enum'] as List;
      expect(ctl.cast<String>(),
          containsAll(<String>['pause', 'continue', 'stepOver', 'stepInto', 'stepOut']));
      final insp = ((byName['xbume_debug_inspect']!.inputSchema['properties']
              as Map)['action'] as Map)['enum'] as List;
      expect(insp.cast<String>(), containsAll(<String>['stack', 'vars', 'eval']));
    });

    test('桥接工具按能力分组：data / inspect / env', () {
      expect(byName['xbume_storage']?.group, ToolGroup.data);
      expect(byName['xbume_db']?.group, ToolGroup.data);
      expect(byName['xbume_sandbox']?.group, ToolGroup.data);
      expect(byName['xbume_watch']?.group, ToolGroup.data);
      expect(byName['xbume_instances']?.group, ToolGroup.inspect);
      expect(byName['xbume_widget_tree']?.group, ToolGroup.inspect);
      expect(byName['xbume_perf']?.group, ToolGroup.inspect);
      expect(byName['xbume_compare']?.group, ToolGroup.inspect);
      expect(byName['xbume_ide']?.group, ToolGroup.env);
      expect(byName['xbume_daemon']?.group, ToolGroup.env);
      expect(byName['xbume_route_locate']?.group, ToolGroup.env);
      expect(byName['xbume_timeline_control']?.group, ToolGroup.env);
      expect(byName['xbume_log_history']?.group, ToolGroup.env);
      expect(byName['xbume_network_control']?.group, ToolGroup.env);
      expect(byName['xbume_exceptions_hub']?.group, ToolGroup.env);
      expect(byName['xbume_automation']?.group, ToolGroup.env);
      expect(byName['xbume_ai']?.group, ToolGroup.ai);
      for (final g in <String>[
        ToolGroup.data,
        ToolGroup.env,
        ToolGroup.ai,
      ]) {
        expect(ToolGroup.optIn, contains(g));
        expect(ToolGroup.defaultExtra, isNot(contains(g)));
      }
    });

    test('工具名唯一，schema 关键参数齐全', () {
      expect(byName.length, all.length, reason: '有重名工具，server 分发会串');
      Set<String> props(String n) =>
          ((byName[n]!.inputSchema['properties'] as Map).keys.cast<String>())
              .toSet();
      expect(props('xbume_storage'),
          containsAll(<String>['action', 'sessionId', 'uri', 'file', 'xml', 'dirty']));
      expect(props('xbume_db'),
          containsAll(<String>['action', 'path', 'dbId', 'table', 'sql', 'force']));
      expect(props('xbume_sandbox'),
          containsAll(<String>['action', 'path', 'offset', 'max', 'content', 'saveTo']));
      expect(props('xbume_watch'),
          containsAll(<String>['action', 'kind', 'expr', 'targetId', 'condition', 'id']));
      expect(props('xbume_instances'),
          containsAll(<String>['action', 'class', 'id', 'field', 'value', 'vtype']));
      expect(props('xbume_perf'), containsAll(<String>['action', 'windowMs', 'classes']));
      expect(props('xbume_compare'),
          containsAll(<String>['action', 'sessionA', 'sessionB', 'uriA', 'uriB', 'steps']));
      expect(props('xbume_ide'), containsAll(<String>['action', 'file', 'line', 'ideOrder']));
      // log_history 不需要 action：一个动作读到底，靠游标推进。
      expect(props('xbume_log_history'), isNot(contains('action')));
      expect(props('xbume_network_control'), containsAll(<String>['action', 'id', 'url', 'headers']));
      // GUI 日志历史：过滤 + 双游标（offset 翻页 / sinceMs 增量跟）。
      expect(
          props('xbume_log_history'),
          containsAll(<String>[
            'keyword',
            'source',
            'sinceMs',
            'offset',
            'limit',
            'tail',
            'maxChars',
          ]));
      expect(props('xbume_automation'),
          containsAll(<String>['action', 'name', 'steps', 'file', 'saveTo']));
      expect(props('xbume_ai'), containsAll(<String>['action', 'goal', 'sessionId']));
      // perf 的 reassemble 与 route_locate 的四个 action 都要能选到。
      expect(
          (((byName['xbume_perf']!.inputSchema['properties'] as Map)['action']
                  as Map)['enum'] as List)
              .cast<String>(),
          containsAll(<String>['snapshot', 'leak', 'gc', 'reassemble']));
      expect(
          (((byName['xbume_route_locate']!.inputSchema['properties'] as Map)['action']
                  as Map)['enum'] as List)
              .cast<String>(),
          containsAll(<String>['locate', 'stack', 'info', 'op']));
    });
  });

  group('GuiBridge', () {
    late _FakeGui gui;
    late GuiBridge bridge;

    setUp(() async {
      gui = await _FakeGui.start();
      bridge = GuiBridge(port: gui.port, timeout: const Duration(seconds: 5));
    });
    tearDown(() async {
      bridge.dispose();
      await gui.close();
    });

    test('GET 把参数放 query，返回 JSON', () async {
      final j = await bridge.json('/api/perf', params: <String, Object?>{
        'uri': 'ws://127.0.0.1:1/ws',
        'windowMs': 1500,
        'open': false,
      });
      expect(j['ok'], isTrue);
      final req = gui.seen.last;
      expect(req['method'], 'GET');
      expect((req['query'] as Map)['windowMs'], '1500');
      expect((req['query'] as Map)['open'], 'false');
    });

    test('POST 默认 query + body 双写（GUI 侧两种读法都有）', () async {
      await bridge.json('/api/instances/set',
          method: 'POST',
          params: <String, Object?>{'uri': 'ws://x/ws', 'id': 'o1', 'field': 'n'});
      final req = gui.seen.last;
      expect(req['method'], 'POST');
      expect((req['query'] as Map)['id'], 'o1');
      final body = jsonDecode('${req['body']}') as Map;
      expect(body['id'], 'o1');
      expect(body['field'], 'n');
    });

    test('bodyOnly 只放 body（长文本不走 URL）', () async {
      await bridge.json('/api/storage/write',
          method: 'POST',
          bodyOnly: true,
          params: <String, Object?>{'uri': 'ws://x/ws'},
          rawBody: '{"xml":"<map/>"}');
      final req = gui.seen.last;
      expect((req['query'] as Map), isEmpty);
      expect(req['body'], '{"xml":"<map/>"}');
    });

    test('非 2xx 把 GUI 的 error 转成 GuiBridgeError', () async {
      await expectLater(
        bridge.json('/api/boom'),
        throwsA(isA<GuiBridgeError>()
            .having((e) => e.message, 'message', contains('VM 连接失败'))),
      );
    });

    test('403 且读不到新令牌时直接给出可操作提示', () async {
      await expectLater(
        bridge.json('/api/deny'),
        throwsA(isA<GuiBridgeError>()
            .having((e) => e.message, 'message', contains('403'))),
      );
    });

    test('二进制接口遇 {token} 会二次请求', () async {
      final bytes = await bridge.bytes('/api/sandbox/download',
          params: <String, Object?>{'uri': 'ws://x/ws', 'path': '/a.bin'});
      expect(bytes, <int>[1, 2, 3, 4, 5]);
      // 首次请求前还会打一次 /api/version 确认端口，这里只数下载请求。
      final dl = gui.seen
          .where((e) => e['path'] == '/api/sandbox/download')
          .toList();
      expect(dl.length, 2);
      expect((dl.last['query'] as Map)['token'], 'tk-1');
    });

    test('端口连不上时提示先打开工具箱', () async {
      final dead = GuiBridge(port: 1, timeout: const Duration(seconds: 2));
      await expectLater(
        dead.json('/api/version'),
        throwsA(isA<GuiBridgeError>()
            .having((e) => e.message, 'message', contains('连不上工具箱'))),
      );
      dead.dispose();
    });
  });

  group('桥接工具转发', () {
    late _FakeGui gui;
    late McpToolContext ctx;

    setUp(() async {
      gui = await _FakeGui.start();
      ctx = _ctx(gui);
    });
    tearDown(() async {
      await gui.close();
    });

    test('timeline clear 打到 /api/timeline/clear', () async {
      final r = await _tool(all, 'xbume_timeline_control')
          .handler(ctx, <String, Object?>{'action': 'clear'});
      expect(r.isError, isFalse);
      expect(gui.seen.last['path'], '/api/timeline/clear');
      expect(gui.seen.last['method'], 'POST');
    });

    test('storage list 用 uri 参数直接转发，不需要会话', () async {
      final r = await _tool(all, 'xbume_storage').handler(ctx, <String, Object?>{
        'action': 'list',
        'uri': 'ws://127.0.0.1:1/ws',
      });
      expect(r.isError, isFalse);
      final req = gui.seen.last;
      expect(req['path'], '/api/storage/list');
      expect((req['query'] as Map)['uri'], 'ws://127.0.0.1:1/ws');
      expect('${r.content.first['text']}', contains('2 个文件'));
    });

    test('storage write 的 XML 走 body，不在 query 里', () async {
      await _tool(all, 'xbume_storage').handler(ctx, <String, Object?>{
        'action': 'write',
        'uri': 'ws://127.0.0.1:1/ws',
        'file': '/tmp/a.plist',
        'xml': '<map><boolean name="k" value="true"/></map>',
        'dirty': <Object?>[
          <String, Object?>{'key': 'k', 'type': 'bool', 'value': true},
        ],
      });
      final req = gui.seen.last;
      expect((req['query'] as Map)['file'], '/tmp/a.plist');
      final body = jsonDecode('${req['body']}') as Map;
      expect('${body['xml']}', contains('<boolean'));
      expect((body['dirty'] as List).length, 1);
    });

    test('network replay 把 id 放 query、编辑项放 body', () async {
      final r = await _tool(all, 'xbume_network_control').handler(ctx, <String, Object?>{
        'action': 'replay',
        'uri': 'ws://127.0.0.1:1/ws',
        'id': 'n1',
        'url': 'https://api.test/v1/login',
      });
      expect(r.isError, isFalse);
      final req = gui.seen.last;
      expect(req['path'], '/api/network/replay');
      expect((req['query'] as Map)['id'], 'n1');
      expect(jsonDecode('${req['body']}')['url'], 'https://api.test/v1/login');
      expect('${r.content.first['text']}', contains('200'));
    });

    test('db query 把列与行整形给人读', () async {
      final r = await _tool(all, 'xbume_db').handler(ctx, <String, Object?>{
        'action': 'query',
        'uri': 'ws://127.0.0.1:1/ws',
        'dbId': 'd1',
        'sql': 'select * from t',
      });
      final text = '${r.content.first['text']}';
      expect(text, contains('id | name'));
      expect(text, contains('2 行'));
    });

    test('sandbox download 落到本机并回路径', () async {
      final dir = await Directory.systemTemp.createTemp('xbume-mcp-dl');
      addTearDown(() => dir.delete(recursive: true));
      final save = '${dir.path}/out.bin';
      final r = await _tool(all, 'xbume_sandbox').handler(ctx, <String, Object?>{
        'action': 'download',
        'uri': 'ws://127.0.0.1:1/ws',
        'path': '/data/app/a.bin',
        'saveTo': save,
      });
      expect(r.isError, isFalse);
      expect(await File(save).readAsBytes(), <int>[1, 2, 3, 4, 5]);
      expect('${r.content.first['text']}', contains('5 字节'));
    });

    test('缺少必填参数时给出可照着做的提示', () async {
      await expectLater(
        _tool(all, 'xbume_network_control').handler(ctx, <String, Object?>{
          'action': 'replay',
          'uri': 'ws://127.0.0.1:1/ws',
        }),
        throwsA(isA<McpToolException>()
            .having((e) => e.hint ?? '', 'hint', contains('xbume_network'))),
      );
    });
  });
}
