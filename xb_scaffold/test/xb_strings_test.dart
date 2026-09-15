import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// dialogWidget 内容的空回调（保持 const 构造）
void _noop(String value) {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 每个用例前恢复中文默认，避免用例间串扰
    xbSetDefaultStrings(const XBScaffoldStrings());
    // XBDialogInput 构建会读主题，测试环境需预先注册
    XBThemeVM().setThemeForIndex(
        XBTheme(config: XBThemeConfig(primaryColor: Colors.blue, imgPrefix: 'a/')), 0);
  });

  tearDown(() {
    XBThemeVM().resetForTest();
  });

  testWidgets('默认文案：未配置时 dialogInput 兜底为中文', (tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: xbNavigatorKey,
      home: const Scaffold(body: SizedBox()),
    ));
    dialogWidget(const XBDialogInput(title: '标题', onDone: _noop));
    await tester.pumpAndSettle();

    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
  });

  testWidgets('xbSetDefaultStrings 全局替换默认文案', (tester) async {
    xbSetDefaultStrings(const XBScaffoldStrings(
      dialogInputCancel: 'CANCEL',
      dialogInputConfirm: 'OK',
      dialogInputNotEmptyTip: 'REQUIRED',
    ));
    await tester.pumpWidget(MaterialApp(
      navigatorKey: xbNavigatorKey,
      home: const Scaffold(body: SizedBox()),
    ));
    dialogWidget(const XBDialogInput(title: '标题', onDone: _noop));
    await tester.pumpAndSettle();

    expect(find.text('CANCEL'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
  });

  testWidgets('局部参数优先级高于全局默认文案', (tester) async {
    xbSetDefaultStrings(const XBScaffoldStrings(
      dialogInputCancel: 'CANCEL',
      dialogInputConfirm: 'OK',
    ));
    await tester.pumpWidget(MaterialApp(
      navigatorKey: xbNavigatorKey,
      home: const Scaffold(body: SizedBox()),
    ));
    dialogWidget(const XBDialogInput(
      title: '标题',
      cancelTitle: '局部取消',
      onDone: _noop,
    ));
    await tester.pumpAndSettle();

    expect(find.text('局部取消'), findsOneWidget);
    expect(find.text('CANCEL'), findsNothing);
    // 未传局部参数的确定按钮仍走全局配置
    expect(find.text('OK'), findsOneWidget);
  });

  test('XBErrorView 兜底文案走全局配置', () {
    xbSetDefaultStrings(const XBScaffoldStrings(
      errorViewMessage: 'GLOBAL_MSG',
      errorViewCopyButton: 'GLOBAL_COPY',
      errorViewCopiedHint: 'GLOBAL_HINT',
    ));
    const view = XBErrorView();
    expect(view.effectiveMessage, 'GLOBAL_MSG');
    expect(view.effectiveCopyButtonText, 'GLOBAL_COPY');
    expect(view.effectiveCopiedHintText, 'GLOBAL_HINT');

    // 局部参数覆盖全局
    const view2 = XBErrorView(message: 'LOCAL_MSG');
    expect(view2.effectiveMessage, 'LOCAL_MSG');
    expect(view2.effectiveCopyButtonText, 'GLOBAL_COPY');
  });

  test('未配置时 XBErrorView 兜底为中文默认值', () {
    xbSetDefaultStrings(const XBScaffoldStrings());
    const view = XBErrorView();
    expect(view.effectiveMessage, '页面发生异常，请稍后重试');
    expect(view.effectiveCopyButtonText, '复制异常');
    expect(view.effectiveCopiedHintText, '已复制异常信息');
  });
}
