import 'package:flutter/material.dart';

import '../../core/xb_ume_controller.dart';
import '../../core/xb_ume_plugin.dart';
import '../../utils/xb_ume_time.dart';

class XBUmeRoutePlugin extends XBUmePlugin {
  @override
  String get id => 'route';

  @override
  String get title => 'Route';

  @override
  IconData get icon => Icons.alt_route;

  @override
  Widget buildPanel(BuildContext context, XBUmeController controller) {
    return _RoutePanel(controller: controller);
  }
}

class _RoutePanel extends StatefulWidget {
  const _RoutePanel({required this.controller});

  final XBUmeController controller;

  @override
  State<_RoutePanel> createState() => _RoutePanelState();
}

class _RoutePanelState extends State<_RoutePanel> {
  String _keyword = '';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.controller.changeTick,
      builder: (context, _, __) {
        final records = widget.controller.routes.reversed.where((item) {
          if (_keyword.isEmpty) return true;
          final key = _keyword.toLowerCase();
          return item.routeName.toLowerCase().contains(key) ||
              (item.previousRouteName ?? '').toLowerCase().contains(key);
        }).toList(growable: false);

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Search route',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) {
                        setState(() {
                          _keyword = value.trim();
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('Count: ${records.length}'),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => widget.controller.clearRoutes(),
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: records.isEmpty
                  ? const Center(child: Text('No route records'))
                  : ListView.builder(
                      itemCount: records.length,
                      itemBuilder: (context, index) {
                        final item = records[index];
                        return ListTile(
                          dense: true,
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
                            '[${item.action.name.toUpperCase()}] ${item.routeName}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            'previous: ${item.previousRouteName ?? '-'}',
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
}
