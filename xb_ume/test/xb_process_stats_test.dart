import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/core/xb_process_stats.dart';
import 'package:xb_ume/src/core/xb_process_stats_platform_io.dart';

/// 桌面/真机（dart:io）下的进程级采样：验证 CPU 时间单调增长、
/// 内存字段有值、第二次采样能算出百分比。仅在 macOS/Linux 测试机上跑。
void main() {
  test('readProcessUsage 读取到 CPU 时间与内存', () {
    final a = readProcessUsage();
    expect(a, isNotNull);
    final cpu0 = a!.cpuNs;
    expect(cpu0, isNotNull);
    expect(a.rss, greaterThan(0));

    final sw = Stopwatch()..start();
    var x = 0;
    while (sw.elapsedMilliseconds < 300) {
      for (var i = 0; i < 20000; i++) {
        x += i & 7;
      }
    }
    final b = readProcessUsage()!;
    expect(b.cpuNs!, greaterThan(cpu0!));
    // macOS 用 proc_pid_rusage 取 footprint；Linux 无此口径，允许为空。
    if (a.footprint != null) expect(b.footprint, greaterThan(0));
    // 桌面平台按 Xcode/top 口径（单核 100%），且有核数可供换算。
    expect(a.cpuScope, 'core');
    expect(a.cpuCores, greaterThan(0));
    expect(a.platform, isNotEmpty);
  });

  test('XBUmeProcessStats.sample 第二次调用给出 cpuPercent', () {
    XBUmeProcessStats.sample();
    final sw = Stopwatch()..start();
    var x = 0;
    while (sw.elapsedMilliseconds < 200) {
      for (var i = 0; i < 20000; i++) {
        x += i & 7;
      }
    }
    final s = XBUmeProcessStats.sample();
    expect(s['supported'], isTrue);
    expect(s['cpuPercent'], isA<num>());
    expect((s['cpuPercent'] as num) >= 0, isTrue);
    expect((s['windowMs'] as num) > 0, isTrue);
    expect(s['cpuScope'], anyOf('core', 'total'));
    expect(s['platform'], isNotEmpty);
  });

  test('readProcessUsage 带线程数与系统总内存', () {
    final usage = readProcessUsage();
    expect(usage, isNotNull);
    if (Platform.isMacOS || Platform.isIOS) {
      // task_threads / sysctlbyname("hw.memsize") 在 Apple 平台必须能读到。
      expect(usage!.threads, greaterThan(0));
      expect(usage.totalMemory, greaterThan(0));
    }
  });

  test('sample 给出主内存口径 primaryMemory / memoryScope', () {
    XBUmeProcessStats.sample();
    final s = XBUmeProcessStats.sample();
    expect(s['primaryMemory'], isA<num>());
    expect((s['primaryMemory'] as num) > 0, isTrue);
    expect(s['threads'], isA<num>());
    expect(s['totalMemory'], isA<num>());
    // Apple 取 phys_footprint（Xcode 口径），为 0/不可用时才回退。
    if (Platform.isMacOS || Platform.isIOS) {
      expect(s['memoryScope'], 'footprint');
      expect(s['footprint'], isA<num>());
    }
  });

  test('windowsCpuNsFromFileTime 按 100ns 换算成纳秒', () {
    // GetProcessTimes 的 kernel/user 都是 FILETIME（100ns）；1s = 10_000_000。
    expect(windowsCpuNsFromFileTime(0, 0), 0);
    expect(windowsCpuNsFromFileTime(10000000, 0), 1000000000);
    expect(windowsCpuNsFromFileTime(10000000, 5000000), 1500000000);
    // 异常值（负）按 0 处理，不把负数传给上层换算百分比。
    expect(windowsCpuNsFromFileTime(-1, -1), 0);
  });
}
