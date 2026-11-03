// app 端日志落盘（XBUmeConfig.logFile* + XBUmeController.addLog）单测：
// 写入内容、logFilePath、清屏分隔标记、关闭开关、按大小轮转。
//
// 走 public API（XBUmeController），顺带覆盖 io/stub 条件导入的工厂接线。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/xb_ume.dart';

/// 不落盘的内存持久化（单测不关心快照）。
class _MemoryPersistence implements XBUmePersistence {
  @override
  Future<Map<String, dynamic>?> load() async => null;

  @override
  Future<void> save(Map<String, dynamic> json) async {}
}

XBUmeConfig _config(
  String dir, {
  bool enabled = true,
  int maxBytes = 4 * 1024 * 1024,
  int backups = 2,
}) {
  return XBUmeConfig(
    logFileEnabled: enabled,
    logFileDir: dir,
    logFileName: 'console.log',
    logFileMaxBytes: maxBytes,
    logFileBackups: backups,
  );
}

XBUmeController _controller(XBUmeConfig config) => XBUmeController(
      config: config,
      persistence: _MemoryPersistence(),
    );

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xbume_log_');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('addLog 同步落盘，logFilePath 指向文件且内容格式可读', () async {
    final c = _controller(_config(dir.path));
    addTearDown(c.dispose);

    c.addLog(
      level: XBUmeLogLevel.info,
      tag: 'order',
      message: 'hello 世界',
    );
    final path = c.logFilePath;
    expect(path, '${dir.path}/console.log');

    await c.flushLogFile();
    final text = File(path!).readAsStringSync();
    expect(text, contains('[INFO] order: hello 世界'));
    // 每行以 ISO8601 时间开头，方便 AI / grep 按时间定位。
    expect(text, contains(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')));
  });

  test('带栈的日志把栈也写进文件', () async {
    final c = _controller(_config(dir.path));
    addTearDown(c.dispose);

    c.addLog(
      level: XBUmeLogLevel.error,
      tag: 'boom',
      message: 'failed',
      stack: '#0 main (lib/main.dart:1:1)',
    );
    await c.flushLogFile();
    final text = File(c.logFilePath!).readAsStringSync();
    expect(text, contains('[ERROR] boom: failed'));
    expect(text, contains('#0 main (lib/main.dart:1:1)'));
  });

  test('clearLogs 只清内存，落盘文件保留旧内容并追加分隔标记', () async {
    final c = _controller(_config(dir.path));
    addTearDown(c.dispose);

    c.addLog(level: XBUmeLogLevel.info, tag: 't', message: 'before-clear');
    c.clearLogs();
    expect(c.logs, isEmpty);
    await c.flushLogFile();
    final text = File(c.logFilePath!).readAsStringSync();
    expect(text, contains('before-clear'));
    expect(text, contains('---- console cleared'));
  });

  test('关闭落盘时不建文件，logFilePath 为 null', () async {
    final c = _controller(_config(dir.path, enabled: false));
    addTearDown(c.dispose);

    c.addLog(level: XBUmeLogLevel.info, tag: 't', message: 'no-file');
    expect(c.logFilePath, isNull);
    await c.flushLogFile();
    expect(File('${dir.path}/console.log').existsSync(), isFalse);
  });

  test('超过大小上限轮转，只保留 backups 个历史文件', () async {
    final c = _controller(_config(dir.path, maxBytes: 300, backups: 1));
    addTearDown(c.dispose);

    for (var i = 0; i < 20; i++) {
      c.addLog(
        level: XBUmeLogLevel.info,
        tag: 't',
        message: 'line-$i-${'x' * 60}',
      );
    }
    await c.flushLogFile();

    expect(File('${dir.path}/console.log.1').existsSync(), isTrue);
    expect(File('${dir.path}/console.log.2').existsSync(), isFalse);
  });
}
