import 'package:flutter/material.dart';

import '../core/xb_ume_controller.dart';
import '../core/xb_ume_widget_pick_service.dart';

class XBUmePanel extends StatefulWidget {
  const XBUmePanel({
    super.key,
    required this.controller,
    required this.onClose,
  });

  final XBUmeController controller;
  final VoidCallback onClose;

  @override
  State<XBUmePanel> createState() => _XbUmePanelState();
}

class _XbUmePanelState extends State<XBUmePanel> {
  int _tabIndex = 0;
  final Map<String, Widget> _cachedPanels = <String, Widget>{};

  @override
  Widget build(BuildContext context) {
    final plugins = widget.controller.plugins;
    if (plugins.isEmpty) {
      return _buildFrame(
        context,
        header: const Text(
          'xb_ume',
          style: TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
        ),
        body: const Center(
          child: Text(
            'No plugins registered',
            style: TextStyle(fontSize: 13),
          ),
        ),
      );
    }

    if (_tabIndex >= plugins.length) {
      _tabIndex = plugins.length - 1;
    }

    final selected = plugins[_tabIndex];
    final panel = _cachedPanels.putIfAbsent(
      selected.id,
      () => selected.buildPanel(context, widget.controller),
    );

    return _buildFrame(
      context,
      header: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (int i = 0; i < plugins.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _tabIndex = i;
                    });
                    if (plugins[i].id == 'widget_locator') {
                      XBUmeWidgetPickService.instance.start();
                    }
                  },
                  borderRadius: BorderRadius.circular(999),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: _tabIndex == i
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.20),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          plugins[i].icon,
                          size: 14,
                          color: _tabIndex == i ? Colors.black87 : Colors.white,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          plugins[i].title,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _tabIndex == i ? Colors.black87 : Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      body: Container(color: Colors.white, child: panel),
    );
  }

  Widget _buildFrame(
    BuildContext context, {
    required Widget header,
    required Widget body,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: Colors.white,
          child: Column(
            children: [
              Container(
                height: 46,
                padding: const EdgeInsets.only(left: 12, right: 8),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xFF1F2A44), Color(0xFF0A84FF)],
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(child: header),
                    IconButton(
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),
              Expanded(child: body),
            ],
          ),
        ),
      ),
    );
  }
}
