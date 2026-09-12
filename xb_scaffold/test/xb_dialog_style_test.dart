import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void _noopOnDone(String value) {}

void _noopOnSelected(int index) {}

List<XBThemeConfig> _themes() => [
      XBThemeConfig(primaryColor: Colors.blue, imgPrefix: 'assets/t1/'),
    ];

/// 挂载 XBMaterialApp + XBScaffold（注册主题），返回带按钮的首页
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

/// 弹出标准 dialog 并等待渲染完成
///
/// 注意：style 必须在 XBScaffold 挂载后再设置，
/// 否则会被 _syncGlobalConfigs 用 widget.dialogStyle（null）覆盖。
Future<void> _showDialog(
  WidgetTester tester, {
  XBDialogStyle? style,
  String title = '提示',
  String msg = '确定删除吗？',
  List<String> btnTitles = const ['取消', '确定'],
  TextStyle? titleStyle,
  TextStyle? msgStyle,
  Color? btnHighLightColor,
  Color? btnDefaultColor,
  double? btnFontSize,
  ValueChanged<int> onSelected = _noopOnSelected,
}) async {
  await _pumpHarness(tester, () {
    dialog(
      title: title,
      msg: msg,
      btnTitles: btnTitles,
      titleStyle: titleStyle,
      msgStyle: msgStyle,
      btnHighLightColor: btnHighLightColor,
      btnDefaultColor: btnDefaultColor,
      btnFontSize: btnFontSize,
      onSelected: onSelected,
    );
  });
  if (style != null) {
    xbSetDialogStyle(style);
  }
  await tester.tap(find.text('show'));
  await tester.pump();
}

Future<void> _closeDialog(WidgetTester tester) async {
  xbNavigatorState.pop();
  await tester.pump();
  await tester.pump();
}

