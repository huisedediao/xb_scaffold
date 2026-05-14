import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/xb_ume_controller.dart';
import '../../core/xb_ume_notice_service.dart';
import '../../core/xb_ume_plugin.dart';
import '../../models/xb_ume_log_item.dart';
import '../../utils/xb_ume_time.dart';

class XBUmeConsolePlugin extends XBUmePlugin {
  @override
  String get id => 'console';

  @override
  String get title => 'Console';

  @override
  IconData get icon => Icons.subject;

  @override
  Widget buildPanel(BuildContext context, XBUmeController controller) {
    return _ConsolePanel(controller: controller);
  }
}

class _ConsolePanel extends StatefulWidget {
  const _ConsolePanel({required this.controller});

  final XBUmeController controller;

  @override
  State<_ConsolePanel> createState() => _ConsolePanelState();
}

class _ConsolePanelState extends State<_ConsolePanel> {
  String _keyword = '';
  XBUmeLogLevel? _level;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.controller.changeTick,
      builder: (context, _, __) {
        final source = widget.controller.logs.reversed.toList(growable: false);
        final logs = source.where((item) {
          if (_level != null && item.level != _level) return false;
          if (_keyword.isEmpty) return true;
          final key = _keyword.toLowerCase();
          return item.message.toLowerCase().contains(key) ||
              item.tag.toLowerCase().contains(key);
        }).toList(growable: false);

        return Column(
          children: [
            _buildToolbar(context, logs),
            const Divider(height: 1),
            Expanded(
              child: logs.isEmpty
                  ? const Center(child: Text('No logs'))
                  : ListView.builder(
                      itemCount: logs.length,
                      itemBuilder: (context, index) {
                        final item = logs[index];
                        return ListTile(
                          dense: true,
                          visualDensity: const VisualDensity(vertical: -3),
                          onTap: () => _showDetail(context, item),
                          leading: SizedBox(
                            width: 84,
                            child: Text(
                              xbUmeFormatTime(item.time),
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.black54,
                              ),
                            ),
                          ),
                          title: Text(
                            '[${item.level.name.toUpperCase()}] ${item.tag}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _colorForLevel(item.level),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            item.message,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildToolbar(BuildContext context, List<XBUmeLogItem> filteredLogs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ChoiceChip(
                label: const Text('ALL'),
                selected: _level == null,
                onSelected: (_) {
                  setState(() {
                    _level = null;
                  });
                },
              ),
              ...XBUmeLogLevel.values.map(
                (level) => ChoiceChip(
                  label: Text(level.name.toUpperCase()),
                  selected: _level == level,
                  onSelected: (_) {
                    setState(() {
                      _level = level;
                    });
                  },
                  avatar: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _colorForLevel(level),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              Text(
                'Count: ${filteredLogs.length}',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              OutlinedButton(
                onPressed: () async {
                  final data = const JsonEncoder.withIndent('  ').convert(
                    filteredLogs.map((e) => e.toJson()).toList(growable: false),
                  );
                  await Clipboard.setData(ClipboardData(text: data));
                  if (!context.mounted) return;
                  XBUmeNoticeService.instance
                      .show('Exported snapshot to clipboard');
                },
                child: const Text('Export'),
              ),
              OutlinedButton(
                onPressed: () => widget.controller.clearLogs(),
                child: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Search',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              setState(() {
                _keyword = value.trim();
              });
            },
          ),
        ],
      ),
    );
  }

  Color _colorForLevel(XBUmeLogLevel level) {
    switch (level) {
      case XBUmeLogLevel.debug:
        return Colors.blueGrey;
      case XBUmeLogLevel.info:
        return Colors.blue;
      case XBUmeLogLevel.warn:
        return Colors.orange.shade800;
      case XBUmeLogLevel.error:
        return Colors.red.shade700;
      case XBUmeLogLevel.fatal:
        return Colors.red.shade900;
    }
  }

  void _showDetail(BuildContext context, XBUmeLogItem item) {
    final lines = <String>[
      'time: ${item.time.toIso8601String()}',
      'level: ${item.level.name}',
      'tag: ${item.tag}',
      '',
      item.message,
      if (item.stack != null) ...[
        '',
        'stack:',
        item.stack!,
      ],
    ];

    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Log Detail'),
          content: SizedBox(
            width: 720,
            child: Scrollbar(
              thumbVisibility: true,
              child: SingleChildScrollView(
                child: SelectableText(
                  lines.join('\n'),
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: Color(0xFF111827),
                  ),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: lines.join('\n')));
                if (!context.mounted) return;
                XBUmeNoticeService.instance.show('Copied');
              },
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}
