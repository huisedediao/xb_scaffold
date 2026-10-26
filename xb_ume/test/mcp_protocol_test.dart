// MCP 协议层与消息分发单测：全部纯函数/内存对象，不连 app、不起端口。
//
// 覆盖：请求解析容错、协议版本协商、JSON-RPC 整形、工具参数辅助、
// tools/list 与 tools/call 的分发与错误码、VM 输出解析、输出路径白名单。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/bridge.dart';
import '../bin/src/device/registry.dart';
import '../bin/src/mcp/protocol.dart';
import '../bin/src/mcp/scenario_service.dart';
import '../bin/src/mcp/server.dart';
import '../bin/src/mcp/session_registry.dart';
import '../bin/src/mcp/tools.dart';

/// 只注册工具清单、不真正调用 handler 的假工具。
McpTool _fakeTool({String name = 'xbume_fake'}) => McpTool(
      name: name,
      title: '假工具',
      description: '单测用',
      group: ToolGroup.core,
      inputSchema: toolSchema(const <String, Object?>{}),
      handler: (ctx, args) async => McpToolResult.text('ok'),
    );

/// 最小 server：空设备注册表，避免探测 adb/hdc；不监听端口。
McpServer _server({List<McpTool> tools = const <McpTool>[]}) {
  final sessions = SessionRegistry();
  return McpServer(
    ctx: McpToolContext(
      sessions: sessions,
      scenarios: ScenarioService(sessions),
      devices: DeviceRegistry(<DeviceBridge>[]),
    ),
    version: '9.9.9',
    tools: tools,
  )..init();
}

