import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/xb_ume_controller.dart';
import '../../core/xb_ume_notice_service.dart';
import '../../core/xb_ume_plugin.dart';
import '../../core/xb_ume_widget_locator_resolver.dart';
import '../../core/xb_ume_widget_pick_service.dart';

class XBUmeWidgetLocatorPlugin extends XBUmePlugin {
  @override
  String get id => 'widget_locator';

  @override
  String get title => 'Locator';

  @override
  IconData get icon => Icons.my_location;

  @override
  Widget buildPanel(BuildContext context, XBUmeController controller) {
    return const _WidgetLocatorPanel();
  }
}

class _WidgetLocatorPanel extends StatefulWidget {
  const _WidgetLocatorPanel();

  @override
  State<_WidgetLocatorPanel> createState() => _WidgetLocatorPanelState();
}

class _WidgetLocatorPanelState extends State<_WidgetLocatorPanel> {
  final WidgetInspectorService _service = WidgetInspectorService.instance;
  final XBUmeWidgetPickService _pickService = XBUmeWidgetPickService.instance;

  bool _trackingEnabled = false;
  bool _pickMode = false;

  XBUmeWidgetLocatorResult? _result;

  @override
  void initState() {
    super.initState();
    _trackingEnabled = _service.isWidgetCreationTracked();
    _pickMode = _pickService.picking.value;

    _pickService.picking.addListener(_onPickModeChanged);
    _pickService.selectedResult.addListener(_onPickResultChanged);

    if (_pickService.selectedResult.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _onPickResultChanged();
      });
    }
  }

  @override
  void dispose() {
    _pickService.picking.removeListener(_onPickModeChanged);
    _pickService.selectedResult.removeListener(_onPickResultChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _stateChip(
                    'track-widget-creation',
                    _trackingEnabled,
                    activeText: 'ON',
                    inactiveText: 'OFF',
                  ),
                  _stateChip(
                    'pick mode',
                    _pickMode,
                    activeText: 'ACTIVE',
                    inactiveText: 'IDLE',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _trackingEnabled ? _startPick : null,
                    icon: const Icon(Icons.ads_click),
                    label: const Text('Start Pick'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _pickMode ? _stopPick : null,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Stop Pick'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _clear,
                    icon: const Icon(Icons.clear_all),
                    label: const Text('Clear Result'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _trackingEnabled
                    ? 'Tap Start Pick, then tap any widget. Locator will keep picking until you tap UME button again.'
                    : 'Widget creation tracking is OFF. Run in debug mode with track-widget-creation enabled.',
                style: TextStyle(
                  fontSize: 12,
                  color:
                      _trackingEnabled ? Colors.black87 : Colors.red.shade700,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _result == null ? _buildEmpty() : _buildResult(context),
        ),
      ],
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Text(
        'No widget selected yet.',
        style: TextStyle(fontSize: 12),
      ),
    );
  }

  Widget _buildResult(BuildContext context) {
    final result = _result!;
    final details = <String>[
      'pickedWidget: ${result.pickedWidgetType}',
      'resolvedWidget: ${result.resolvedWidgetType}',
      'resolveStrategy: ${result.resolveStrategy}',
      'file: ${result.file ?? '-'}',
      'line: ${result.line ?? '-'}',
      'column: ${result.column ?? '-'}',
      '',
      'parentWidget: ${result.parentWidgetType ?? '-'}',
      'parentResolveStrategy: ${result.parentResolveStrategy ?? '-'}',
      'parentFile: ${result.parentFile ?? '-'}',
      'parentLine: ${result.parentLine ?? '-'}',
      'parentColumn: ${result.parentColumn ?? '-'}',
      '',
      'ancestorPath:',
      result.ancestorPath,
      '',
      'creationLocationRaw:',
      result.rawCreationLocation ?? '-',
    ].join('\n');

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            const Text(
              'Selected Widget',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: details));
                if (!context.mounted) return;
                XBUmeNoticeService.instance.show('Copied');
              },
              child: const Text('Copy'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SelectableText(
          details,
          style: const TextStyle(
            fontSize: 12,
            height: 1.4,
            color: Color(0xFF111827),
          ),
        ),
      ],
    );
  }

  Widget _stateChip(
    String label,
    bool active, {
    required String activeText,
    required String inactiveText,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: active
            ? Colors.green.withValues(alpha: 0.12)
            : Colors.blueGrey.withValues(alpha: 0.10),
        border: Border.all(
          color: active
              ? Colors.green.withValues(alpha: 0.42)
              : Colors.blueGrey.withValues(alpha: 0.25),
        ),
      ),
      child: Text(
        '$label: ${active ? activeText : inactiveText}',
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }

  void _startPick() {
    _pickService.start();
  }

  void _stopPick() {
    _pickService.stop();
  }

  void _clear() {
    _pickService.clearSelection();
    _setStateSafely(() {
      _result = null;
    });
  }

  void _onPickModeChanged() {
    _setStateSafely(() {
      _trackingEnabled = _service.isWidgetCreationTracked();
      _pickMode = _pickService.picking.value;
    });
  }

  void _onPickResultChanged() {
    _setStateSafely(() {
      _result = _pickService.selectedResult.value;
    });
  }

  void _setStateSafely(VoidCallback fn) {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    final canSetStateNow = phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks;
    if (canSetStateNow) {
      setState(fn);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(fn);
    });
  }
}
