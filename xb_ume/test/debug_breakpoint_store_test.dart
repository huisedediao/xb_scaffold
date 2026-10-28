// 断点落盘（BreakpointStore）的单测：
// VM 在调试客户端断开时会删掉它建的断点，GUI 重启后断点表必然是空的，
// 这份清单就是「重连同一项目自动恢复」的依据。这里锁：
// - 读写往返、项目隔离、同位置覆盖
// - 项目内文件存相对路径（项目搬走仍能用）、项目外存绝对路径
// - 坏 JSON 不崩、删/启停/清空
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/debug/breakpoint_store.dart';

void main() {
  late Directory tmp;
  late BreakpointStore store;
  late String root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xbd_store_');
    store = BreakpointStore(filePath: '${tmp.path}/debug/breakpoints.json');
    root = '${tmp.path}/proj';
    Directory('$root/lib').createSync(recursive: true);
    File('$root/lib/main.dart').writeAsStringSync('void main() {}\n');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('路径', () {
    test('项目内文件转相对，项目外保持绝对', () {
      expect(
        BreakpointStore.relativePathOf(root, '$root/lib/main.dart'),
        'lib/main.dart',
      );
      expect(
        BreakpointStore.relativePathOf(root, '${tmp.path}/other/a.dart'),
        '${tmp.path}/other/a.dart',
      );
    });

    test('相对路径还原绝对，绝对路径原样', () {
      expect(
        BreakpointStore.absolutePathOf(root, 'lib/main.dart'),
        '$root/lib/main.dart',
      );
      expect(
        BreakpointStore.absolutePathOf(root, '/tmp/x/a.dart'),
        '/tmp/x/a.dart',
      );
    });

    test('项目根归一化：去尾部斜杠，/ 不变成空串', () {
      expect(BreakpointStore.normalizeRoot('$root/'), BreakpointStore.normalizeRoot(root));
      final one = BreakpointStore.normalizeRoot('/');
      expect(one.isNotEmpty, isTrue);
      expect(one, anyOf('/', r'\'));
    });
  });

  group('读写', () {
    test('空文件 / 不存在都回空表', () {
      expect(store.load(root), isEmpty);
      File(store.filePath)
        ..createSync(recursive: true)
        ..writeAsStringSync('{not json');
      expect(store.load(root), isEmpty);
    });

    test('add 后能 load，字段完整', () {
      expect(
        store.add(
          root,
          const SavedBreakpoint(
            path: 'lib/main.dart',
            line: 87,
            condition: 'i > 3',
            enabled: false,
          ),
        ),
        isTrue,
      );
      final list = store.load(root);
      expect(list, hasLength(1));
      expect(list.first.path, 'lib/main.dart');
      expect(list.first.line, 87);
      expect(list.first.condition, 'i > 3');
      expect(list.first.enabled, isFalse);
    });

    test('同位置再 add 是覆盖，不重复', () {
      store.add(root, const SavedBreakpoint(path: 'lib/main.dart', line: 87));
      final added = store.add(
        root,
        const SavedBreakpoint(
          path: 'lib/main.dart',
          line: 87,
          condition: 'n == 0',
        ),
      );
      expect(added, isFalse);
      final list = store.load(root);
      expect(list, hasLength(1));
      expect(list.first.condition, 'n == 0');
    });

    test('不同项目互不影响，清空只影响一个项目', () {
      final other = '${tmp.path}/proj2';
      store.add(root, const SavedBreakpoint(path: 'lib/main.dart', line: 10));
      store.add(other, const SavedBreakpoint(path: 'lib/a.dart', line: 20));
      expect(store.load(root), hasLength(1));
      expect(store.load(other), hasLength(1));

      expect(store.clear(root), 1);
      expect(store.load(root), isEmpty);
      expect(store.load(other), hasLength(1));
    });

    test('remove 按位置删，setEnabled 只改状态', () {
      store.add(root, const SavedBreakpoint(path: 'lib/main.dart', line: 87));
      store.add(root, const SavedBreakpoint(path: 'lib/main.dart', line: 99));

      expect(
        store.setEnabled(root, 'lib/main.dart', 87, false),
        isTrue,
      );
      expect(store.load(root).firstWhere((b) => b.line == 87).enabled, isFalse);

      expect(store.remove(root, 'lib/main.dart', 87), isTrue);
      final list = store.load(root);
      expect(list, hasLength(1));
      expect(list.first.line, 99);

      // 删不存在的位置：返回 false，不影响文件。
      expect(store.remove(root, 'lib/main.dart', 123), isFalse);
      expect(store.load(root), hasLength(1));
    });

    test('文件是合法 JSON 且能被别处读回（跨进程共享）', () {
      store.add(root, const SavedBreakpoint(path: 'lib/main.dart', line: 87));
      final raw = jsonDecode(File(store.filePath).readAsStringSync());
      expect(raw, isA<Map>());
      final projects = (raw as Map)['projects'] as Map;
      expect(projects, contains(BreakpointStore.normalizeRoot(root)));
      final items = projects[BreakpointStore.normalizeRoot(root)] as List;
      expect((items.first as Map)['line'], 87);
      // 临时文件不应残留。
      expect(File('${store.filePath}.tmp').existsSync(), isFalse);
    });
  });

  group('SavedBreakpoint', () {
    test('fromJson 拒绝缺字段 / 非法行号', () {
      expect(SavedBreakpoint.fromJson(null), isNull);
      expect(SavedBreakpoint.fromJson(<String, Object?>{}), isNull);
      expect(
        SavedBreakpoint.fromJson(<String, Object?>{'path': 'a.dart', 'line': 0}),
        isNull,
      );
      final ok = SavedBreakpoint.fromJson(
        <String, Object?>{'path': 'a.dart', 'line': 3, 'enabled': false},
      );
      expect(ok?.enabled, isFalse);
    });

    test('列只在两边都给时才参与同位置判定', () {
      const a = SavedBreakpoint(path: 'a.dart', line: 3);
      const b = SavedBreakpoint(path: 'a.dart', line: 3, column: 5);
      const c = SavedBreakpoint(path: 'a.dart', line: 3, column: 9);
      expect(a.sameLocation(b), isTrue);
      expect(b.sameLocation(c), isFalse);
      expect(a.sameLocation(const SavedBreakpoint(path: 'b.dart', line: 3)),
          isFalse);
    });
  });
}
