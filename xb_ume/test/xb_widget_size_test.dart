import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/core/xb_ume_widget_locator_resolver.dart';
import 'package:xb_ume/src/core/xb_ume_widget_pick_service.dart';
import 'package:xb_ume/xb_ume.dart';

const Key _kTarget = Key('size_target');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 回归：选中组件后，气泡需展示组件真实宽高（size 行）。
  // 宽高取自未 clamp 的高亮 rect，组件超出屏幕时仍应显示真实值。
  testWidgets('选中组件后气泡展示 size 行与真实宽高', (tester) async {
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
            child: Container(
              key: _kTarget,
              width: 120,
              height: 50,
              color: Colors.green,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final element = tester.element(find.byKey(_kTarget));
    final result = const XBUmeWidgetLocatorResolver(
      inspectablePackages: <String>{'xb_ume'},
    ).resolve(element);
    final rect = (result.pickedRect ?? result.resolvedRect)!;

    // 进入拾取模式后发布选中（拾取覆盖层仅在此模式下渲染）。
    XBUmeWidgetPickService.instance.start();
    await tester.pump();
    XBUmeWidgetPickService.instance.publishSelection(result);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.textContaining(
        'size: ${rect.width.toStringAsFixed(1)} '
        '× ${rect.height.toStringAsFixed(1)}',
      ),
      findsOneWidget,
    );

    // 展开态：size 行仍需展示（仅框上标签收起）。
    await tester.tap(find.textContaining('Expand full chain'));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      find.textContaining(
        'size: ${rect.width.toStringAsFixed(1)} '
        '× ${rect.height.toStringAsFixed(1)}',
      ),
      findsOneWidget,
    );

    XBUmeWidgetPickService.instance.clearSelection();
    XBUmeWidgetPickService.instance.stop();
    await tester.pump();
    binding.dispose();
  });
}
