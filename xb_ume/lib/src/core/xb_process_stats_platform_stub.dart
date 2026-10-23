// 无 dart:io 的平台（Web）：不支持进程级采样，GUI 回退到 isolate 采样。
import 'xb_process_stats_types.dart';

void installProcessStatsExtension(Map<String, Object?> Function() sample) {}

XBUmeProcessUsage? readProcessUsage() => null;
