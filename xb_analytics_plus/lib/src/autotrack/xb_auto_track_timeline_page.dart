import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/xb_track_event.dart';
import '../xb_track_api.dart';

/// 操作路径时间线：按时间正序展示页面进入/离开与点击步骤，
/// 支持一键复制 Markdown 复现步骤（走 [xbExportTrackAsMarkdown]）。
class XBAutoTrackTimelinePage extends StatefulWidget {
  const XBAutoTrackTimelinePage({super.key, this.limit = 200});

  /// 最多加载的事件条数。
  final int limit;

  @override
  State<XBAutoTrackTimelinePage> createState() =>
      _XBAutoTrackTimelinePageState();
}

class _XBAutoTrackTimelinePageState extends State<XBAutoTrackTimelinePage> {
  List<XBTrackEvent>? _events;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final events = await xbReadTrackLocalLatest(limit: widget.limit);
    if (!mounted) return;
    setState(() => _events = events);
  }

  Future<void> _copyMarkdown() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final markdown = await xbExportTrackAsMarkdown(limit: widget.limit);
      await Clipboard.setData(ClipboardData(text: markdown));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Markdown 复现步骤已复制到剪贴板')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = _events;
    return Scaffold(
      appBar: AppBar(
        title: const Text('操作路径时间线'),
        actions: <Widget>[
          IconButton(
            tooltip: '复制 Markdown 复现步骤',
            onPressed: _exporting ? null : _copyMarkdown,
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: events == null
          ? const Center(child: CircularProgressIndicator())
          : events.isEmpty
              ? const Center(child: Text('暂无事件'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: events.length,
                  itemBuilder: (context, index) =>
                      _EventTile(event: events[index]),
                ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final XBTrackEvent event;

  @override
  Widget build(BuildContext context) {
    final isPageEvent =
        event.event == 'page_enter' || event.event == 'page_exit';
    return ListTile(
      dense: true,
      leading: Icon(
        _iconOf(event),
        size: 20,
        color: isPageEvent ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(_titleOf(event)),
      subtitle: Text(
        _subtitleOf(event),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
    );
  }

  IconData _iconOf(XBTrackEvent event) {
    switch (event.event) {
      case 'page_enter':
        return Icons.login;
      case 'page_exit':
        return Icons.logout;
      case 'auto_click':
      case 'tap':
        return Icons.ads_click;
      default:
        return Icons.bolt;
    }
  }

  String _titleOf(XBTrackEvent event) {
    switch (event.event) {
      case 'page_enter':
        return '进入「${event.pageName ?? '?'}」';
      case 'page_exit':
        final duration = event.params['durationMs'];
        final stay = duration is num ? ' · 停留 ${duration}ms' : '';
        return '离开「${event.pageName ?? '?'}」$stay';
      case 'auto_click':
        return '点击 ${event.params['text'] ?? ''}';
      default:
        return event.event;
    }
  }

  String _subtitleOf(XBTrackEvent event) {
    final time = DateTime.fromMillisecondsSinceEpoch(event.eventTimeMs);
    String two(int v) => v.toString().padLeft(2, '0');
    final timeText =
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
    final chain = event.params['typeChain'];
    final location = event.params['file'];
    final parts = <String>[timeText];
    if (chain != null) parts.add(chain.toString());
    if (location != null) {
      parts.add('$location:${event.params['line'] ?? ''}');
    }
    return parts.join('  ');
  }
}
