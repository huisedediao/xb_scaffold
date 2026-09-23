import 'xb_track_event.dart';

/// 把事件时间序列转为 Markdown 复现步骤。
///
/// 页面事件渲染为章节锚点，点击与自定义事件渲染为带序号的步骤；
/// auto_click 的语义指纹 + 源码位置（debug 期可得）直接可读。
String xbTrackEventsToMarkdown(List<XBTrackEvent> events) {
  final buffer = StringBuffer();
  buffer.writeln('# 操作路径复现步骤');
  buffer.writeln();

  if (events.isEmpty) {
    buffer.writeln('（无事件）');
    return buffer.toString();
  }

  buffer.writeln(
      '- 导出时间：${_formatTime(events.last.eventTimeMs)}　事件数：${events.length}');
  buffer.writeln();

  var step = 0;
  for (final event in events) {
    final time = _formatTime(event.eventTimeMs);
    switch (event.event) {
      case 'page_enter':
        step = 0;
        buffer.writeln('## 进入页面「${event.pageName ?? _pageOf(event)}」');
        buffer.writeln();
        buffer.writeln('- $time');
        buffer.writeln();
      case 'page_exit':
        final duration = event.params['durationMs'];
        final stay = duration is num ? '（停留 ${_formatDuration(duration)}）' : '';
        buffer.writeln('## 离开页面「${event.pageName ?? _pageOf(event)}」$stay');
        buffer.writeln();
        buffer.writeln('- $time');
        buffer.writeln();
      default:
        step++;
        final page = event.pageName ?? _pageOf(event);
        buffer.writeln('$step. [$page] ${_describeEvent(event)}');
        buffer.writeln('   - $time');
    }
  }
  return buffer.toString();
}

String _describeEvent(XBTrackEvent event) {
  final params = event.params;
  switch (event.event) {
    case 'auto_click':
      final chain = params['typeChain']?.toString() ?? '';
      final text = params['text'];
      final location = _locationOf(params);
      final label = text == null ? '' : '("$text")';
      final at = location == null ? '' : ' @ $location';
      return '**点击** `${chain.isEmpty ? '?' : chain}$label`$at';
    case 'tap':
      return '**点击**（埋点）`${params['trackId'] ?? ''}`';
    default:
      final extra = params.isEmpty ? '' : '　`$params`';
      return '**${event.event}**$extra';
  }
}

String? _locationOf(Map<String, dynamic> params) {
  final file = params['file'];
  final line = params['line'];
  if (file == null || line == null) return null;
  final column = params['column'];
  return '$file:$line${column == null ? '' : ':$column'}';
}

String _pageOf(XBTrackEvent event) => event.pageName ?? '未知页面';

String _formatTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String _formatDuration(num ms) {
  if (ms < 1000) return '${ms}ms';
  final seconds = ms / 1000;
  if (seconds < 60) return '${seconds.toStringAsFixed(1)}s';
  final minutes = seconds ~/ 60;
  return '$minutes分${(seconds % 60).toStringAsFixed(0)}秒';
}
