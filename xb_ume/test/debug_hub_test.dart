// GUI 调试中枢（DebugHub）的单测：
// - 纯函数：pubspec 包名、断点路径解析、JSON 序列化、错误文案
// - 无会话时的操作语义：status / stop / hot / 未知 op / 未连接提示
// 真实链路（启动 → 断点 → 暂停 → 步进）在 macOS example 上做端到端，
// 单测只锁「前后端契约」这部分，避免依赖 flutter run 与设备。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/debug/breakpoint_store.dart';
import '../bin/src/debug/debug_client.dart';
import '../bin/src/debug/debug_hub.dart';
import '../bin/src/device/bridge.dart';

void main() {
  group('readPubspecName', () {
    test('取 name 行，忽略注释与引号', () {
      final dir = Directory.systemTemp.createTempSync('xbd_hub_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/pubspec.yaml').writeAsStringSync('''
# 注释
name: "demo_app"   # 行尾注释
version: 1.0.0
''');
      expect(readPubspecName(dir.path), 'demo_app');
    });

    test('目录 / 文件不存在返回 null', () {
      expect(readPubspecName(''), isNull);
      expect(readPubspecName('/tmp/definitely-not-a-project-xbd'), isNull);
    });
  });

  group('breakpointPathOf', () {
    test('绝对路径原样返回', () {
      expect(
        breakpointPathOf('/tmp/proj/lib/main.dart'),
        '/tmp/proj/lib/main.dart',
      );
    });

    test('相对路径按项目根补全', () {
      expect(
        breakpointPathOf('lib/main.dart', projectRoot: '/tmp/proj'),
        '/tmp/proj/lib/main.dart',
      );
    });

    test('脚本 URI：file: 解码，本包 package: 落到 lib', () {
      expect(
        breakpointPathOf('file:///tmp/my%20app/lib/a.dart'),
        '/tmp/my app/lib/a.dart',
      );
      expect(
        breakpointPathOf('package:app/main.dart',
            projectRoot: '/tmp/proj', packageName: 'app'),
        '/tmp/proj/lib/main.dart',
      );
    });

    test('别的包 / 空串返回 null', () {
      expect(
        breakpointPathOf('package:dio/dio.dart',
            projectRoot: '/tmp/proj', packageName: 'app'),
        isNull,
      );
      expect(breakpointPathOf('   '), isNull);
    });
  });

  group('savedAllDirs', () {
    test('当前项目有断点才置顶；没断点不占空分组', () {
      expect(savedAllDirs(<String>['/b', '/a'], null), <String>['/a', '/b']);
      expect(savedAllDirs(<String>['/b', '/a'], '/b'), <String>['/b', '/a']);
      expect(savedAllDirs(<String>['/b', '/a'], '/c'), <String>['/a', '/b']);
      expect(savedAllDirs(const <String>[], '/c'), isEmpty);
    });
  });

  group('bindProjectRoot', () {
    test('显式根优先，其次是认领到的 cwd，并归一化尾斜杠', () {
      expect(bindProjectRoot('/p/a', '/p/b'), '/p/a');
      expect(bindProjectRoot('  /p/a/  ', null), '/p/a');
      expect(bindProjectRoot('', '/p/b'), '/p/b');
      expect(bindProjectRoot(null, '/p/b/'), '/p/b');
    });

    test('都拿不到就回 null：不沿用上一个会话的项目根', () {
      // 接入别的项目时若回退旧根，断点会记到旧项目、又反向恢复旧清单。
      expect(bindProjectRoot(null, null), isNull);
      expect(bindProjectRoot('   ', ''), isNull);
    });
  });

  group('JSON 序列化', () {
    test('断点：带条件与本机路径', () {
      final json = debugBreakpointJson(
        const DebugBreakpoint(
          id: 'breakpoints/1',
          scriptUri: 'package:app/main.dart',
          line: 12,
          resolved: true,
          condition: 'count > 2',
        ),
        localPath: '/tmp/proj/lib/main.dart',
      );
      expect(json['id'], 'breakpoints/1');
      expect(json['path'], '/tmp/proj/lib/main.dart');
      expect(json['condition'], 'count > 2');
      expect(json['enabled'], isTrue);
    });

    test('栈帧：变量展开并带本机路径', () {
      const frame = DebugFrame(
        index: 1,
        function: 'build',
        scriptUri: 'package:app/main.dart',
        line: 42,
        vars: <DebugVar>[
          DebugVar(name: 'count', value: '3', type: 'int', objectId: 'objects/1'),
        ],
      );
      final json = debugFrameJson(frame, toLocal: (_) => '/tmp/proj/lib/main.dart');
      expect(json['index'], 1);
      expect(json['path'], '/tmp/proj/lib/main.dart');
      expect(json['label'], 'build  package:app/main.dart:42');
      final vars = json['vars']! as List;
      expect((vars.single as Map)['name'], 'count');
      expect((vars.single as Map)['objectId'], 'objects/1');
    });

    test('暂停现场：带原因、命中断点与异常值', () {
      const pause = DebugPause(
        reason: 'PauseException',
        topFrame: DebugFrame(index: 0, function: 'main', line: 7),
        exception: 'Bad state: boom',
      );
      final json = debugPauseJson(pause);
      expect(json['fromException'], isTrue);
      expect(json['exception'], 'Bad state: boom');
      expect((json['topFrame']! as Map)['function'], 'main');
    });

    test('事件：kind 用枚举名，便于前端分支', () {
      final json = debugEventJson(const DebugEvent(
        kind: DebugEventKind.conditionMissed,
        condition: 'x == 1',
        message: '条件未命中',
      ));
      expect(json['kind'], 'conditionMissed');
      expect(json['condition'], 'x == 1');
      expect(json['message'], '条件未命中');
    });

    test('错误文案：DebugException / DeviceCommandError 取 message', () {
      expect(debugErrorText(DebugException('连接失败')), '连接失败');
      expect(
        debugErrorText(DeviceCommandError('flutter-run', 'flutter run', '超时')),
        '超时',
      );
      expect(debugErrorText(StateError('boom')), contains('boom'));
    });
  });

  group('DebugHub（无会话）', () {
    late List<Map<String, Object?>> pushed;
    late DebugHub hub;

    setUp(() {
      pushed = <Map<String, Object?>>[];
      hub = DebugHub(push: pushed.add);
    });

    tearDown(() async {
      await hub.dispose();
    });

    test('status 是干净的空态', () {
      final s = hub.status();
      expect(s['running'], isFalse);
      expect(s['attached'], isFalse);
      expect(s['paused'], isFalse);
      expect(s['pause'], isNull);
      expect(s['breakpoints'], isEmpty);
      expect(s['pid'], isNull);
    });

    test('status 操作回最近输出并推一次状态', () async {
      final r = await hub.handle('status', const <String, Object?>{});
      expect(r['ok'], isTrue);
      expect(r['output'], isEmpty);
      expect(pushed.where((m) => m['type'] == 'debugState'), hasLength(1));
    });

    test('需要会话的操作给出可执行提示', () async {
      // addBreakpoint 先校验参数，见下一个用例。
      for (final op in <String>['pause', 'resume', 'stack']) {
        final r = await hub.handle(op, const <String, Object?>{});
        expect(r['ok'], isFalse, reason: op);
        expect('${r['error']}', contains('未连接调试会话'), reason: op);
      }
    });

    test('addBreakpoint 先校验参数（缺 path / line）', () async {
      final noPath = await hub.handle('addBreakpoint', const <String, Object?>{
        'line': 3,
      });
      expect('${noPath['error']}', contains('path'));
      // 有 path 才会走到「未连接调试会话」。
      final noClient = await hub.handle('addBreakpoint', const <String, Object?>{
        'path': '/tmp/a.dart',
        'line': 3,
      });
      expect('${noClient['error']}', contains('未连接调试会话'));
    });

    test('hot 无会话时明确说不能热重载', () async {
      final r = await hub.handle('hot', const <String, Object?>{});
      expect(r['ok'], isFalse);
      expect('${r['error']}', contains('无法热重载'));
    });

    test('stop 没有会话时只断开连接', () async {
      final r = await hub.handle('stop', const <String, Object?>{});
      expect(r['ok'], isTrue);
      expect(r['stopped'], isFalse);
      expect('${r['message']}', contains('没有在跑'));
    });

    test('未知 op 回错误而不是抛异常', () async {
      final r = await hub.handle('boom', const <String, Object?>{});
      expect(r['ok'], isFalse);
      expect('${r['error']}', contains('未知操作'));
    });
  });

  group('断点落盘（无会话）', () {
    late Directory tmp;
    late DebugHub storeHub;
    late String root;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('xbd_hub_bp_');
      root = '${tmp.path}/proj';
      storeHub = DebugHub(
        push: (_) {},
        store: BreakpointStore(filePath: '${tmp.path}/bp.json'),
      );
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('saved：没给 dir 回空表，给了就列清单（含绝对路径）', () async {
      final none = await storeHub.handle('saved', const <String, Object?>{});
      expect(none['ok'], isTrue);
      expect(none['saved'], isEmpty);

      storeHub.store.add(
        root,
        const SavedBreakpoint(path: 'lib/main.dart', line: 87, condition: 'i>2'),
      );
      final d = await storeHub.handle('saved', <String, Object?>{'dir': root});
      final list = d['saved'] as List;
      expect(list, hasLength(1));
      final item = list.first as Map;
      expect(item['path'], 'lib/main.dart');
      expect(item['absPath'], '$root/lib/main.dart');
      expect(item['line'], 87);
      expect(item['condition'], 'i>2');
    });

    test('rememberBreakpoint：没 dir 报错；有 dir 写清单且路径转相对', () async {
      // 「一键下断点」在未连会话时只记清单，下次 start/attach 自动重下。
      final bad = await storeHub.handle(
        'rememberBreakpoint',
        <String, Object?>{'path': '$root/lib/main.dart', 'line': 88},
      );
      expect(bad['ok'], isFalse);
      expect('${bad['error']}', contains('项目目录'));
      expect(storeHub.store.load(root), isEmpty);

      final d = await storeHub.handle('rememberBreakpoint', <String, Object?>{
        'dir': root,
        'path': '$root/lib/main.dart',
        'line': 88,
        'logMessage': r'i=$i',
      });
      expect(d['ok'], isTrue);
      final list = storeHub.store.load(root);
      expect(list, hasLength(1));
      expect(list.first.path, 'lib/main.dart');
      expect(list.first.line, 88);
      expect(list.first.logMessage, r'i=$i');
      final saved = d['saved'] as List;
      expect(saved, hasLength(1));
      expect((saved.first as Map)['absPath'], '$root/lib/main.dart');
      expect((saved.first as Map)['logMessage'], r'i=$i');
      expect('${d['message']}', contains('已记住断点'));
    });

    test('savedAll：列出所有项目的清单（无会话时按路径排序）', () async {
      final other = '${tmp.path}/another';
      storeHub.store.add(
        root,
        const SavedBreakpoint(path: 'lib/main.dart', line: 10),
      );
      storeHub.store.add(
        other,
        const SavedBreakpoint(path: 'lib/a.dart', line: 20, logMessage: 'x'),
      );
      final d = await storeHub.handle('savedAll', const <String, Object?>{});
      expect(d['ok'], isTrue);
      expect(d['current'], isNull);
      final projects = d['projects'] as List;
      expect(projects, hasLength(2));
      final dirs = <String>[
        for (final p in projects) '${(p as Map)['dir']}',
      ];
      final sorted = <String>[
        BreakpointStore.normalizeRoot(other),
        BreakpointStore.normalizeRoot(root),
      ]..sort();
      expect(dirs, sorted);
      final items = <Map>[
        for (final p in projects)
          for (final it in (p as Map)['items'] as List) it as Map,
      ];
      expect(items.any((it) => it['logMessage'] == 'x'), isTrue);
    });

    test('forgetSaved：没 dir 报可读错误，有 dir 清空并回报条数', () async {
      final bad = await storeHub.handle('forgetSaved', const <String, Object?>{});
      expect(bad['ok'], isFalse);
      expect('${bad['error']}', contains('项目目录'));

      storeHub.store.add(
        root,
        const SavedBreakpoint(path: 'lib/main.dart', line: 87),
      );
      final d = await storeHub.handle('forgetSaved', <String, Object?>{'dir': root});
      expect(d['ok'], isTrue);
      expect(d['cleared'], 1);
      expect(storeHub.store.load(root), isEmpty);
    });

    test('updateBreakpoint：缺 id / 没连会话都给出可读错误', () async {
      final noId =
          await storeHub.handle('updateBreakpoint', const <String, Object?>{});
      expect(noId['ok'], isFalse);
      expect('${noId['error']}', contains('断点 id'));

      final noSession = await storeHub.handle(
        'updateBreakpoint',
        <String, Object?>{'id': 'breakpoints/1', 'condition': 'x > 1'},
      );
      expect(noSession['ok'], isFalse);
      expect('${noSession['error']}', contains('未连接调试会话'));
    });

    test('forgetBreakpoint：按位置只删一条（源码面板再点取消）', () async {
      storeHub.store.add(
        root,
        const SavedBreakpoint(path: 'lib/a.dart', line: 10),
      );
      storeHub.store.add(
        root,
        const SavedBreakpoint(path: 'lib/a.dart', line: 20),
      );
      final noLine = await storeHub.handle(
        'forgetBreakpoint',
        <String, Object?>{'dir': root, 'path': '$root/lib/a.dart'},
      );
      expect(noLine['ok'], isFalse);
      expect('${noLine['error']}', contains('行号'));

      final noDir = await storeHub.handle(
        'forgetBreakpoint',
        <String, Object?>{'path': '$root/lib/a.dart', 'line': 10},
      );
      expect(noDir['ok'], isFalse);
      expect('${noDir['error']}', contains('项目目录'));

      final d = await storeHub.handle('forgetBreakpoint', <String, Object?>{
        'dir': root,
        'path': '$root/lib/a.dart',
        'line': 10,
      });
      expect(d['ok'], isTrue);
      expect(d['removed'], isTrue);
      expect(storeHub.store.load(root).map((b) => b.line), <int>[20]);
    });
  });
}
