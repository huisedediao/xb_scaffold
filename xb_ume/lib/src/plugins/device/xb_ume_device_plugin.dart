import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/xb_ume_controller.dart';
import '../../core/xb_ume_plugin.dart';
import '../../utils/xb_ume_platform.dart';

class XBUmeDevicePlugin extends XBUmePlugin {
  @override
  String get id => 'device';

  @override
  String get title => 'Device';

  @override
  IconData get icon => Icons.devices;

  @override
  Widget buildPanel(BuildContext context, XBUmeController controller) {
    return const _DevicePanel();
  }
}

class _DevicePanel extends StatefulWidget {
  const _DevicePanel();

  @override
  State<_DevicePanel> createState() => _DevicePanelState();
}

class _DevicePanelState extends State<_DevicePanel> {
  int _tick = 0;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final view = View.of(context);
    final dispatcher = WidgetsBinding.instance.platformDispatcher;

    final rows = <MapEntry<String, String>>[
      MapEntry<String, String>('kIsWeb', kIsWeb.toString()),
      MapEntry<String, String>('OS', xbUmeOperatingSystem()),
      MapEntry<String, String>('Platform', defaultTargetPlatform.name),
      MapEntry<String, String>(
        'Physical Size',
        '${view.physicalSize.width.toStringAsFixed(0)} x ${view.physicalSize.height.toStringAsFixed(0)}',
      ),
      MapEntry<String, String>(
        'Device Pixel Ratio',
        view.devicePixelRatio.toStringAsFixed(2),
      ),
      MapEntry<String, String>(
        'Logical Size',
        '${media.size.width.toStringAsFixed(1)} x ${media.size.height.toStringAsFixed(1)}',
      ),
      MapEntry<String, String>(
        'Text Scale',
        media.textScaler.scale(1).toStringAsFixed(2),
      ),
      MapEntry<String, String>('Orientation', media.orientation.name),
      MapEntry<String, String>('Brightness', media.platformBrightness.name),
      MapEntry<String, String>('Locale', dispatcher.locale.toLanguageTag()),
      MapEntry<String, String>('Locales',
          dispatcher.locales.map((e) => e.toLanguageTag()).join(', ')),
      MapEntry<String, String>('View Insets', media.viewInsets.toString()),
      MapEntry<String, String>('View Padding', media.viewPadding.toString()),
      MapEntry<String, String>('Padding', media.padding.toString()),
      MapEntry<String, String>(
        'Always Use 24h',
        dispatcher.alwaysUse24HourFormat.toString(),
      ),
      MapEntry<String, String>(
        'Semantics Enabled',
        dispatcher.semanticsEnabled.toString(),
      ),
      MapEntry<String, String>('Accessibility Features',
          dispatcher.accessibilityFeatures.toString()),
      MapEntry<String, String>('Refresh Tick', '$_tick'),
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              const Text(
                'Device & Runtime Environment',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _tick += 1;
                  });
                },
                child: const Text('Refresh'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final row = rows[index];
              return ListTile(
                dense: true,
                title: Text(
                  row.key,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                ),
                subtitle: SelectableText(
                  row.value,
                  style: const TextStyle(fontSize: 12),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
