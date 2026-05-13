import 'package:flutter/material.dart';
import 'package:xb_ume/xb_ume.dart';

class XBTestUmePlugin extends XBUmePlugin {
  @override
  String get id => 'xb_test';

  @override
  String get title => 'XB Test';

  @override
  IconData get icon => Icons.extension;

  @override
  Widget buildPanel(BuildContext context, XBUmeController controller) {
    return _XbTestPanel(controller: controller);
  }
}

class _XbTestPanel extends StatelessWidget {
  const _XbTestPanel({required this.controller});

  final XBUmeController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: ValueListenableBuilder<int>(
        valueListenable: controller.changeTick,
        builder: (context, _, __) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '这是 example 里自定义的 XB Test 面板',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text('logs: ${controller.logs.length}'),
              Text('routes: ${controller.routes.length}'),
              Text('network: ${controller.network.length}'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(
                    onPressed: () {
                      XBUme.log(
                        'Hello from XB Test plugin',
                        tag: 'xb_test',
                        level: XBUmeLogLevel.info,
                      );
                    },
                    child: const Text('写入一条日志'),
                  ),
                  OutlinedButton(
                    onPressed: controller.clearLogs,
                    child: const Text('清空 Console'),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
