// 部署完整性测试：bin/ide.dart 会被复制到 ~/.xb_ume_ide 下独立运行，
// dart 只从脚本所在目录解析相对 import。新增一个相对 import 却忘了登记
// 进 _kIdeRuntimeDeps，部署副本就会启动即编译失败（GUI 只报「未检测到
// daemon」，无从下手）。这里用源码解析把两边锁死。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('bin/ide.dart').readAsStringSync();

  Set<String> relativeImports() => RegExp(r"""^import\s+'(src/[^']+)';""", multiLine: true)
      .allMatches(source)
      .map((m) => m.group(1)!)
      .toSet();

  Set<String> declaredDeps() {
    final block = RegExp(r'_kIdeRuntimeDeps = <String>\[(.*?)\];', dotAll: true)
        .firstMatch(source)
        ?.group(1);
    expect(block, isNotNull, reason: '未找到 _kIdeRuntimeDeps 清单');
    return RegExp(r"""'([^']+)'""")
        .allMatches(block!)
        .map((m) => m.group(1)!)
        .toSet();
  }

  test('_kIdeRuntimeDeps 覆盖 bin/ide.dart 的全部相对 import', () {
    final imports = relativeImports();
    expect(imports, isNotEmpty, reason: 'ide.dart 应至少有一个相对依赖');
    expect(
      declaredDeps(),
      containsAll(imports),
      reason: '有相对 import 未登记进 _kIdeRuntimeDeps，部署副本会起不来',
    );
  });

  test('清单里的每个依赖在源码树中真实存在', () {
    for (final rel in declaredDeps()) {
      expect(File('bin/$rel').existsSync(), isTrue, reason: '缺失 bin/$rel');
    }
  });

  test('清单只登记 src/ 下的相对路径（部署目录结构假设）', () {
    for (final rel in declaredDeps()) {
      expect(rel.startsWith('src/'), isTrue, reason: '$rel 不在 src/ 下');
    }
  });
}
