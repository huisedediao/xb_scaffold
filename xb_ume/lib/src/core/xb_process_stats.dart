import 'package:flutter/foundation.dart';

import 'xb_process_stats_platform_stub.dart'
    if (dart.library.io) 'xb_process_stats_platform_io.dart' as platform;

/// 进程级资源采样（CPU / 常驻内存 / footprint）。
///
/// CPU 口径与 Xcode 调试导航器、macOS 活动监视器一致：进程内所有线程
/// （Dart、UI、光栅、IO、平台线程）累计 user+sys CPU 时间增量 ÷ 墙钟增量，
/// 单核占满为 100%，多核并行可超过 100%。与 VM service 的
/// `getCpuSamples` 不同，后者只覆盖 Dart 主 isolate。
///
/// GUI 通过服务扩展 `ext.xbume.processStats` 拉取；未注册（旧版 SDK /
/// release 构建）时调用方回退到 isolate 采样。
class XBUmeProcessStats {
  XBUmeProcessStats._();

  static bool _installed = false;
  static int? _lastCpuNs;
  static int? _lastWallUs;

  /// 注册服务扩展；debug/profile 下由 [XBUmeBinding] 启动时调用。
  static void install() {
    if (_installed || kReleaseMode) return;
    _installed = true;
    platform.installProcessStatsExtension(sample);
  }

  /// 采样一次。首次调用只记录基准，返回结果里没有 `cpuPercent`。
  static Map<String, Object?> sample() {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final raw = platform.readProcessUsage();
    final out = <String, Object?>{
      'ok': true,
      'ts': nowUs,
      'supported': raw != null,
    };
    if (raw == null) return out;
    out['rss'] = raw.rss;
    out['footprint'] = raw.footprint;
    final cpuNs = raw.cpuNs;
    if (cpuNs != null) {
      final lastCpu = _lastCpuNs;
      final lastWall = _lastWallUs;
      if (lastCpu != null && lastWall != null) {
        final dCpu = cpuNs - lastCpu;
        final dWall = nowUs - lastWall;
        if (dCpu >= 0 && dWall > 0) {
          // dCpu 为纳秒、dWall 为微秒，比值正好是百分比的 10 倍。
          out['cpuPercent'] = (dCpu / dWall).round() / 10;
          out['windowMs'] = (dWall / 1000).round();
        }
      }
      _lastCpuNs = cpuNs;
      _lastWallUs = nowUs;
    }
    return out;
  }
}
