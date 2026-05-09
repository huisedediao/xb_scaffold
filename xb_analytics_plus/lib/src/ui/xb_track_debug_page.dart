import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/xb_track_event.dart';
import '../xb_track_api.dart';

class XBTrackDebugPage extends StatefulWidget {
  final int pageSize;
  final bool allowClear;
  final bool allowShare;

  const XBTrackDebugPage({
    super.key,
    this.pageSize = 100,
    this.allowClear = true,
    this.allowShare = true,
  }) : assert(pageSize > 0);

  @override
  State<XBTrackDebugPage> createState() => _XBTrackDebugPageState();
}

class _XBTrackDebugPageState extends State<XBTrackDebugPage> {
  final List<XBTrackEvent> _events = <XBTrackEvent>[];
  final TextEditingController _keywordController = TextEditingController();

  bool _loading = false;
  bool _hasMore = true;
  int _offset = 0;
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      if (reset) {
        _events.clear();
        _offset = 0;
        _hasMore = true;
      }
    });

    try {
      final newItems = await xbReadTrackLocalLatest(
        limit: widget.pageSize,
        offset: _offset,
      );
      setState(() {
        _events.addAll(newItems);
        _offset += newItems.length;
        _hasMore = newItems.length == widget.pageSize;
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  List<XBTrackEvent> get _filteredEvents {
    final key = _keyword.trim().toLowerCase();
    if (key.isEmpty) return _events;
    return _events.where((event) {
      if (event.event.toLowerCase().contains(key)) return true;
      final params = jsonEncode(event.params).toLowerCase();
      if (params.contains(key)) return true;
      final common = jsonEncode(event.commonParams).toLowerCase();
      return common.contains(key);
    }).toList();
  }

  Future<void> _copyExportJson() async {
    final content = await xbExportTrackAsJson();
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied JSON export to clipboard.')),
    );
  }

  Future<void> _shareExport() async {
    await xbShareTrackExport();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Share callback executed.')),
    );
  }

  Future<void> _clear() async {
    await xbClearTrackLocal();
    if (!mounted) return;
    await _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final list = _filteredEvents;
    return Scaffold(
      appBar: AppBar(
        title: const Text('XB Track Debug'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _load(reset: true),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Copy JSON',
            onPressed: _copyExportJson,
            icon: const Icon(Icons.copy),
          ),
          if (widget.allowShare)
            IconButton(
              tooltip: 'Share',
              onPressed: _shareExport,
              icon: const Icon(Icons.share),
            ),
          if (widget.allowClear)
            IconButton(
              tooltip: 'Clear',
              onPressed: _clear,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              controller: _keywordController,
              decoration: const InputDecoration(
                hintText: 'Search by event or params',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) {
                setState(() {
                  _keyword = value;
                });
              },
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('No events yet.'))
                : ListView.builder(
                    itemCount: list.length + 1,
                    itemBuilder: (context, index) {
                      if (index == list.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: _hasMore
                                ? OutlinedButton(
                                    onPressed: _loading
                                        ? null
                                        : () => _load(reset: false),
                                    child: Text(
                                        _loading ? 'Loading...' : 'Load More'),
                                  )
                                : const Text('No more data'),
                          ),
                        );
                      }

                      final event = list[index];
                      final time = DateTime.fromMillisecondsSinceEpoch(
                        event.eventTimeMs,
                      ).toIso8601String();

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  event.event,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text('time: $time'),
                                Text('eventId: ${event.eventId}'),
                                Text('page: ${event.pageName ?? '-'}'),
                                Text('user: ${event.userId ?? '-'}'),
                                const SizedBox(height: 6),
                                Text('params: ${jsonEncode(event.params)}'),
                                Text(
                                    'common: ${jsonEncode(event.commonParams)}'),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
