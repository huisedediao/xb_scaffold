// 直连 Agent 的文件/存储数据面（P3）。
//
// lib 侧函数直接在宿主进程里跑（全是 dart:io + 已注册适配器），另起一个真实
// HttpServer 断言端点接线、method 限制与返回形状；不初始化 widget binding，
// 避免 flutter_test 把 HttpClient 换成一律 400 的 mock。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/agent/xb_ume_agent.dart';
import 'package:xb_ume/src/agent/xb_ume_agent_fs.dart';
import 'package:xb_ume/src/agent/xb_ume_agent_inspectable.dart';
import 'package:xb_ume/src/agent/xb_ume_agent_perf.dart';
import 'package:xb_ume/src/agent/xb_ume_agent_routes.dart';
import 'package:xb_ume/xb_ume.dart';

class _MemoryPersistence implements XBUmePersistence {
  @override
  Future<Map<String, dynamic>?> load() async => null;

  @override
  Future<void> save(Map<String, dynamic> json) async {}
}

class _ThrowingInspectable extends XBUmeInspectable {
  @override
  String get inspectId => 'boom';

  @override
  Map<String, dynamic> inspect() => throw StateError('炸了');
}

void main() {
  HttpOverrides.global = null;
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xbume_fs_test_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File writeFile(String name, Object content) {
    final f = File('${tmp.path}/$name');
    f.parent.createSync(recursive: true);
    if (content is List<int>) {
      f.writeAsBytesSync(content);
    } else {
      f.writeAsStringSync(content.toString());
    }
    return f;
  }

  group('sandbox', () {
    test('stat：存在 / 不存在', () {
      final f = writeFile('a.txt', 'hello 世界');
      final ok = agentSandboxStatJson(f.path);
      expect(ok['ok'], isTrue);
      expect(ok['size'], utf8.encode('hello 世界').length);
      expect(ok['dir'], isFalse);

      final missing = agentSandboxStatJson('${tmp.path}/nope');
      expect(missing['ok'], isFalse);
      expect(missing['error'], 'missing');
    });

    test('list：目录优先 + 名字排序，字段与 GUI 同形', () {
      writeFile('b.txt', 'b');
      writeFile('a.txt', 'a');
      Directory('${tmp.path}/zdir').createSync();

      final j = agentSandboxListJson(
        path: tmp.path,
        pkg: '',
        os: 'macos',
        home: tmp.path,
      );
      expect(j['ok'], isTrue);
      expect(j['root'], tmp.path);
      expect(j['os'], 'macos');
      final entries = (j['entries'] as List).cast<Map>();
      expect(entries.map((e) => e['name']).take(3).toList(),
          <String>['zdir', 'a.txt', 'b.txt']);
      expect(entries.first['dir'], isTrue);
      expect(entries[1]['size'], 1);
      expect(entries[1]['mtime'], isA<int>());
    });

    test('list：path 为空时用第一个可用根', () {
      final j = agentSandboxListJson(
        path: '',
        pkg: '',
        os: 'macos',
        home: tmp.path,
      );
      expect(j['ok'], isTrue);
      expect(j['root'], isNotEmpty);
    });

    test('read：按 max 分块，nextOffset 落在字符边界上', () {
      // 每字符 3 字节，max=4 必然切在多字节字符中间，`nextOffset` 要回退。
      final f = writeFile('zh.txt', '中文内容');
      final first = agentSandboxReadJson(f.path, offset: 0, max: 4);
      expect(first['ok'], isTrue);
      expect(first['fileSize'], 12);
      expect(first['text'], '中');
      expect(first['nextOffset'], 3);
      expect(first['truncated'], isTrue);

      final second =
          agentSandboxReadJson(f.path, offset: 3, max: 4096);
      expect(second['text'], '文内容');
      expect(second['truncated'], isFalse);
    });

    test('read：二进制自动回 base64，b64=1 强制 base64', () {
      final f = writeFile('bin.dat', <int>[0, 159, 146, 150, 255]);
      final j = agentSandboxReadJson(f.path, max: 4096);
      expect(j['ok'], isTrue);
      expect(j['binary'], isTrue);
      expect(base64Decode('${j['b64']}'), <int>[0, 159, 146, 150, 255]);
      expect(j['nextOffset'], 5);

      final text = writeFile('t.txt', 'abc');
      final forced =
          agentSandboxReadJson(text.path, max: 4096, forceB64: true);
      expect(utf8.decode(base64Decode('${forced['b64']}')), 'abc');
      expect(forced.containsKey('binary'), isFalse);
    });

    test('read：文件不存在回 ok=false', () {
      final j = agentSandboxReadJson('${tmp.path}/nope');
      expect(j['ok'], isFalse);
      expect(j['error'], 'missing');
    });

    test('roots：候选里可进的那几个标 ok', () {
      final j = agentSandboxRootsJson(pkg: '', os: 'macos', home: tmp.path);
      final roots = (j['roots'] as List).cast<Map>();
      expect(roots.map((e) => e['path']), contains(tmp.path));
      expect(roots.firstWhere((e) => e['path'] == tmp.path)['ok'], isTrue);
      expect(j['root'], isNotEmpty);
    });
  });

  group('storage', () {
    late XBUmeController controller;

    setUp(() {
      controller = XBUmeController(
        config:
            const XBUmeConfig(persistenceEnabled: false, logFileEnabled: false),
        persistence: _MemoryPersistence(),
      );
      controller.registerStorageAdapter(XBUmeMapStorageAdapter(
        id: 'memory',
        data: <String, dynamic>{'count': 1, 'name': 'demo'},
        allowWrite: true,
      ));
      controller.registerStorageAdapter(XBUmeMapStorageAdapter(
        id: 'readonly',
        data: <String, dynamic>{'x': 1},
      ));
    });

    tearDown(() => controller.dispose());

    test('adapters：列出 id / writable / dump，不写的不给写', () async {
      final j = await agentStorageAdaptersJson(controller);
      final items = (j['items'] as List).cast<Map>();
      expect(items.map((e) => e['id']), <String>['memory', 'readonly']);
      expect(items.first['writable'], isTrue);
      expect((items.first['data'] as Map)['name'], 'demo');
      expect(items.last['writable'], isFalse);
    });

    test('set / remove：只接受可写适配器', () async {
      final ok = await agentStorageSetJson(
        controller,
        adapter: 'memory',
        key: 'count',
        type: 'int',
        value: '7',
      );
      expect(ok['ok'], isTrue);
      final after =
          await controller.findStorageAdapter('memory')!.dump();
      expect(after['count'], 7);

      final denied = await agentStorageSetJson(
        controller,
        adapter: 'readonly',
        key: 'x',
        type: 'int',
        value: '2',
      );
      expect(denied['ok'], isFalse);
      expect('${denied['error']}', contains('writable=false'));

      final unknown = await agentStorageRemoveJson(
        controller,
        adapter: 'nope',
        key: 'x',
      );
      expect(unknown['ok'], isFalse);

      final removed = await agentStorageRemoveJson(
        controller,
        adapter: 'memory',
        key: 'name',
      );
      expect(removed['ok'], isTrue);
      final dump = await controller.findStorageAdapter('memory')!.dump();
      expect(dump.containsKey('name'), isFalse);
    });

    test('set：json 类型按 JSON 解析，解析失败退回字符串', () async {
      await agentStorageSetJson(
        controller,
        adapter: 'memory',
        key: 'list',
        type: 'json',
        value: '["a","b"]',
      );
      final dump = await controller.findStorageAdapter('memory')!.dump();
      expect(dump['list'], <String>['a', 'b']);
    });

    test('list / read：桌面端扫 ~/Library/Preferences，读文本原样返回', () {
      final f = writeFile('demo_prefs.plist', '<plist/>');
      final read = agentStorageReadJson(f.path);
      expect(read['ok'], isTrue);
      expect(read['text'], '<plist/>');
      expect(read.containsKey('binary'), isFalse);
    });
  });

  group('db files', () {
    test('只列 SQLite 扩展名，跳过缓存目录，按 mtime 倒序', () {
      final old = writeFile('old.db', 'x');
      // 保证 mtime 有差异（部分文件系统精度 1s）。
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
      writeFile('new.sqlite3', 'y');
      writeFile('notes.txt', 'z');
      writeFile('cache/skip.db', 'w');

      final j = agentDbFilesJson(
        pkg: '',
        os: 'macos',
        home: tmp.path,
        dir: tmp.path,
      );
      expect(j['ok'], isTrue);
      final items = (j['items'] as List).cast<Map>();
      expect(items.map((e) => e['name']), <String>['new.sqlite3', 'old.db']);
      expect(items.every((e) => e['root'] == tmp.path), isTrue);
      expect(j['truncated'], isFalse);
    });

    test('limit 生效并标记 truncated', () {
      writeFile('a.db', 'a');
      writeFile('b.db', 'b');
      final j = agentDbFilesJson(
        pkg: '',
        os: 'macos',
        home: tmp.path,
        dir: tmp.path,
        limit: 1,
      );
      expect((j['items'] as List).length, 1);
      expect(j['truncated'], isTrue);
    });
  });

  group('perf', () {
    test('无帧时给零值，进程统计保留，不死造 VM 字段', () {
      final c = XBUmeController(
        config:
            const XBUmeConfig(persistenceEnabled: false, logFileEnabled: false),
        persistence: _MemoryPersistence(),
      );
      final j = agentPerfJson(c, windowMs: 1000, app: 'demo');
      expect(j['ok'], isTrue);
      expect(j['app'], 'demo');
      expect(j['windowMs'], 1000);
      expect(j['os'], isNotEmpty);
      final fr = j['frames'] as Map;
      expect(fr['count'], 0);
      expect(fr['fps'], 0.0);
      expect(fr['jankRate'], 0.0);
      expect(j['processStats'], isA<Map>());
      expect(j.containsKey('heap'), isFalse);
      expect('${j['cpuError']}', contains('isolate'));
      c.dispose();
    });

    test('窗口夹在 0.5–5s（与 GUI 同口径）', () {
      final c = XBUmeController(
        config:
            const XBUmeConfig(persistenceEnabled: false, logFileEnabled: false),
        persistence: _MemoryPersistence(),
      );
      expect(agentPerfJson(c, windowMs: 10)['windowMs'], 500);
      expect(agentPerfJson(c, windowMs: 99999)['windowMs'], 5000);
      c.dispose();
    });
  });

  group('inspectable', () {
    XBUmeController newController() => XBUmeController(
          config: const XBUmeConfig(
              persistenceEnabled: false, logFileEnabled: false),
          persistence: _MemoryPersistence(),
        );

    test('未注册时列表为空，取树回报注册方法', () {
      final c = newController();
      final stores = agentInspectStoresJson(c);
      expect(stores['ok'], isTrue);
      expect(stores['items'], isEmpty);

      final tree = agentInspectTreeJson(c, 'AppState');
      expect(tree['ok'], isFalse);
      expect('${tree['error']}', contains('registerInspectable'));
      c.dispose();
    });

    test('列表与字段树：形状对齐 GUI，节点不带 id（不可写）', () {
      final c = newController();
      c.registerInspectable(XBUmeMapInspectable(
        inspectId: 'AppState',
        data: <String, dynamic>{
          'count': 3,
          'ratio': 0.5,
          'enabled': true,
          'title': 'demo',
          'none': null,
          'user': <String, dynamic>{'name': 'a', 'tags': <Object?>['x', 2]},
        },
      ));

      final stores = agentInspectStoresJson(c);
      final items = (stores['items'] as List).cast<Map>();
      expect(items.length, 1);
      expect(items.first['id'], 'AppState');
      expect(items.first['instId'], 'AppState');
      expect(items.first['cls'], 'Map');

      // depth=1：根字段给全，嵌套 Map/List 只报条目数。
      final shallow = agentInspectTreeJson(c, 'AppState', depth: 1);
      expect(shallow['ok'], isTrue);
      final root = shallow['node'] as Map;
      expect(root['name'], 'AppState');
      expect(root['kind'], 'map');
      expect(root['length'], 6);
      final fields = <String, Map>{
        for (final n in (root['children'] as List).cast<Map>())
          '${n['name']}': n,
      };
      expect(fields['count']!['kind'], 'value');
      expect(fields['count']!['cls'], 'int');
      expect(fields['count']!['value'], '3');
      expect(fields['ratio']!['value'], '0.5');
      expect(fields['enabled']!['cls'], 'bool');
      expect(fields['title']!['cls'], 'String');
      expect(fields['none']!['value'], 'null');
      expect(fields['user']!['kind'], 'map');
      expect(fields['user']!['length'], 2);
      expect(fields['user']!.containsKey('children'), isFalse);
      // 没有 id 字段 = 前端不显示「展开（ref）」与「编辑」。
      expect(root.containsKey('id'), isFalse);
      expect(fields['count']!.containsKey('id'), isFalse);

      // depth=3：嵌套 Map/List 展开到叶子。
      final deep = agentInspectTreeJson(c, 'AppState', depth: 3);
      final deepRoot = deep['node'] as Map;
      final user = ((deepRoot['children'] as List).cast<Map>())
          .firstWhere((n) => n['name'] == 'user');
      final userKids = <String, Map>{
        for (final n in (user['children'] as List).cast<Map>())
          '${n['name']}': n,
      };
      expect(userKids['name']!['value'], 'a');
      expect(userKids['tags']!['kind'], 'list');
      expect(userKids['tags']!['length'], 2);
      final tag0 =
          ((userKids['tags']!['children'] as List).cast<Map>()).first;
      expect(tag0['name'], '[0]');
      expect(tag0['value'], 'x');
      c.dispose();
    });

    test('按类型名也能取树；长值标 truncated', () {
      final c = newController();
      c.registerInspectable(XBUmeMapInspectable(
        inspectId: 'cfg',
        inspectType: 'Settings',
        data: <String, dynamic>{'blob': 'x' * 900},
      ));
      final byType = agentInspectTreeJson(c, 'Settings');
      expect(byType['ok'], isTrue);
      expect(byType['type'], 'Settings');
      final leaf = ((byType['node'] as Map)['children'] as List).cast<Map>().first;
      expect('${leaf['value']}'.length, 500);
      expect(leaf['truncated'], isTrue);
      c.dispose();
    });

    test('inspect() 抛错时回报错误，不挂服务', () {
      final c = newController();
      c.registerInspectable(_ThrowingInspectable());
      final tree = agentInspectTreeJson(c, 'boom');
      expect(tree['ok'], isFalse);
      expect('${tree['error']}', contains('inspect()'));
      c.dispose();
    });
  });

  group('route stack', () {
    XBUmeController newController() => XBUmeController(
          config: const XBUmeConfig(
              persistenceEnabled: false, logFileEnabled: false),
          persistence: _MemoryPersistence(),
        );

    XBUmeRouteItem ev(XBUmeRouteAction a, String name, [String? prev]) =>
        XBUmeRouteItem(
          id: '$name-${a.name}',
          time: DateTime.now(),
          action: a,
          routeName: name,
          previousRouteName: prev,
        );

    test('push / pop / replace 重放成近似栈', () {
      final stack = replayRouteStack(<XBUmeRouteItem>[
        ev(XBUmeRouteAction.push, '/'),
        ev(XBUmeRouteAction.push, '/user'),
        ev(XBUmeRouteAction.push, '/order'),
        ev(XBUmeRouteAction.pop, '/order'),
        ev(XBUmeRouteAction.replace, '/settings', '/user'),
      ]);
      expect(stack, <String>['/', '/settings']);
    });

    test('同名多次 push 只弹最后一层；弹空栈不抛错', () {
      expect(
        replayRouteStack(<XBUmeRouteItem>[
          ev(XBUmeRouteAction.push, '/a'),
          ev(XBUmeRouteAction.push, '/a'),
          ev(XBUmeRouteAction.pop, '/a'),
        ]),
        <String>['/a'],
      );
      expect(
        replayRouteStack(<XBUmeRouteItem>[
          ev(XBUmeRouteAction.pop, '/x'),
        ]),
        isEmpty,
      );
    });

    test('响应标 approx，只有一个虚拟 Navigator，栈顶标 current', () {
      final c = newController();
      c.addRoute(
          action: XBUmeRouteAction.push, routeName: '/', previousRouteName: null);
      c.addRoute(
          action: XBUmeRouteAction.push,
          routeName: '/detail',
          previousRouteName: '/');
      final j = agentRouteStackJson(c, eventLimit: 10);
      expect(j['ok'], isTrue);
      expect(j['approx'], isTrue);
      expect('${j['note']}', contains('近似'));
      final navs = (j['navigators'] as List).cast<Map>();
      expect(navs.length, 1);
      final routes = (navs.first['routes'] as List).cast<Map>();
      expect(routes.map((r) => r['name']), <String>['/', '/detail']);
      expect(routes.first['current'], isFalse);
      expect(routes.last['current'], isTrue);
      expect((j['events'] as List).length, 2);
      c.dispose();
    });

    test('eventLimit 只截事件视界，不影响栈', () {
      final c = newController();
      for (var i = 0; i < 30; i++) {
        c.addRoute(
            action: XBUmeRouteAction.push,
            routeName: '/p$i',
            previousRouteName: null);
      }
      final j = agentRouteStackJson(c, eventLimit: 5);
      expect((j['events'] as List).length, 5);
      final routes =
          (((j['navigators'] as List).first as Map)['routes'] as List);
      expect(routes.length, 30);
      c.dispose();
    });
  });

  group('HTTP 接线', () {
    late XBUmeController controller;
    late XBUmeAgentServer server;

    Future<Map<String, Object?>> call(
      String path, {
      String method = 'GET',
      Map<String, String>? query,
      Map<String, Object?>? body,
    }) async {
      final client = HttpClient();
      try {
        final uri =
            Uri.parse('${server.baseUrl}$path').replace(queryParameters: query);
        final req = await client.openUrl(method, uri);
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
      controller = XBUmeController(
        config:
            const XBUmeConfig(persistenceEnabled: false, logFileEnabled: false),
        persistence: _MemoryPersistence(),
      );
      controller.registerStorageAdapter(XBUmeMapStorageAdapter(
        id: 'memory',
        data: <String, dynamic>{'count': 1},
        allowWrite: true,
      ));
      final started = await startXBUmeAgentServer(
        controller: controller,
        options: const XBUmeAgentOptions(
          enabled: true,
          port: 0,
          appId: 'demo',
          packageName: 'com.demo.app',
        ),
      );
      server = started!;
    });

    tearDown(() async {
      await server.close();
      controller.dispose();
    });

    test('hello 自报 fs / perf / inspectable 能力', () async {
      final body = (await call('/v1/hello'))['body'] as Map;
      expect(body['caps'], containsAll(<String>['fs', 'perf', 'inspectable']));
    });

    test('perf 给帧统计与进程采样', () async {
      final body = (await call('/v1/perf',
          query: <String, String>{'windowMs': '500'}))['body'] as Map;
      expect(body['ok'], isTrue);
      expect(body['windowMs'], 500);
      expect(body['frames'], isA<Map>());
      expect(body['processStats'], isA<Map>());
    });

    test('sandbox stat / read（b64）/ list 可用', () async {
      final f = writeFile('x.txt', 'hi');

      final stat = (await call('/v1/sandbox/stat',
          query: <String, String>{'path': f.path}))['body'] as Map;
      expect(stat['ok'], isTrue);
      expect(stat['size'], 2);

      final read = (await call('/v1/sandbox/read', query: <String, String>{
        'path': f.path,
        'max': '4096',
        'b64': '1',
      }))['body'] as Map;
      expect(utf8.decode(base64Decode('${read['b64']}')), 'hi');

      final list = (await call('/v1/sandbox/list',
          query: <String, String>{'path': tmp.path}))['body'] as Map;
      expect(list['entries'], isNotEmpty);
    });

    test('storage set / remove 只收 POST', () async {
      final denied = await call('/v1/storage/set',
          query: <String, String>{'adapter': 'memory', 'key': 'a'});
      expect(denied['status'], 405);

      final noArgs = await call('/v1/storage/set', method: 'POST', body: null);
      expect(noArgs['status'], 200);
      expect((noArgs['body'] as Map)['ok'], isFalse, reason: '缺 adapter 不能算成功');

      final set = await call(
        '/v1/storage/set',
        method: 'POST',
        body: <String, Object?>{
          'adapter': 'memory',
          'key': 'count',
          'type': 'int',
          'value': '9',
        },
      );
      expect((set['body'] as Map)['ok'], isTrue);

      final dump = await controller.findStorageAdapter('memory')!.dump();
      expect(dump['count'], 9);

      final rm = await call(
        '/v1/storage/remove',
        method: 'POST',
        body: <String, Object?>{'adapter': 'memory', 'key': 'count'},
      );
      expect((rm['body'] as Map)['ok'], isTrue);
    });

    test('db/files 与 storage/list 可用', () async {
      writeFile('a.db', 'x');
      final db = (await call('/v1/db/files',
          query: <String, String>{'dir': tmp.path}))['body'] as Map;
      expect((db['items'] as List).length, 1);

      final list = (await call('/v1/storage/list'))['body'] as Map;
      expect(list['ok'], isTrue);
      expect(list['files'], isA<List>());
    });

    test('inspect 列注册表 / 展开字段树 / 未知 id 报错', () async {
      controller.registerInspectable(XBUmeMapInspectable(
        inspectId: 'AppState',
        data: <String, dynamic>{'count': 1},
      ));

      final stores = (await call('/v1/inspect'))['body'] as Map;
      expect(stores['ok'], isTrue);
      final items = (stores['items'] as List).cast<Map>();
      expect(items.map((e) => e['instId']), contains('AppState'));

      final tree = (await call('/v1/inspect', query: <String, String>{
        'id': 'AppState',
        'depth': '2',
      }))['body'] as Map;
      expect(tree['ok'], isTrue);
      final node = tree['node'] as Map;
      expect(node['kind'], 'map');
      expect((node['children'] as List).first['name'], 'count');

      final missing = (await call('/v1/inspect',
          query: <String, String>{'id': 'nope'}))['body'] as Map;
      expect(missing['ok'], isFalse);
      expect('${missing['error']}', contains('AppState'));
    });
  });
}