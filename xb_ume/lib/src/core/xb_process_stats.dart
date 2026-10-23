import 'package:flutter/foundation.dart';

import 'xb_process_stats_platform_stub.dart'
    if (dart.library.io) 'xb_process_stats_platform_io.dart' as platform;

/// 进程级资源采样（CPU / 常驻内存 / footprint / PSS）。
///
/// CPU 覆盖进程内所有线程（Dart、UI、光栅、IO、平台线程）的 user+sys：
/// iOS/macOS 按 Xcode 调试导航器口径以单核占满为 100%；Android/OHOS 按
/// Android Studio / DevEco Profiler 口径以全部核心容量合计为 100%。
/// 与 VM service 的 `getCpuSamples` 不同，后者只覆盖 Dart 主 isolate。
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
    out['pss'] = raw.pss;
    out['pssItems'] = raw.pssItems;
    out['platform'] = raw.platform;
    final cores = raw.cpuCores ?? 1;
    out['cpuCores'] = cores;
    out['cpuScope'] = raw.cpuScope;
    final cpuNs = raw.cpuNs;
    if (cpuNs != null) {
      final lastCpu = _lastCpuNs;
      final lastWall = _lastWallUs;
      if (lastCpu != null && lastWall != null) {
        final dCpu = cpuNs - lastCpu;
        final dWall = nowUs - lastWall;
        // 窗口超过 10 秒（例如页面隐藏/暂停后首次恢复）算出来的是长时间均值，
        // 不具代表性，丢弃本次百分比，下一次轮询即可给出正常窗口值。
        if (dCpu >= 0 && dWall > 0 && dWall <= 10000000) {
          // dCpu 纳秒 / dWall 微秒 = 单核口径百分比的 10 倍；Android/OHOS
          // 再除以核数，换算成官方工具的「占全部核心容量」百分比。
          var pct = dCpu / dWall / 10;
          if (raw.cpuScope == 'total' && cores > 1) pct = pct / cores;
          out['cpuPercent'] = (pct * 10).round() / 10;
          out['windowMs'] = (dWall / 1000).round();
        }
      }
      _lastCpuNs = cpuNs;
      _lastWallUs = nowUs;
    }
    return out;
  }
}