ClipRRect? _dialogCard(WidgetTester tester, double radius) {
  final list = tester.widgetList<ClipRRect>(find.byWidgetPredicate(
    (w) => w is ClipRRect && w.borderRadius == BorderRadius.circular(radius),
  ));
  return list.isEmpty ? null : list.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    xbSetDialogStyle(null);
    XBThemeVM().resetForTest();
  });

  testWidgets('未配置 dialogStyle 时保持框架默认样式（回归保障）',
      (WidgetTester tester) async {
    expect(xbDialogStyle, isNull);
    await _showDialog(tester);

    final card = _dialogCard(tester, 10);

    // 标题默认 s18 + medium
    final title = tester.widget<Text>(find.text('提示'));
    expect(title.style?.fontSize, fontSizes.s18);
    expect(title.style?.fontWeight, fontWeights.medium);

    // 正文默认 s15 + #808080
    final msg = tester.widget<Text>(find.text('确定删除吗？'));
    expect(msg.style?.fontSize, fontSizes.s15);
    expect(msg.style?.color, const Color(0xFF808080));

    // 默认高亮按钮 colors.primary（XBButton 渲染两份 Text，取第一份）
    final confirm = tester.widget<Text>(find.text('确定').first);
    expect(confirm.style?.color, colors.primary);
    expect(confirm.style?.fontSize, fontSizes.s16);

    expect(card, isNotNull);
    await _closeDialog(tester);
  });

  testWidgets('xbSetDialogStyle 注入后各部分样式生效', (WidgetTester tester) async {
    await _showDialog(
      tester,
      style: const XBDialogStyle(
        backgroundColor: Colors.black,
        radius: 20,
        titleStyle: TextStyle(fontSize: 22, color: Colors.amber),
        msgStyle: TextStyle(fontSize: 13, color: Colors.green),
        lineColor: Colors.purple,
        btnHeight: 60,
        btnFontSize: 20,
        btnDefaultColor: Colors.orange,
        btnHighLightColor: Colors.red,
      ),
    );

    final card = _dialogCard(tester, 20);
    expect(card, isNotNull);
    // 卡片直接子 Container 即背景容器（取第一个后代 Container）
    final cardContainer = tester
        .widgetList<Container>(find.descendant(
          of: find.byWidget(card!),
          matching: find.byWidgetPredicate((w) => w is Container),
        ))
        .first;
    expect(cardContainer.color, Colors.black);

    final title = tester.widget<Text>(find.text('提示'));
    expect(title.style?.fontSize, 22);
    expect(title.style?.color, Colors.amber);

    final msg = tester.widget<Text>(find.text('确定删除吗？'));
    expect(msg.style?.fontSize, 13);
    expect(msg.style?.color, Colors.green);

    // XBButton 会渲染两份 Text（点击效果层），取第一份
    final cancel = tester.widget<Text>(find.text('取消').first);
    expect(cancel.style?.color, Colors.orange);
    expect(cancel.style?.fontSize, 20);

    final confirm = tester.widget<Text>(find.text('确定').first);
    expect(confirm.style?.color, Colors.red);
    expect(confirm.style?.fontSize, 20);

    // 竖向分隔线使用配置色、高度 60
    expect(
      find.byWidgetPredicate((w) =>
          w is Container &&
          w.constraints?.maxHeight == 60 &&
          w.color == Colors.purple),
      findsOneWidget,
    );

    await _closeDialog(tester);
  });

  testWidgets('调用处参数优先于全局 dialogStyle', (WidgetTester tester) async {
    xbSetDialogStyle(const XBDialogStyle(
      titleStyle: TextStyle(fontSize: 22, color: Colors.amber),
      btnHighLightColor: Colors.red,
    ));
    await _showDialog(
      tester,
      titleStyle: const TextStyle(fontSize: 26, color: Colors.blue),
      btnHighLightColor: Colors.teal,
    );

    final title = tester.widget<Text>(find.text('提示'));
    expect(title.style?.fontSize, 26);
    expect(title.style?.color, Colors.blue);

    final confirm = tester.widget<Text>(find.text('确定').first);
    expect(confirm.style?.color, Colors.teal);

    // 未覆盖的取值仍走框架默认
    final msg = tester.widget<Text>(find.text('确定删除吗？'));
    expect(msg.style?.fontSize, fontSizes.s15);
    expect(msg.style?.color, const Color(0xFF808080));

    await _closeDialog(tester);
  });

  testWidgets('xbSetDialogStyle(null) 恢复框架默认样式', (WidgetTester tester) async {
    xbSetDialogStyle(const XBDialogStyle(
      backgroundColor: Colors.black,
      radius: 20,
    ));
    expect(xbDialogStyle, isNotNull);

    xbSetDialogStyle(null);
    expect(xbDialogStyle, isNull);

    await _showDialog(tester);
    final card = _dialogCard(tester, 10);
    expect(card, isNotNull);
    await _closeDialog(tester);
  });

  testWidgets('分区 builder 生效，返回 null 回退默认渲染', (WidgetTester tester) async {
    await _showDialog(
      tester,
      style: XBDialogStyle(
        partBuilders: XBDialogPartBuilders(
          title: (context, style) => const Text('自定义标题区'),
          content: null,
          buttons: (context, style) => const Text('自定义按钮区'),
        ),
      ),
    );

    expect(find.text('自定义标题区'), findsOneWidget);
    expect(find.text('自定义按钮区'), findsOneWidget);
    // title 被替换后默认标题不渲染
    expect(find.text('提示'), findsNothing);

    // content builder 返回 null，回退默认内容渲染
    expect(find.text('确定删除吗？'), findsOneWidget);

    await _closeDialog(tester);
  });

  testWidgets('dialogContent 内容区使用全局 contentPadding',
      (WidgetTester tester) async {
    const padding = EdgeInsets.all(30);
    await _pumpHarness(tester, () {
      dialogContent(
        title: '标题',
        content: const Text('内容'),
        btnTitles: const ['确定'],
        onSelected: _noopOnSelected,
      );
    });
    xbSetDialogStyle(const XBDialogStyle(contentPadding: padding));
    await tester.tap(find.text('show'));
    await tester.pump();

    final paddings = tester.widgetList<Padding>(find.ancestor(
      of: find.text('内容'),
      matching: find.byType(Padding),
    ));
    expect(paddings.where((p) => p.padding == padding), isNotEmpty);

    await _closeDialog(tester);
  });

  testWidgets('XBDialogInput 接入全局样式', (WidgetTester tester) async {
    await _pumpHarness(tester, () {
      dialogWidget(
        const XBDialogInput(
          title: '输入标题',
          subTitle: '副标题',
          placeholder: 'placeholder',
          onDone: _noopOnDone,
        ),
      );
    });
    xbSetDialogStyle(const XBDialogStyle(
      backgroundColor: Colors.black,
      radius: 16,
      titleStyle: TextStyle(fontSize: 24, color: Colors.cyan),
      inputBorderColor: Colors.red,
      btnDefaultColor: Colors.orange,
      btnHighLightColor: Colors.red,
    ));
    await tester.tap(find.text('show'));
    await tester.pump();

    // 卡片背景
    expect(
      find.byWidgetPredicate((w) => w is Container && w.color == Colors.black),
      findsWidgets,
    );
    // 卡片圆角
    expect(_dialogCard(tester, 16), isNotNull);

    final title = tester.widget<Text>(find.text('输入标题'));
    expect(title.style?.fontSize, 24);
    expect(title.style?.color, Colors.cyan);

    // subTitle 未单独配置时保持默认样式
    expect(find.text('副标题'), findsOneWidget);

    // 取消/确定按钮（XBButton 渲染两份 Text，取第一份）
    final cancel = tester.widget<Text>(find.text('取消').first);
    expect(cancel.style?.color, Colors.orange);
    final confirm = tester.widget<Text>(find.text('确定').first);
    expect(confirm.style?.color, Colors.red);

    await _closeDialog(tester);
  });
}