void main() {
  group('McpRequest.parse', () {
    test('notification：无 id', () {
      final r = McpRequest.parse(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });
      expect(r.isNotification, isTrue);
      expect(r.method, 'notifications/initialized');
      expect(r.params, isEmpty);
    });

    test('缺 jsonrpc 字段也接受（宽松解析）', () {
      final r = McpRequest.parse(<String, Object?>{
        'id': 7,
        'method': 'ping',
      });
      expect(r.id, 7);
      expect(r.isNotification, isFalse);
    });

    test('jsonrpc 非 2.0 抛错', () {
      expect(
        () => McpRequest.parse(<String, Object?>{'jsonrpc': '1.0', 'method': 'x'}),
        throwsA(isA<McpToolException>()),
      );
    });

    test('缺 method 抛错', () {
      expect(() => McpRequest.parse(<String, Object?>{'id': 1}),
          throwsA(isA<McpToolException>()));
    });

    test('非对象抛错', () {
      expect(() => McpRequest.parse(<Object?>[]),
          throwsA(isA<McpToolException>()));
    });

    test('params 不是对象时归一化为空 map', () {
      final r = McpRequest.parse(<String, Object?>{
        'id': 1,
        'method': 'ping',
        'params': <Object?>[],
      });
      expect(r.params, isEmpty);
    });
  });

  group('initialize 版本协商', () {
    Map<String, Object?> init(String requested) =>
        mcpInitializeResult(requestedVersion: requested, serverVersion: '1.2.3');

    test('已知版本原样回显', () {
      for (final v in kMcpSupportedVersions) {
        expect(init(v)['protocolVersion'], v);
      }
    });

    test('未知版本回落到最新', () {
      expect(init('1999-01-01')['protocolVersion'], kMcpLatestVersion);
      expect(init('')['protocolVersion'], kMcpLatestVersion);
    });

    test('serverInfo 带名字与版本，capabilities 声明 tools', () {
      final r = init(kMcpLatestVersion);
      expect((r['serverInfo'] as Map)['name'], kMcpServerName);
      expect((r['serverInfo'] as Map)['version'], '1.2.3');
      expect(((r['capabilities'] as Map)['tools'] as Map)['listChanged'], false);
    });
  });

  group('JSON-RPC 整形', () {
    test('mcpResult 保留 id 与 result', () {
      final m = mcpResult('abc', <String, Object?>{'x': 1});
      expect(m['jsonrpc'], '2.0');
      expect(m['id'], 'abc');
      expect((m['result'] as Map)['x'], 1);
      expect(m.containsKey('error'), isFalse);
    });

    test('mcpError 带 data 时原样附上', () {
      final m = mcpError(1, kMcpInvalidParams, '参数错', <String, Object?>{'k': 'v'});
      final e = m['error'] as Map;
      expect(e['code'], kMcpInvalidParams);
      expect(e['message'], '参数错');
      expect((e['data'] as Map)['k'], 'v');
    });

    test('mcpError 无 data 时不输出 data 字段', () {
      final m = mcpError(1, kMcpInternalError, '异常');
      expect((m['error'] as Map).containsKey('data'), isFalse);
    });

    test('mcpNotification 不带 id', () {
      final m = mcpNotification('notifications/initialized');
      expect(m.containsKey('id'), isFalse);
      expect(m['method'], 'notifications/initialized');
      expect(m.containsKey('params'), isFalse);
    });
  });

  group('工具参数辅助', () {
    test('requireString 接受字符串/数字/布尔，空串抛错', () {
      expect(requireString(<String, Object?>{'a': ' x '}, 'a'), ' x ');
      expect(requireString(<String, Object?>{'a': 42}, 'a'), '42');
      expect(requireString(<String, Object?>{'a': true}, 'a'), 'true');
      expect(() => requireString(<String, Object?>{'a': '   '}, 'a'),
          throwsA(isA<McpToolException>()));
      expect(() => requireString(const <String, Object?>{}, 'a'),
          throwsA(isA<McpToolException>()));
    });

    test('optionalString 空串/空白归 null', () {
      expect(optionalString(<String, Object?>{'a': 'v'}, 'a'), 'v');
      expect(optionalString(<String, Object?>{'a': '  '}, 'a'), isNull);
      expect(optionalString(const <String, Object?>{}, 'a'), isNull);
    });

    test('optionalInt / optionalDouble 接受字符串数字', () {
      expect(optionalInt(<String, Object?>{'a': '42'}, 'a'), 42);
      expect(optionalInt(<String, Object?>{'a': 3.7}, 'a'), 3);
      expect(optionalInt(<String, Object?>{'a': 'x'}, 'a'), isNull);
      expect(optionalDouble(<String, Object?>{'a': '1.5'}, 'a'), 1.5);
      expect(optionalDouble(<String, Object?>{'a': 2}, 'a'), 2.0);
      expect(optionalDouble(<String, Object?>{'a': 'x'}, 'a'), isNull);
    });

    test('optionalBool 识别常见真值，未知回落 fallback', () {
      expect(optionalBool(<String, Object?>{'a': true}, 'a'), isTrue);
      expect(optionalBool(<String, Object?>{'a': 'yes'}, 'a'), isTrue);
      expect(optionalBool(<String, Object?>{'a': '1'}, 'a'), isTrue);
      expect(optionalBool(<String, Object?>{'a': 'no'}, 'a'), isFalse);
      expect(optionalBool(const <String, Object?>{}, 'a', fallback: true), isTrue);
    });

    test('truncateText 只截超长并说明原长', () {
      expect(truncateText('abc', max: 10), 'abc');
      final s = truncateText('x' * 20, max: 5);
      expect(s.startsWith('xxxxx'), isTrue);
      expect(s.contains('原始长度 20'), isTrue);
    });
  });

  group('schema 构造', () {
    test('toolSchema 无 required 时不输出该字段', () {
      expect(toolSchema(const <String, Object?>{}).containsKey('required'), isFalse);
      final withReq = toolSchema(const <String, Object?>{}, <String>['a']);
      expect(withReq['required'], <String>['a']);
    });

    test('prop 只在有值时输出 enum / default', () {
      expect(prop('string', 'd').containsKey('enum'), isFalse);
      expect(prop('string', 'd').containsKey('default'), isFalse);
      final p = prop('string', 'd',
          enumValues: <String>['a'], defaultValue: 'a');
      expect(p['enum'], <String>['a']);
      expect(p['default'], 'a');
    });

    test('arrayProp / objectProp 结构', () {
      expect((arrayProp('d', 'object')['items'] as Map)['type'], 'object');
      expect(objectProp('d')['type'], 'object');
    });
  });

  group('McpToolResult', () {
    test('text 带 structuredContent', () {
      final j = McpToolResult.text('hi', structured: <String, Object?>{'n': 1}).toJson();
      expect((j['content'] as List).first, <String, Object?>{'type': 'text', 'text': 'hi'});
      expect((j['structuredContent'] as Map)['n'], 1);
      expect(j.containsKey('isError'), isFalse);
    });

    test('json 把非 Map 包成 items', () {
      final j = McpToolResult.json(<Object?>[1, 2]).toJson();
      expect((j['structuredContent'] as Map)['items'], <Object?>[1, 2]);
      expect((j['content'] as List).first['text'], '[1,2]');
    });

    test('image 先说明后图像', () {
      final j = McpToolResult.image('AAA', caption: '截图').toJson();
      final c = j['content'] as List;
      expect(c.length, 2);
      expect(c.first['type'], 'text');
      expect(c.last['type'], 'image');
      expect(c.last['mimeType'], 'image/png');
    });

    test('isError 显式输出', () {
      final j = McpToolResult.text('坏了', isError: true).toJson();
      expect(j['isError'], true);
    });
  });

  group('McpServer 消息分发', () {
    test('initialize 回协议版本与服务名', () async {
      final s = _server();
      final r = await s.handleMessage(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, Object?>{'protocolVersion': '2025-03-26'},
      });
      final res = r!['result'] as Map;
      expect(res['protocolVersion'], '2025-03-26');
      expect((res['serverInfo'] as Map)['version'], '9.9.9');
      await s.close();
    });

    test('ping 返回空结果', () async {
      final s = _server();
      final r = await s.handleMessage(
          <String, Object?>{'jsonrpc': '2.0', 'id': 2, 'method': 'ping'});
      expect(r!['result'], isEmpty);
      await s.close();
    });

    test('tools/list 输出工具的 name/title/description/inputSchema', () async {
      final s = _server(tools: <McpTool>[_fakeTool()]);
      final r = await s.handleMessage(
          <String, Object?>{'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'});
      final tools = (r!['result'] as Map)['tools'] as List;
      expect(tools.length, 1);
      final t = tools.first as Map;
      expect(t['name'], 'xbume_fake');
      expect(t['title'], '假工具');
      expect(t['description'], '单测用');
      expect((t['inputSchema'] as Map)['type'], 'object');
      await s.close();
    });

    test('notification 不返回响应', () async {
      final s = _server();
      final r = await s.handleMessage(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });
      expect(r, isNull);
      await s.close();
    });

    test('未知方法回 -32601；通知形式的未知方法静默', () async {
      final s = _server();
      final r = await s.handleMessage(
          <String, Object?>{'jsonrpc': '2.0', 'id': 4, 'method': 'x/y'});
      expect((r!['error'] as Map)['code'], kMcpMethodNotFound);
      final n = await s.handleMessage(
          <String, Object?>{'jsonrpc': '2.0', 'method': 'x/y'});
      expect(n, isNull);
      await s.close();
    });

    test('批量请求显式拒绝', () async {
      final s = _server();
      final r = await s.handleMessage(<Object?>[
        <String, Object?>{'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
      ]);
      expect((r!['error'] as Map)['code'], kMcpInvalidRequest);
      await s.close();
    });

    test('tools/call 未知工具回 -32602 并列出可用工具', () async {
      final s = _server(tools: <McpTool>[_fakeTool()]);
      final r = await s.handleMessage(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'tools/call',
        'params': <String, Object?>{'name': 'xbume_nope'},
      });
      final e = r!['error'] as Map;
      expect(e['code'], kMcpInvalidParams);
      expect(((e['data'] as Map)['available'] as String), contains('xbume_fake'));
      await s.close();
    });

    test('resources/list 与 prompts/list 返回空集合', () async {
      final s = _server();
      for (final m in <String>['resources/list', 'prompts/list']) {
        final r = await s.handleMessage(
            <String, Object?>{'jsonrpc': '2.0', 'id': 6, 'method': m});
        final res = r!['result'] as Map;
        expect(res.values.first, isEmpty, reason: m);
      }
      await s.close();
    });
  });

  group('parseFindWidget', () {
    test('解析 7 段行并保留空文本', () {
      final raw = <String>[
        '12\u00013\u0001XBCell\u0001k1\u000118,74,88,20\u0001标题\u0001cell.dart:55',
        '13\u00014\u0001RichText\u0001\u00010,0,10,10\u0001\u0001',
      ].join('\u0003');
      final items = parseFindWidget(raw);
      expect(items.length, 2);
      expect(items.first['ref'], 12);
      expect(items.first['depth'], 3);
      expect(items.first['type'], 'XBCell');
      expect(items.first['key'], 'k1');
      expect((items.first['bounds'] as Map)['w'], 88);
      expect(items.first['text'], '标题');
      expect(items.first['source'], 'cell.dart:55');
      expect(items.last['text'], '');
    });

    test('坏行（字段不足）跳过，特殊标记返回空', () {
      expect(parseFindWidget('1\u00012'), isEmpty);
      expect(parseFindWidget('NO_ROOT'), isEmpty);
      expect(parseFindWidget('NOT_FOUND'), isEmpty);
      expect(parseFindWidget(''), isEmpty);
    });
  });

  group('resolveOutputPath 白名单', () {
    test('当前目录下的相对路径被接受且转绝对', () {
      final p = resolveOutputPath('mcp_shot_test.png');
      expect(p, startsWith('/'));
      expect(p, endsWith('mcp_shot_test.png'));
    });

    test('白名单外路径被拒绝', () {
      expect(() => resolveOutputPath('/etc/xbume_nope.png'),
          throwsA(isA<McpToolException>()));
      expect(() => resolveOutputPath('/var/xbume_nope.png'),
          throwsA(isA<McpToolException>()));
    });

    test('用户主目录在白名单内（截图常落到项目目录）', () {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null || home.isEmpty) return;
      expect(resolveOutputPath('$home/xbume_nope.png'), '$home/xbume_nope.png');
    });
  });

  group('ToolGroup 分组', () {
    test('默认只开 diagnose / run-safe，act 与 device-write 需显式开启', () {
      expect(ToolGroup.defaultExtra,
          <String>{ToolGroup.diagnose, ToolGroup.runSafe});
      expect(ToolGroup.optIn.contains(ToolGroup.act), isTrue);
      expect(ToolGroup.optIn.contains(ToolGroup.deviceWrite), isTrue);
      expect(ToolGroup.defaultExtra.contains(ToolGroup.act), isFalse);
    });
  });

  group('设备后端能力声明', () {
    test('空注册表不崩，能力矩阵为空', () {
      final r = DeviceRegistry(<DeviceBridge>[]);
      expect(r.backendsJson(), isEmpty);
      expect(r.bridgeOf('adb'), isNull);
    });
  });
}
