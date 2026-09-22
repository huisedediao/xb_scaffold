import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/core/xb_ume_widget_locator_resolver.dart';
import 'package:xb_ume/src/core/xb_ume_widget_pick_service.dart';
import 'package:xb_ume/xb_ume.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 回归：选中组件后，选中框、信息气泡、间距标注需同时正常渲染。
  // 曾因气泡头部行在无界 Row 内使用 Expanded 导致整帧布局异常，
  // 气泡与间距标注全部消失（仅剩选中框）。
  testWidgets('选中组件后气泡/间距/链条渲染无布局异常', (tester) async {
    final binding = XBUmeBinding.ensureInitialized(
      config: const XBUmeConfig(
        enable: true,
        persistenceEnabled: false,
        enableConsole: false,
        enableRoute: false,
        enablePerformance: false,
        enableNetwork: false,
        enableInspector: false,
        enableWidgetLocator: true,
        enableDevice: false,
        enableStorage: false,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: XBUme.appBuilder(),
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {},
              child: const Text('target'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final element = tester.element(find.text('target'));
    final result = const XBUmeWidgetLocatorResolver(
      inspectablePackages: <String>{'xb_ume'},
    ).resolve(element);
    // 进入拾取模式后发布选中（拾取覆盖层仅在此模式下渲染）。
    XBUmeWidgetPickService.instance.start();
    await tester.pump();
    XBUmeWidgetPickService.instance.publishSelection(result);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('picked:'), findsOneWidget);

    // 展开链条：展开态气泡内含更多 _jumpableRow，同样不能有布局异常。
    await tester.tap(find.textContaining('Expand full chain'));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('点击行尾箭头'), findsOneWidget);

    XBUmeWidgetPickService.instance.clearSelection();
    XBUmeWidgetPickService.instance.stop();
    await tester.pump();
    binding.dispose();
  });
}
