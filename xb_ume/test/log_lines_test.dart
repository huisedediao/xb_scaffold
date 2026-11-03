// 设备日志解析与过滤单测：用四个平台的真实行样本锁定级别识别与筛选行为。
//
// 这里最容易出的错是"把多行异常栈当低级别日志过滤掉"，导致 AI 拿到
// 一个没有调用栈的报错；所以专门有一条用例钉住"认不出级别的行必须保留"。
library;

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/log_lines.dart';

void main() {
  group('lineLevel 识别四平台行格式', () {
    test('logcat -v time（L/Tag( pid) 形式）', () {
      expect(
        lineLevel('10-26 17:00:00.001 D/Flutter( 1234): hello'),
        'D',
      );
      expect(
        lineLevel('10-26 17:00:00.001 E/flutter( 1234): Unhandled exception'),
        'E',
      );
    });

    test('logcat threadtime / hilog（pid tid L 形式）', () {
      expect(
        lineLevel('10-26 17:00:00.001  4321  4321 E AndroidRuntime: FATAL EXCEPTION: main'),
        'E',
      );
      expect(
        lineLevel('01-01 08:00:00.000  1234  5678 I C01800/MyTag: message'),
        'I',
      );
    });

    test('iOS syslog 与 simctl compact 的级别名', () {
      expect(lineLevel('Oct 12 14:23:01  MyApp[1234] <Notice>: hi'), 'I');
      expect(lineLevel('Oct 12 14:23:01  MyApp[1234] <Error>: boom'), 'E');
      expect(
        lineLevel('2026-10-12 14:23:01.123-0700  MyApp[1234:5678] [Fault] crash'),
        'F',
      );
    });

    test('正文里的单个字母不算级别', () {
      expect(lineLevel('flutter: E is for effort'), isNull);
      expect(lineLevel('    at some/path.dart:12'), isNull);
    });
  });

  group('filterDeviceLog', () {
    final raw = <String>[
      '10-26 17:00:00.000  100  100 I/flutter( 100): app start',
      '10-26 17:00:00.100  100  100 D/flutter( 100): Order tap 42',
      '10-26 17:00:00.200  200  200 W/ActivityManager: slow operation',
      '10-26 17:00:00.300  100  100 E/flutter( 100): Exception: boom',
      'java.lang.IllegalStateException: broken',
      '    at OrderPage.build (package:demo/order.dart:42:7)',
      '10-26 17:00:00.400  100  100 I/flutter( 100): done',
    ].join('\n');

    test('keyword 忽略大小写', () {
      final r = filterDeviceLog(raw, query: const DeviceLogQuery(keyword: 'order'));
      expect(r.matched, 2);
      expect(r.lines, hasLength(2));
      expect(r.lines.first, contains('Order tap 42'));
    });

    test('tag 子串匹配（flutter / ActivityManager）', () {
      final r = filterDeviceLog(raw, query: const DeviceLogQuery(tag: 'flutter'));
      expect(r.matched, 4);
      final am = filterDeviceLog(raw, query: const DeviceLogQuery(tag: 'ActivityManager'));
      expect(am.lines.single, contains('slow operation'));
    });

    test('level 之下的行被丢掉，但认不出级别的栈行必须保留', () {
      final r = filterDeviceLog(raw, query: const DeviceLogQuery(level: 'E'));
      expect(r.lines.first, contains('Exception: boom'));
      // 紧接着的两行是栈（认不出级别）→ 保留，否则 AI 只拿到一句 "boom"
      expect(r.lines, hasLength(3));
      expect(r.lines[1], contains('IllegalStateException'));
      expect(r.lines[2], contains('order.dart:42'));
    });

    test('limit 只回最后 N 条，total/matched 仍反映全量', () {
      final r = filterDeviceLog(raw, query: const DeviceLogQuery(limit: 2));
      expect(r.total, 7);
      expect(r.matched, 7);
      expect(r.lines, hasLength(2));
      expect(r.lines.last, contains('done'));
    });

    test('空行与 \\r 被清掉', () {
      final r = filterDeviceLog('a\r\n\r\nb\r\n', query: const DeviceLogQuery());
      expect(r.lines, <String>['a', 'b']);
      expect(r.total, 2);
    });
  });
}
