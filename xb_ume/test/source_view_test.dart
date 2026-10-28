// 「源码下断点」面板的只读文件视图单测：
// - 只列项目里的 .dart，构建产物 / 依赖缓存 / 隐藏目录整棵跳过
// - 按行读源码：BOM、CRLF、超长行 / 超行数截断
// - 越界（../）、非 .dart、不存在都给可读错误
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/debug/debug_client.dart' show DebugException;
import '../bin/src/debug/source_view.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('xbd_src_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void write(String rel, String content) {
    final f = File('${tmp.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  group('listDartFiles', () {
    test('列 .dart（相对路径、/ 分隔），跳过构建目录与隐藏目录', () {
      write('lib/main.dart', 'void main() {}');
      write('lib/pages/a.dart', '// a');
      write('test/a_test.dart', '// t');
      write('build/gen.dart', '// build');
      write('.dart_tool/cache.dart', '// cache');
      write('.hidden/x.dart', '// hidden');
      write('README.md', '#');
      expect(listDartFiles(tmp.path), <String>[
        'lib/main.dart',
        'lib/pages/a.dart',
        'test/a_test.dart',
      ]);
    });

    test('目录不存在给可读错误', () {
      expect(
        () => listDartFiles('${tmp.path}/nope'),
        throwsA(isA<DebugException>()),
      );
    });
  });

  group('readSourceFile', () {
    test('返回行与总行数，去掉 BOM 与 CRLF，尾随换行不算多一行', () {
      write('lib/a.dart', '\uFEFFline1\r\nline2\r\nline3\r\n');
      final v = readSourceFile(tmp.path, 'lib/a.dart');
      expect(v.rel, 'lib/a.dart');
      expect(v.total, 3);
      expect(v.lines, <String>['line1', 'line2', 'line3']);
      expect(v.abs, endsWith('/lib/a.dart'));
      expect(v.truncated, isFalse);
    });

    test('超长行截断、超行数截断', () {
      write('lib/b.dart', '${List.filled(20, 'x').join()}\ny\nz\n');
      final v = readSourceFile(tmp.path, 'lib/b.dart',
          maxLines: 1, maxLineLen: 5);
      expect(v.total, 3);
      expect(v.lines, <String>['xxxxx…']);
      expect(v.truncated, isTrue);
    });

    test('越界 / 非 .dart / 绝对路径 / 不存在都报可读错误', () {
      final outside = File('${Directory.systemTemp.path}/xbd_src_outside.dart')
        ..writeAsStringSync('// outside');
      try {
        expect(
          () => readSourceFile(tmp.path, '../xbd_src_outside.dart'),
          throwsA(predicate((e) => '$e'.contains('项目目录内'))),
        );
      } finally {
        if (outside.existsSync()) outside.deleteSync();
      }
      expect(
        () => readSourceFile(tmp.path, 'lib/a.txt'),
        throwsA(predicate((e) => '$e'.contains('.dart'))),
      );
      expect(
        () => readSourceFile(tmp.path, '/etc/hosts'),
        throwsA(predicate((e) => '$e'.contains('相对项目根'))),
      );
      expect(
        () => readSourceFile(tmp.path, 'lib/none.dart'),
        throwsA(predicate((e) => '$e'.contains('不存在'))),
      );
    });
  });
}
