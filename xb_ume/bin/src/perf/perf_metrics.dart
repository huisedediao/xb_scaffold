// 性能采样的纯解析函数：GUI 的 /api/perf 与 MCP 的 perf 工具共用一份，
// 避免两边对同一份 VM 响应给出不同口径。
//
// 注意：这里只做解析，不发请求。ext.* 服务扩展在部分会话（例如 macOS 桌面
// 的某些 Flutter 版本）会一直不应答，调用方必须自己控制超时。
library;

import 'dart:convert';

/// 解析 `getCpuSamples` 响应，估算 isolate 在采样窗口内的 CPU 占用率。
/// 每个样本代表一个采样周期（默认 1ms）；Idle 样本表示线程在等消息，
/// 不计入忙时，其余（Dart/GC/Native/VM）均视为线程实际执行。
/// GC 标签在 VM 侧分为 `GC New` / `GC Old` / `GC Idle`，按前缀匹配。
Map<String, Object?> perfCpuFromSamples(Map<String, Object?> samples) {
  final rawPeriod = (samples['samplePeriod'] as num?)?.toInt() ?? 0;
  final periodUs = rawPeriod > 0 ? rawPeriod : 0;
  final extentUs = (samples['timeExtentMicros'] as num?)?.toInt() ?? 0;
  final list = samples['samples'];
  var total = 0;
  var idle = 0;
  var gc = 0;
  if (list is List) {
    for (final item in list) {
      if (item is! Map) continue;
      total++;
      final tag = (item['vmTag'] ?? '').toString().toLowerCase();
      if (tag == 'idle') {
        idle++;
      } else if (tag.startsWith('gc')) {
        gc++;
      }
    }
  }
  final busy = total - idle;
  final pct = (extentUs <= 0 || periodUs <= 0)
      ? 0.0
      : busy * periodUs * 100.0 / extentUs;
  return <String, Object?>{
    'percent': double.parse(pct.clamp(0.0, 100.0).toStringAsFixed(1)),
    'samples': total,
    'busy': busy,
    'idle': idle,
    'gc': gc,
    'periodUs': periodUs,
    'extentUs': extentUs,
  };
}

/// 解析 VM service 对 `ext.*` 服务扩展的响应：多数版本会包一层 `data`
/// （对象或 JSON 字符串），少数直接返回扩展内容。无法识别时返回 null。
Map<String, Object?>? perfExtensionData(Object? result) {
  if (result is! Map) return null;
  final data = result['data'];
  if (data == null) {
    final direct = result.cast<String, Object?>();
    return direct.containsKey('cpuPercent') || direct.containsKey('supported')
        ? direct
        : null;
  }
  Object? parsed = data;
  if (parsed is String) {
    try {
      parsed = jsonDecode(parsed);
    } catch (_) {
      return null;
    }
  }
  return parsed is Map ? parsed.cast<String, Object?>() : null;
}

/// 把 `getProcessMemoryUsage` 的 root 树压平成前端可直接渲染的顶层分桶。
/// size 为 retain 后的字节数；root.size 即进程总内存，个别平台可能为 -1。
Map<String, Object?> perfProcessMemory(Map<String, Object?> result) {
  final root = result['root'];
  if (root is! Map) return <String, Object?>{'error': '进程内存不可用'};
  int sizeOf(Object? item) =>
      item is Map ? ((item['size'] as num?)?.toInt() ?? 0) : 0;
  final total = sizeOf(root);
  final items = <Map<String, Object?>>[];
  final children = root['children'];
  if (children is List) {
    for (final child in children) {
      if (child is! Map) continue;
      final size = sizeOf(child);
      if (size <= 0) continue;
      items.add(<String, Object?>{
        'name': child['name']?.toString() ?? '',
        'description': child['description']?.toString() ?? '',
        'size': size,
      });
    }
  }
  items.sort((a, b) => (b['size'] as int).compareTo(a['size'] as int));
  final shown = items.take(12).toList();
  if (total > 0) {
    // 部分平台只回一个「Dart VM」分桶，行合计会明显小于总常驻内存；
    // 补一行差额，避免表格与总数看起来对不上（例如 macOS 只细分 Dart VM）。
    final listed = shown.fold<int>(0, (sum, e) => sum + (e['size'] as int));
    final rest = total - listed;
    if (rest > 0) {
      shown.add(<String, Object?>{
        'name': '其他',
        'description': '总常驻内存中未细分到上述子项的部分',
        'size': rest,
      });
    }
  }
  return <String, Object?>{
    'rss': total > 0 ? total : null,
    'name': root['name']?.toString() ?? '',
    'description': root['description']?.toString() ?? '',
    'items': shown,
  };
}
