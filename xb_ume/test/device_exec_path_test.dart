// GUI / daemon 由 Finder、launchd 或 IDE 图形界面拉起时 PATH 只剩
// /usr/bin:/bin:/usr/sbin:/sbin，flutter / adb / hdc 全都会「找不到」。
// 这里守住兜底解析的语义：PATH 优先、兜底只补真实目录、子进程环境整体继承。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/process.dart';

void main() {
  final sep = Platform.isWindows ? ';' : ':';

  test('兜底目录都必须是真实存在的绝对路径', () {
    for (final dir in fallbackBinDirs()) {
      expect(dir.trim(), isNotEmpty);
      expect(Directory(dir).existsSync(), isTrue, reason: '兜底目录不存在：$dir');
      expect(dir.contains('null'), isFalse, reason: '环境变量为空时不能拼出 null：$dir');
    }
  });

  test('execSearchPath：原 PATH 在前，兜底目录追加去重', () {
    final path = execSearchPath();
    final parts = path.split(sep);
    expect(parts.every((p) => p.trim().isNotEmpty), isTrue);
    expect(parts.length, parts.toSet().length, reason: '不应出现重复目录');

    final original = (Platform.environment['PATH'] ?? '')
        .split(sep)
        .where((p) => p.trim().isNotEmpty)
        .toList();
    if (original.isNotEmpty) {
      expect(parts.first, original.first, reason: 'PATH 原有顺序要保持');
    }
    for (final dir in fallbackBinDirs()) {
      expect(parts.contains(dir), isTrue, reason: '兜底目录未进入 PATH：$dir');
    }
  });

  test('execEnvironment：整体继承本进程环境，只替换 PATH', () {
    final env = execEnvironment();
    expect(env['PATH'], execSearchPath());
    expect(
      env.keys.where((k) => k.toUpperCase() == 'PATH').length,
      1,
      reason: 'Windows 上不能同时留 Path 与 PATH',
    );
    for (final key in Platform.environment.keys) {
      if (key.toUpperCase() == 'PATH') continue;
      expect(env.containsKey(key), isTrue, reason: '环境变量被丢掉：$key');
    }
  });

  test('execEnvironment：额外变量覆盖同名项', () {
    final env = execEnvironment(<String, String>{'XB_UME_PROBE': '1'});
    expect(env['XB_UME_PROBE'], '1');
  });

  test('findExecutable：已是绝对路径时只看文件是否存在', () {
    expect(findExecutable('/definitely/not/here/flutter'), isNull);
  });
}
