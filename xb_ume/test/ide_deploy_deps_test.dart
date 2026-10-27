// 部署完整性测试：bin/ide.dart 与 bin/mcp.dart 会被复制到 ~/.xb_ume_ide 下
// 独立运行，dart 只从脚本所在目录解析相对 import。这里锁住两件事：
// 1) bin/ 下不能出现 `package:` 依赖 —— 否则部署副本解析不到，启动即编译失败；
// 2) 部署逻辑必须把整棵 bin/src 与 mcp.dart 一起带过去。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('bin/ide.dart').readAsStringSync();

  test('bin/ 下不出现 package: 依赖（部署副本独立编译的前提）', () {
    final dir = Directory('bin');
    expect(dir.existsSync(), isTrue);
    final offenders = <String>[];
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.readAsStringSync().contains("import 'package:")) {
        offenders.add(e.path);
      }
    }
    expect(offenders, isEmpty,
        reason: '这些文件引入了 package: 依赖，部署副本（~/.xb_ume_ide）无法解析');
  });

  test('部署函数递归复制 bin/src 并带上 mcp.dart', () {
    final start = source.indexOf('Future<void> _deployRuntimeDeps(');
    expect(start, greaterThanOrEqualTo(0), reason: '未找到 _deployRuntimeDeps');
    final end = source.indexOf('\n}\n', start);
    expect(end, greaterThan(start));
    final body = source.substring(start, end);
    expect(body, contains("Directory('\$binDir\${sep}src')"),
        reason: 'src 树要整棵复制，不能只登记单文件');
    expect(body, contains('_copyDartTree'));
    expect(body, contains('mcp.dart'), reason: 'GUI「启动 MCP」依赖部署副本');
    expect(body, contains('version.txt'),
        reason: '部署目录没有 pubspec.yaml，MCP 报版本要靠它回退');
  });

  test('bin/src 与 bin/mcp.dart 真实存在', () {
    expect(Directory('bin/src').existsSync(), isTrue);
    expect(File('bin/mcp.dart').existsSync(), isTrue);
  });
}
