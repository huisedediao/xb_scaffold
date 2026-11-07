// 直连会话 Watch 的纯逻辑：字段路径取值、展示串、条件本地比较。
library;

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/session/agent_watch.dart';

/// 与 `/v1/inspect` 同形的字段树（map 根 → count / name / tags / user）。
Map<String, Object?> node({
  required String name,
  required String kind,
  Object? cls,
  Object? value,
  int? length,
  List<Map<String, Object?>>? children,
}) =>
    <String, Object?>{
      'name': name,
      'kind': kind,
      if (cls != null) 'cls': cls,
      if (value != null) 'value': value,
      if (length != null) 'length': length,
      if (children != null) 'children': children,
    };

void main() {
  group('watchCondLite', () {
    test('数字按数值比较，不是字符串字典序', () {
      expect(watchCondLite('value>9', '12'), isTrue);
      expect(watchCondLite('>9', '8'), isFalse);
      expect(watchCondLite('v == 3', '3'), isTrue);
      expect(watchCondLite('<=2', '2.5'), isFalse);
    });

    test('字符串按字典序 / 相等比较，支持引号与 contains', () {
      expect(watchCondLite('value==done', 'done'), isTrue);
      expect(watchCondLite('value != "done"', 'done'), isFalse);
      expect(watchCondLite('value contains ok', 'all ok now'), isTrue);
      expect(watchCondLite('contains:ok', 'all ok now'), isNull);
    });

    test('语法不支持或空条件返回 null（添加监听时要拒绝）', () {
      expect(watchCondLite('', '1'), isNull);
      expect(watchCondLite('a && b', '1'), isNull);
      expect(watchCondLite('value', '1'), isNull);
      expect(watchCondLiteHint(), contains('value'));
    });
  });

  group('agentWatchPick', () {
    final root = node(
      name: 'demo',
      kind: 'map',
      length: 3,
      children: <Map<String, Object?>>[
        node(name: 'count', kind: 'value', cls: 'int', value: '3'),
        node(name: 'name', kind: 'value', cls: 'String', value: '小明'),
        node(
          name: 'tags',
          kind: 'list',
          length: 2,
          children: <Map<String, Object?>>[
            node(name: '[0]', kind: 'value', cls: 'String', value: 'x'),
            node(name: '[1]', kind: 'value', cls: 'String', value: 'y'),
          ],
        ),
      ],
    );

    test('空路径取整棵树的一层摘要', () {
      expect(agentWatchPick(root, ''), 'map(3){count: 3, name: 小明, tags: list(2)}');
      expect(agentWatchPick(root, '   '), contains('count: 3'));
    });

    test('标量字段与列表下标都能取到', () {
      expect(agentWatchPick(root, 'count'), '3');
      expect(agentWatchPick(root, 'tags[0]'), 'x');
      expect(agentWatchPick(root, 'tags[1]'), 'y');
    });

    test('路径不存在 / 下标越界 / 超出展开深度都报错而不是静默旧值', () {
      expect(() => agentWatchPick(root, 'missing'), throwsFormatException);
      expect(() => agentWatchPick(root, 'tags[5]'), throwsFormatException);
      final shallow = node(name: 'demo', kind: 'map', length: 9);
      expect(
        () => agentWatchPick(shallow, 'count'),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('展开深度'))),
      );
    });
  });

  group('agentWatchNodeText', () {
    test('map / list 只展开一层，深层只给条目数', () {
      final deep = node(
        name: 'user',
        kind: 'map',
        length: 1,
        children: <Map<String, Object?>>[
          node(name: 'tags', kind: 'list', length: 9),
        ],
      );
      expect(agentWatchNodeText(deep), 'map(1){tags: list(9)}');
    });

    test('value / opaque 有稳定展示串', () {
      expect(
        node(name: 'a', kind: 'value', value: 'null').let(agentWatchNodeText),
        'null',
      );
      expect(
        node(name: 'a', kind: 'opaque', cls: '（节点过多）')
            .let(agentWatchNodeText),
        '<（节点过多）…>',
      );
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}