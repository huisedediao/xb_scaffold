import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/xb_ume_controller.dart';
import '../../core/xb_ume_ide_jump.dart';
import '../../core/xb_ume_notice_service.dart';
import '../../core/xb_ume_plugin.dart';
import '../../models/xb_ume_network_item.dart';
import '../../ui/xb_ume_detail_scroll_content.dart';
import '../../utils/xb_ume_pretty.dart';
import '../../utils/xb_ume_time.dart';

class XBUmeNetworkPlugin extends XBUmePlugin {
  @override
  String get id => 'network';

  @override
  String get title => 'Network';

  @override
  IconData get icon => Icons.network_check;

  @override
  Widget buildPanel(BuildContext context, XBUmeController controller) {
    return _NetworkPanel(controller: controller);
  }
}

class _NetworkPanel extends StatefulWidget {
  const _NetworkPanel({required this.controller});

  final XBUmeController controller;

  @override
  State<_NetworkPanel> createState() => _NetworkPanelState();
}

class _NetworkPanelState extends State<_NetworkPanel> {
  String _keyword = '';
  XBUmeNetworkStatus? _status;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.controller.changeTick,
      builder: (context, _, __) {
        final source =
            widget.controller.network.reversed.toList(growable: false);
        final list = source.where((item) {
          if (_status != null && item.status != _status) return false;
          if (_keyword.isEmpty) return true;
          final key = _keyword.toLowerCase();
          return item.url.toLowerCase().contains(key) ||
              item.method.toLowerCase().contains(key) ||
              (item.statusCode?.toString() ?? '').contains(key);
        }).toList(growable: false);

        return Column(
          children: [
            _buildToolbar(context, list),
            const Divider(height: 1),
            Expanded(
              child: list.isEmpty
                  ? const Center(child: Text('No network records'))
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, index) {
                        final item = list[index];
                        final statusText = _statusText(item);
                        return ListTile(
                          dense: true,
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
                            '${item.method.toUpperCase()} ${item.url}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '$statusText  ${item.durationMs ?? '-'}ms',
                            style: TextStyle(
                              fontSize: 12,
                              color: _statusColor(item.status),
                            ),
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

  Widget _buildToolbar(
      BuildContext context, List<XBUmeNetworkItem> filteredItems) {
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
                selected: _status == null,
                onSelected: (_) {
                  setState(() {
                    _status = null;
                  });
                },
              ),
              ...XBUmeNetworkStatus.values.map(
                (status) => ChoiceChip(
                  label: Text(status.name.toUpperCase()),
                  selected: _status == status,
                  onSelected: (_) {
                    setState(() {
                      _status = status;
                    });
                  },
                  avatar: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _statusColor(status),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              Text(
                'Count: ${filteredItems.length}',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              OutlinedButton(
                onPressed: () async {
                  final map = filteredItems
                      .map((e) => e.toJson())
                      .toList(growable: false);
                  final text = const JsonEncoder.withIndent('  ').convert(map);
                  await Clipboard.setData(ClipboardData(text: text));
                  if (!context.mounted) return;
                  XBUmeNoticeService.instance.show('Network records copied');
                },
                child: const Text('Copy JSON'),
              ),
              OutlinedButton(
                onPressed: widget.controller.clearNetwork,
                child: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Search URL/method/status',
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

  Color _statusColor(XBUmeNetworkStatus status) {
    switch (status) {
      case XBUmeNetworkStatus.pending:
        return Colors.blueGrey;
      case XBUmeNetworkStatus.success:
        return Colors.green.shade700;
      case XBUmeNetworkStatus.failure:
        return Colors.red.shade700;
      case XBUmeNetworkStatus.cancelled:
        return Colors.orange.shade800;
    }
  }

  String _statusText(XBUmeNetworkItem item) {
    final code = item.statusCode;
    if (code == null) return item.status.name.toUpperCase();
    return '${item.status.name.toUpperCase()}($code)';
  }

  void _showDetail(BuildContext context, XBUmeNetworkItem item) {
    final initiator = _firstInitiator(item);
    final initiatorStack = item.initiatorStack?.trim();
    final text = <String>[
      'id: ${item.id}',
      'time: ${item.time.toIso8601String()}',
      'method: ${item.method}',
      'url: ${item.url}',
      'status: ${item.status.name}',
      'statusCode: ${item.statusCode ?? '-'}',
      'durationMs: ${item.durationMs ?? '-'}',
      if (item.progress != null)
        'progress: ${(item.progress! * 100).toStringAsFixed(1)}%',
      if (item.error != null) 'error: ${item.error}',
      '',
      'request headers:',
      xbUmePreview(item.requestHeaders),
      '',
      'request body:',
      xbUmePreview(item.requestBody),
      '',
      'response headers:',
      xbUmePreview(item.responseHeaders),
      '',
      'response body:',
      xbUmePreview(item.responseBody),
      if (item.stack != null) ...[
        '',
        'stack:',
        xbUmePreview(item.stack),
      ],
      '',
      '发起位置:',
      if (initiatorStack != null && initiatorStack.isNotEmpty)
        initiatorStack
      else if (item.initiator != null && item.initiator!.isNotEmpty)
        item.initiator!
      else
        '未记录（该记录可能来自 0.3.0 之前的版本，或未捕获到用户代码帧）',
    ].join('\n');

    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Network Detail'),
          content: SizedBox(
            width: 760,
            child: XBUmeDetailScrollContent(
              child: SelectableText(
                text,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: Color(0xFF111827),
                ),
              ),
            ),
          ),
          actions: [
            if (initiator != null)
              TextButton.icon(
                onPressed: () async {
                  final sent = await XBUmeIdeJump.requestOpen(
                    file: initiator.file,
                    line: initiator.line,
                    column: initiator.column,
                  );
                  if (!context.mounted) return;
                  XBUmeNoticeService.instance.show(
                    sent ? '已发送 IDE 打开请求，路径已复制' : '路径已复制到剪贴板',
                  );
                },
                icon: const Icon(Icons.north_east, size: 16),
                label: const Text('跳转发起位置'),
              ),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
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

/// 发起位置栈帧解析结果，如 `#2 Foo.bar (package:app/main.dart:153:35)`。
class _InitiatorLocation {
  const _InitiatorLocation({
    required this.file,
    required this.line,
    required this.column,
  });

  final String file;
  final int line;
  final int? column;
}

final RegExp _initiatorFrameRe = RegExp(r'^#\d+\s+.*\((.+):(\d+):(\d+)\)$');

/// 取首个可解析的发起位置栈帧；app 端已过滤基础设施帧，首帧即调用点。
_InitiatorLocation? _firstInitiator(XBUmeNetworkItem item) {
  final stack = item.initiatorStack;
  final frames = stack == null || stack.isEmpty
      ? <String>[if (item.initiator != null) item.initiator!]
      : stack.split('\n');
  for (final frame in frames) {
    final match = _initiatorFrameRe.firstMatch(frame.trim());
    if (match == null) continue;
    final line = int.tryParse(match.group(2)!);
    if (line == null) continue;
    return _InitiatorLocation(
      file: match.group(1)!,
      line: line,
      column: int.tryParse(match.group(3)!),
    );
  }
  return null;
}
