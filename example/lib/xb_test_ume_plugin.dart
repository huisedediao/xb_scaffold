import 'package:example/pages/xb_common_test_page.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:xb_simple_router/xb_simple_router.dart';
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
          return ListView.builder(
            itemCount: titles.length,
            itemBuilder: (context, index) {
              return XBCellTitle(
                contentHeight: 50,
                title: titles[index],
                onTap: () {
                  controller.hidePanel();
                  push(const XBCommonTestPage(), 1);
                },
              );
            },
          );
        },
      ),
    );
  }

  List<String> get titles => ["点击测试"];
}
