import 'package:flutter/material.dart';

import '../../core/xb_ume_controller.dart';
import '../../core/xb_ume_plugin.dart';
import '../../core/xb_ume_storage_adapter.dart';
import '../../utils/xb_ume_pretty.dart';

class XBUmeStoragePlugin extends XBUmePlugin {
  @override
  String get id => 'storage';

  @override
  String get title => 'Storage';

  @override
  IconData get icon => Icons.storage;

  @override
  Widget buildPanel(BuildContext context, XBUmeController controller) {
    return _StoragePanel(controller: controller);
  }
}

class _StoragePanel extends StatefulWidget {
  const _StoragePanel({required this.controller});

  final XBUmeController controller;

  @override
  State<_StoragePanel> createState() => _StoragePanelState();
}

class _StoragePanelState extends State<_StoragePanel> {
  String? _adapterId;
  String _keyword = '';
  Map<String, dynamic> _entries = <String, dynamic>{};
  List<MapEntry<String, dynamic>> _filteredEntries =
      <MapEntry<String, dynamic>>[];
  String _adapterSignature = '';

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _valueController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _adapterSignature = _buildAdapterSignature();
    widget.controller.changeTick.addListener(_onControllerTick);
    _searchController.addListener(_onSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureAdapterAndLoad();
    });
  }

  @override
  void dispose() {
    widget.controller.changeTick.removeListener(_onControllerTick);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _keyController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final adapters = widget.controller.storageAdapters;
    if (_adapterId == null && adapters.isNotEmpty) {
      _adapterId = adapters.first.id;
      _loadEntries();
    }

    final adapter = _adapterId == null
        ? null
        : widget.controller.findStorageAdapter(_adapterId!);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Storage Adapter:',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  ...adapters.map(
                    (e) => ChoiceChip(
                      label: Text(e.id),
                      selected: _adapterId == e.id,
                      onSelected: (_) {
                        setState(() {
                          _adapterId = e.id;
                        });
                        _loadEntries();
                      },
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _loadEntries,
                    child: const Text('Refresh'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Search key/value',
                  border: OutlineInputBorder(),
                ),
              ),
              if (adapter != null && adapter.writable) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _keyController,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Key',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _valueController,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'Value (string)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => _setValue(adapter),
                      child: const Text('Set'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: adapters.isEmpty
              ? const Center(
                  child: Text(
                    'No storage adapters.\nRegister adapters with XBUme.registerStorageAdapter(...)',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: _filteredEntries.length,
                  itemBuilder: (context, index) {
                    final entry = _filteredEntries[index];
                    return ListTile(
                      dense: true,
                      title: Text(
                        entry.key,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: SelectableText(
                        xbUmePreview(entry.value),
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: (adapter?.writable ?? false)
                          ? IconButton(
                              onPressed: () =>
                                  _removeValue(adapter!, entry.key),
                              icon: const Icon(Icons.delete_outline),
                            )
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _ensureAdapterAndLoad() async {
    final adapters = widget.controller.storageAdapters;
    if (adapters.isNotEmpty && _adapterId == null) {
      _adapterId = adapters.first.id;
    }
    await _loadEntries();
  }

  Future<void> _loadEntries() async {
    final adapterId = _adapterId;
    if (adapterId == null) {
      setState(() {
        _entries = <String, dynamic>{};
      });
      return;
    }

    final adapter = widget.controller.findStorageAdapter(adapterId);
    if (adapter == null) {
      setState(() {
        _entries = <String, dynamic>{};
      });
      return;
    }

    final entries = await adapter.dump();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _applyFilter();
    });
  }

  Future<void> _setValue(XBUmeStorageAdapter adapter) async {
    final key = _keyController.text.trim();
    final value = _valueController.text;
    if (key.isEmpty) return;
    await adapter.setValue(key, value);
    await _loadEntries();
  }

  Future<void> _removeValue(XBUmeStorageAdapter adapter, String key) async {
    await adapter.removeValue(key);
    await _loadEntries();
  }

  void _onSearchChanged() {
    final next = _searchController.text.trim();
    if (next == _keyword) return;
    setState(() {
      _keyword = next;
      _applyFilter();
    });
  }

  void _applyFilter() {
    if (_keyword.isEmpty) {
      _filteredEntries = _entries.entries.toList(growable: false);
      return;
    }

    final key = _keyword.toLowerCase();
    _filteredEntries = _entries.entries.where((entry) {
      return entry.key.toLowerCase().contains(key) ||
          entry.value.toString().toLowerCase().contains(key);
    }).toList(growable: false);
  }

  void _onControllerTick() {
    final nextSignature = _buildAdapterSignature();
    if (nextSignature == _adapterSignature) return;
    _adapterSignature = nextSignature;

    final adapters = widget.controller.storageAdapters;
    if (adapters.isEmpty) {
      if (mounted) {
        setState(() {
          _adapterId = null;
          _entries = <String, dynamic>{};
          _applyFilter();
        });
      }
      return;
    }

    if (_adapterId == null ||
        !adapters.any((adapter) => adapter.id == _adapterId)) {
      setState(() {
        _adapterId = adapters.first.id;
      });
      _loadEntries();
      return;
    }

    if (mounted) {
      setState(() {});
    }
  }

  String _buildAdapterSignature() {
    final ids = widget.controller.storageAdapters.map((e) => e.id).toList()
      ..sort();
    return ids.join('|');
  }
}
