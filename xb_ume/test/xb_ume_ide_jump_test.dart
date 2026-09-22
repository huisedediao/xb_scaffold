import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/core/xb_ume_ide_jump.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('XBUmeIdeJump.buildLocationText', () {
    test('file URI 转本地路径并拼行列', () {
      expect(
        XBUmeIdeJump.buildLocationText(
          file: 'file:///Users/demo/app/lib/main.dart',
          line: 14,
          column: 5,
        ),
        '/Users/demo/app/lib/main.dart:14:5',
      );
    });

    test('非 URI 路径原样拼接', () {
      expect(
        XBUmeIdeJump.buildLocationText(
          file: '/a/b.dart',
          line: 1,
          column: null,
        ),
        '/a/b.dart:1',
      );
    });

    test('信息不足返回 null', () {
      expect(
        XBUmeIdeJump.buildLocationText(file: null, line: 1, column: 1),
        isNull,
      );
      expect(
        XBUmeIdeJump.buildLocationText(file: '', line: 1, column: 1),
        isNull,
      );
      expect(
        XBUmeIdeJump.buildLocationText(file: '/a.dart', line: null, column: 1),
        isNull,
      );
    });
  });

  group('XBUmeIdeJump.requestOpen', () {
    test('无有效位置返回 false 且不抛异常', () async {
      expect(
        await XBUmeIdeJump.requestOpen(file: null, line: null, column: null),
        isFalse,
      );
    });

    test('有效位置发出事件（测试环境无 VM service 也不应抛异常）', () async {
      final sent = await XBUmeIdeJump.requestOpen(
        file: 'file:///a.dart',
        line: 3,
        column: 4,
      );
      expect(sent, isTrue);
    });
  });

  test('toFilePath 非 file scheme 原样返回', () {
    expect(XBUmeIdeJump.toFilePath('dart:///x'), 'dart:///x');
    expect(XBUmeIdeJump.toFilePath('not a uri'), 'not a uri');
  });
}
