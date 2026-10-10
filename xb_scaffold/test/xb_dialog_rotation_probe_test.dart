import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void _noopOnSelected(int index) {}
void _noopOnDone(String value) {}

List<XBThemeConfig> _themes() => [
      XBThemeConfig(primaryColor: Colors.blue, imgPrefix: 'assets/t1/'),
    ];

Future<void> _pumpHarness(WidgetTester tester, VoidCallback onTap) async {
  await tester.pumpWidget(XBMaterialApp(
    home: XBScaffold(
      themeConfigs: _themes(),
      child: Center(
        child: TextButton(onPressed: onTap, child: const Text('show')),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 白色卡片（dialog 卡片容器）
Size _cardSize(WidgetTester tester) {
  final list = tester.widgetList<Container>(find.byWidgetPredicate(
    (w) => w is Container && w.color == Colors.white,
  ));
  expect(list, isNotEmpty, reason: '找不到 dialog 白色卡片');
  final first = list.first;
  final rect = tester.getRect(find.byWidget(first));
  return rect.size;
}

/// 找到指定固定宽度的 SizedBox
bool _hasSizedBoxWidth(WidgetTester tester, double width) {
  return tester.widgetList<SizedBox>(find.byWidgetPredicate(
    (w) => w is SizedBox && w.width == width,
  )).isNotEmpty;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 默认测试面 800x600（横屏逻辑尺寸），切到 400x800 模拟竖屏
  const landscape = Size(800, 600);
  const portrait = Size(400, 800);

  void _setView(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(XBThemeVM().resetForTest);
  }

  Future<void> _rotate(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    await tester.pump();
    await tester.pump();
  }

  testWidgets('dialog + maxWidth: 横屏弹出 -> 切竖屏后宽度是否变化',
      (WidgetTester tester) async {
    _setView(tester, landscape);
    await _pumpHarness(tester, () {
      dialog(
        title: '提示',
        msg: '确定删除吗？',
        btnTitles: const ['取消', '确定'],
        onSelected: _noopOnSelected,
        maxWidth: 300,
      );
    });
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    expect(_hasSizedBoxWidth(tester, 300), isTrue);
    expect(screenW, 800);
    final before = _cardSize(tester).width;
    // ignore: avoid_print
    print('landscape card width = $before, screenW = ${screenW}');

    await _rotate(tester, portrait);
    final after = _cardSize(tester).width;
    // ignore: avoid_print
    print('portrait card width = $after, screenW = ${screenW}');
    expect(_hasSizedBoxWidth(tester, 300), isTrue, reason: 'SizedBox 固定宽度仍在');

    xbNavigatorState.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('dialog 默认(无maxWidth): 横屏弹出 -> 切竖屏后宽度是否变化',
      (WidgetTester tester) async {
    _setView(tester, landscape);
    await _pumpHarness(tester, () {
      dialog(
        title: '提示',
        msg: '确定删除吗？',
        btnTitles: const ['取消', '确定'],
        onSelected: _noopOnSelected,
      );
    });
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    final before = _cardSize(tester).width;
    // ignore: avoid_print
    print('landscape default card width = $before, screenW = ${screenW}');

    await _rotate(tester, portrait);
    final after = _cardSize(tester).width;
    // ignore: avoid_print
    print('portrait default card width = $after, screenW = ${screenW}');

    xbNavigatorState.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('XBDialogInput 默认: 横屏弹出 -> 切竖屏后宽度是否变化',
      (WidgetTester tester) async {
    _setView(tester, landscape);
    await _pumpHarness(tester, () {
      dialogWidget(XBDialogInput(
        title: '输入',
        onDone: _noopOnDone,
      ));
    });
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    final before = _cardSize(tester).width;
    // ignore: avoid_print
    print('landscape input card width = $before, screenW = ${screenW}');

    await _rotate(tester, portrait);
    final after = _cardSize(tester).width;
    // ignore: avoid_print
    print('portrait input card width = $after, screenW = ${screenW}');

    xbNavigatorState.pop();
    await tester.pumpAndSettle();
  });

  testWidgets('XBDialogInput + maxWidth: 竖屏弹出 -> 切横屏后宽度是否变化',
      (WidgetTester tester) async {
    _setView(tester, portrait);
    await _pumpHarness(tester, () {
      dialogWidget(XBDialogInput(
        title: '输入',
        maxWidth: 500,
        onDone: _noopOnDone,
      ));
    });
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    final before = _cardSize(tester).width;
    // ignore: avoid_print
    print('portrait input maxWidth=500 card width = $before, screenW = ${screenW}');

    await _rotate(tester, landscape);
    final after = _cardSize(tester).width;
    // ignore: avoid_print
    print('landscape input card width = $after, screenW = ${screenW}');

    xbNavigatorState.pop();
    await tester.pumpAndSettle();
  });
}
