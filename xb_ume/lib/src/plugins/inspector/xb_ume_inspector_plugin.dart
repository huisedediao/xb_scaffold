import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/xb_ume_controller.dart';
import '../../core/xb_ume_notice_service.dart';
import '../../core/xb_ume_plugin.dart';
import '../../models/xb_ume_widget_node.dart';

class XBUmeInspectorPlugin extends XBUmePlugin {
  @override
  String get id => 'inspector';

  @override
  String get title => 'Inspector';

  @override
  IconData get icon => Icons.account_tree;

  @override
  Widget buildPanel(BuildContext context, XBUmeController controller) {
    return _InspectorPanel(controller: controller);
  }
}

class _InspectorPanel extends StatefulWidget {
  const _InspectorPanel({required this.controller});

  final XBUmeController controller;

  @override
  State<_InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<_InspectorPanel> {
  List<XBUmeWidgetNode> _nodes = <XBUmeWidgetNode>[];
  List<XBUmeWidgetNode> _filteredNodes = <XBUmeWidgetNode>[];
  String _keyword = '';
  bool _loading = false;
  String? _errorMessage;
  XBUmeWidgetNode? _selectedNode;
  List<String> _selectedContextLines = const <String>[];
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    if (widget.controller.config.inspectorAutoCaptureOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refresh();
      });
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Search widget type/key',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('Nodes: ${_filteredNodes.length}/${_nodes.length}'),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _loading ? null : _refresh,
                child: Text(_loading ? 'Loading...' : 'Refresh'),
              ),
            ],
          ),
        ),
        if (_errorMessage != null)
          Container(
            width: double.infinity,
            color: Colors.red.withValues(alpha: 0.08),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
        if (_selectedNode != null) _buildSelectedNodeCard(context),
        const Divider(height: 1),
        Expanded(
          child: _filteredNodes.isEmpty
              ? Center(
                  child: Text(
                    _nodes.isEmpty
                        ? 'No nodes yet. Tap Refresh to capture widget tree.'
                        : 'No matched nodes',
                  ),
                )
              : ListView.builder(
                  itemCount: _filteredNodes.length,
                  itemBuilder: (context, index) {
                    final node = _filteredNodes[index];
                    final isFiltering = _keyword.isNotEmpty;
                    final indent = isFiltering
                        ? 0.0
                        : (node.depth * 12).toDouble().clamp(0.0, 220.0);
                    return ListTile(
                      dense: true,
                      selected: identical(_selectedNode, node),
                      selectedTileColor: Colors.blue.withValues(alpha: 0.08),
                      onTap: () => _onSelectNode(node),
                      onLongPress: () => _showNodeDetailDialog(context, node),
                      title: Padding(
                        padding: EdgeInsets.only(left: indent),
                        child: Text(
                          node.widgetType,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      subtitle: Padding(
                        padding: EdgeInsets.only(left: indent),
                        child: Text(
                          'depth=${node.depth} | key=${node.key ?? '-'} | children=${node.childCount} | ${node.renderSummary ?? '-'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      await Future<void>.delayed(Duration.zero);
      final nodes = widget.controller.buildWidgetTreeSnapshot();
      if (!mounted) return;
      setState(() {
        _nodes = nodes;
        _applyFilter();
        _selectedNode = null;
        _selectedContextLines = const <String>[];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Inspector capture failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _onSearchChanged() {
    final next = _searchController.text.trim();
    if (next == _keyword) return;
    setState(() {
      _keyword = next;
      _applyFilter();
    });

    if (_nodes.isEmpty && !_loading) {
      _refresh();
    }
  }

  void _applyFilter() {
    if (_keyword.isEmpty) {
      _filteredNodes = List<XBUmeWidgetNode>.from(_nodes, growable: false);
      return;
    }

    final key = _keyword.toLowerCase();
    _filteredNodes = _nodes.where((node) {
      return node.widgetType.toLowerCase().contains(key) ||
          (node.key ?? '').toLowerCase().contains(key) ||
          (node.renderSummary ?? '').toLowerCase().contains(key);
    }).toList(growable: false);
  }

  void _onSelectNode(XBUmeWidgetNode node) {
    setState(() {
      _selectedNode = node;
      _selectedContextLines = _buildContextLines(node);
    });
  }

  Widget _buildSelectedNodeCard(BuildContext context) {
    final node = _selectedNode!;
    final contextText = _selectedContextLines.join('\n');
    final compactButtonStyle = TextButton.styleFrom(
      minimumSize: const Size(56, 30),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blueGrey.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Hierarchy Around ${node.widgetType}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 136,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    SizedBox(
                      width: 64,
                      child: TextButton(
                        style: compactButtonStyle,
                        onPressed: () async {
                          await Clipboard.setData(
                              ClipboardData(text: contextText));
                          if (!context.mounted) return;
                          XBUmeNoticeService.instance.show('Copied');
                        },
                        child: const Text('Copy'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 64,
                      child: TextButton(
                        style: compactButtonStyle,
                        onPressed: () {
                          setState(() {
                            _selectedNode = null;
                            _selectedContextLines = const <String>[];
                          });
                        },
                        child: const Text('Clear'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 170),
            child: SingleChildScrollView(
              child: SelectableText(
                contextText,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: Color(0xFF111827),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showNodeDetailDialog(BuildContext context, XBUmeWidgetNode node) {
    final text = _buildNodeDetailText(node);
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Inspector Node Detail'),
          content: SizedBox(
            width: 760,
            child: Scrollbar(
              thumbVisibility: true,
              child: SingleChildScrollView(
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
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!dialogContext.mounted) return;
                XBUmeNoticeService.instance.show('Copied');
              },
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  String _buildAncestorPath(XBUmeWidgetNode node) {
    final index = _nodes.indexWhere((n) => identical(n, node));
    if (index <= 0) return node.widgetType;

    final segments = <String>[node.widgetType];
    int expectDepth = node.depth - 1;

    for (int i = index - 1; i >= 0 && expectDepth >= 0; i--) {
      final current = _nodes[i];
      if (current.depth == expectDepth) {
        segments.insert(0, current.widgetType);
        expectDepth -= 1;
      }
    }

    return segments.join(' > ');
  }

  String _buildNodeDetailText(XBUmeWidgetNode node) {
    final path = _buildAncestorPath(node);
    return <String>[
      'widgetType: ${node.widgetType}',
      'depth: ${node.depth}',
      'key: ${node.key ?? '-'}',
      'childCount: ${node.childCount}',
      'renderSummary: ${node.renderSummary ?? '-'}',
      '',
      'ancestorPath:',
      path,
    ].join('\n');
  }

  List<String> _buildContextLines(XBUmeWidgetNode node) {
    final index = _nodes.indexWhere((item) => identical(item, node));
    if (index < 0) {
      return <String>['No hierarchy info. Tap Refresh and select again.'];
    }

    final selectedDepth = node.depth;

    final upper = <XBUmeWidgetNode>[];
    int expectDepth = selectedDepth - 1;
    for (int i = index - 1;
        i >= 0 && expectDepth >= 0 && upper.length < 5;
        i--) {
      final current = _nodes[i];
      if (current.depth == expectDepth) {
        upper.add(current);
        expectDepth -= 1;
      }
    }

    final down = <XBUmeWidgetNode>[];
    for (int i = index + 1; i < _nodes.length; i++) {
      final current = _nodes[i];
      if (current.depth <= selectedDepth) {
        break;
      }
      final delta = current.depth - selectedDepth;
      if (delta <= 5) {
        down.add(current);
      }
      if (down.length >= 120) {
        break;
      }
    }

    final lines = <String>[
      'Tap: show +/-5 levels | Long press: detail popup',
      '',
    ];

    final orderedUpper = upper.reversed.toList(growable: false);
    if (orderedUpper.isEmpty) {
      lines.add('↑ (no parent within 5 levels)');
    } else {
      for (final item in orderedUpper) {
        final delta = item.depth - selectedDepth;
        lines.add('↑ ${delta.toString().padLeft(2)}  ${_nodeBrief(item)}');
      }
    }

    lines.add('●  0  ${_nodeBrief(node)}');

    if (down.isEmpty) {
      lines.add('↓ (no child within 5 levels)');
    } else {
      for (final item in down) {
        final delta = item.depth - selectedDepth;
        final visualIndent = delta > 1 ? '  ' * (delta - 1) : '';
        lines.add('↓ +$delta  $visualIndent${_nodeBrief(item)}');
      }
      if (down.length >= 120) {
        lines.add('... (truncated: too many descendants)');
      }
    }

    return lines;
  }

  String _nodeBrief(XBUmeWidgetNode node) {
    return '${node.widgetType} [key=${node.key ?? '-'}, children=${node.childCount}]';
  }
}
