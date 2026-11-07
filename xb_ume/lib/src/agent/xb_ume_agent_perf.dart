// 直连 Agent 的性能数据面（P3）：`/v1/perf`。
//
// 直连会话（release 包）没有 Dart VM 的 `getMemoryUsage` / `getCpuSamples`，
// 这里用两样 AOT 可用的数据拼出能看的面板：
//   - 帧耗时：app 内 `addTimingsCallback` 早就采集好了（`controller.frames`）；
//   - 进程 CPU / RSS / PSS / footprint：与 GUI 经 `ext.xbume.processStats`
//     拿的是同一份实现（`XBUmeProcessStats.sample`）。
//
// 返回形状对齐 GUI `/api/perf`，没有 VM 的字段（heap/isolate cpu）不给，
// 前端按「无 VM」降级，不伪造数字。
library;

import 'dart:io';

import '../core/xb_process_stats.dart';
import '../core/xb_ume_controller.dart';

/// 端点：`/v1/perf?windowMs=`（窗口与 GUI 一致：0.5–5 秒）。
///
/// 首次调用拿不到 `cpuPercent`（进程 CPU 需要两次采样做差），GUI 侧下一轮
/// 轮询即正常——服务启动时预热过一次，实际第一次就有值。
Map<String, Object?> agentPerfJson(
  XBUmeController controller, {
  int windowMs = 2000,
  String app = '',
}) {
  final win = windowMs.clamp(500, 5000);
  final now = DateTime.now();
  final since = now.subtract(Duration(milliseconds: win));
  final frames = controller.frames
      .where((f) => f.time.isAfter(since))
      .toList(growable: false);

  var build = 0.0;
  var raster = 0.0;
  var total = 0.0;
  var maxTotal = 0.0;
  var jank = 0;
  for (final f in frames) {
    build += f.buildMs;
    raster += f.rasterMs;
    total += f.totalMs;
    if (f.totalMs > maxTotal) maxTotal = f.totalMs;
    if (f.isJank) jank++;
  }
  final n = frames.length;
  final fps = n == 0 ? 0.0 : n / (win / 1000);

  Map<String, Object?> stats;
  try {
    stats = XBUmeProcessStats.sample();
  } catch (e) {
    stats = <String, Object?>{
      'ok': false,
      'supported': false,
      'error': e.toString(),
    };
  }
  final rss = (stats['rss'] as num?)?.toInt() ?? 0;

  return <String, Object?>{
    'ok': true,
    'ts': now.millisecondsSinceEpoch,
    'windowMs': win,
    'app': app,
    'os': Platform.operatingSystem,
    'isolates': 1,
    'frames': <String, Object?>{
      'count': n,
      'windowMs': win,
      'jank': jank,
      'jankRate': n == 0 ? 0.0 : _round(jank / n),
      'fps': _round(fps),
      'avgBuildMs': n == 0 ? 0.0 : _round(build / n),
      'avgRasterMs': n == 0 ? 0.0 : _round(raster / n),
      'avgTotalMs': n == 0 ? 0.0 : _round(total / n),
      'maxTotalMs': _round(maxTotal),
    },
    'processStats': stats,
    if (rss > 0)
      'process': <String, Object?>{
        'rss': rss,
        'name': '进程',
        'items': const <Object?>[],
      },
    // 说明为什么不给这两块，前端会原样显示在副标题里。
    'heapError': '直连会话没有 Dart VM 堆指标（VM 会话可用）',
    'cpuError': '直连会话没有 Dart isolate 采样（CPU 取整进程口径）',
  };
}

double _round(num v) => (v * 10).round() / 10;