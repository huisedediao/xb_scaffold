import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// 可配置开关的测试页面，覆盖 XBPage 的构建分支与 loading 遮罩交互
class _TestPage extends XBPage<_TestVM> {
  const _TestPage({
    this.withLoading = false,
    this.initLoading = false,
    this.responseContentWhileLoading = false,
    this.longPressThreshold = 500,
    this.endEditingWhileTouch = true,
    this.pageCanPop = true,
    this.popLog,
  });

  final bool withLoading;
  final bool initLoading;
  final bool responseContentWhileLoading;
  final int longPressThreshold;
  final bool endEditingWhileTouch;
  final bool pageCanPop;
  final List<String>? popLog;

  @override
  _TestVM generateVM(BuildContext context) =>
      _TestVM(context: context, page: this);

  @override
  Widget buildPage(BuildContext context) => const _TestPageContent();

  @override
  bool needLoading(BuildContext context) => withLoading;

  @override
  bool needInitLoading(BuildContext context) => initLoading;

  @override
  bool needResponseContentWhileLoading(BuildContext context) =>
      responseContentWhileLoading;

  @override
  int longPressThresholdMilliseconds(BuildContext context) =>
      longPressThreshold;

  @override
  bool needEndEditingWhileTouch(BuildContext context) => endEditingWhileTouch;

  @override
  bool canPop(BuildContext context) => pageCanPop;

  @override
  void handlePopSuccess(BuildContext context, result) =>
      popLog?.add('success');

  @override
  void handlePopFailure(BuildContext context, result) =>
      popLog?.add('failure');
}

class _TestVM extends XBPageVM<_TestPage> {
  _TestVM({required super.context, required this.page});

  final _TestPage page;
}

/// 输入框焦点（顶层持有，便于断言）
FocusNode _textFieldFocusNode = FocusNode();

/// 页面内容：计数按钮 + 输入框
class _TestPageContent extends StatelessWidget {
  const _TestPageContent();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
            key: const ValueKey('test-textfield'),
            focusNode: _textFieldFocusNode),
        ElevatedButton(
          key: const ValueKey('test-button'),
          onPressed: () => _tapCount++,
          child: const Text('tap me'),
        ),
      ],
    );
  }
}

/// 按钮点击计数（顶层变量，VM 每次重建不影响）
int _tapCount = 0;

Future<void> _pumpPage(WidgetTester tester, _TestPage page) async {
  // loading 遮罩会读 topBarH → xbNavigatorContext，
  // 需向 MaterialApp 注册全局 navigatorKey
  await tester.pumpWidget(MaterialApp(
    navigatorKey: xbNavigatorKey,
    home: page,
  ));
  // XBLoadingWidget 含无限旋转动画，不能 pumpAndSettle，用固定时长推进
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 从当前页面 State 取 VM（pumpWidget 同类型页面会原地 update，
/// initState 不重跑，不能依赖 generateVM 时的 last 登记）
_TestVM _vmOf(WidgetTester tester) =>
    tester.state<XBWidgetState<_TestVM>>(find.byType(_TestPage)).vmInstance;

/// 推进若干帧，等待 loading 淡入/淡出动画完成
Future<void> _pumpFrames(WidgetTester tester) async {
  for (int i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // XBPage 默认配置会读主题，测试环境无 XBScaffold，需预先注册主题
    XBThemeVM().setThemeForIndex(
        XBTheme(config: XBThemeConfig(primaryColor: Colors.blue, imgPrefix: 'a/')), 0);
    _tapCount = 0;
    _textFieldFocusNode = FocusNode();
  });

  tearDown(() {
    XBThemeVM().resetForTest();
  });

  testWidgets('默认配置：标题与内容正常渲染，无 loading', (tester) async {
    await _pumpPage(tester, const _TestPage());

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byKey(const ValueKey('test-button')), findsOneWidget);
    expect(find.byType(XBLoadingWidget), findsNothing);
  });

  testWidgets('showLoading/hideLoading 控制 loading 遮罩显隐', (tester) async {
    await _pumpPage(tester, const _TestPage(withLoading: true));
    expect(find.byType(XBLoadingWidget), findsNothing);

    _vmOf(tester).showLoading();
    await _pumpFrames(tester);
    expect(find.byType(XBLoadingWidget), findsOneWidget);

    _vmOf(tester).hideLoading();
    await _pumpFrames(tester);
    expect(find.byType(XBLoadingWidget), findsNothing);
  });

  testWidgets('needInitLoading 页面进入即显示 loading', (tester) async {
    await _pumpPage(
        tester, const _TestPage(withLoading: true, initLoading: true));
    expect(find.byType(XBLoadingWidget), findsOneWidget);
  });

  testWidgets('loading 时内容默认被遮罩屏蔽，needResponseContent 放行', (tester) async {
    // 默认：遮罩拦截内容点击
    await _pumpPage(tester, const _TestPage(withLoading: true));
    _vmOf(tester).showLoading();
    await _pumpFrames(tester);

    await tester.tap(find.byKey(const ValueKey('test-button')),
        warnIfMissed: false);
    await tester.pump();
    expect(_tapCount, 0, reason: 'loading 时内容点击应被遮罩拦截');

    // 放行配置：内容可点击
    await _pumpPage(
        tester,
        const _TestPage(
            withLoading: true, responseContentWhileLoading: true));
    _vmOf(tester).showLoading();
    await _pumpFrames(tester);

    await tester.tap(find.byKey(const ValueKey('test-button')),
        warnIfMissed: false);
    await tester.pump();
    expect(_tapCount, 1, reason: 'needResponseContentWhileLoading=true 时点击应到达内容');
  });

  testWidgets('普通点击触发 endEditing，长按不触发', (tester) async {
    // 阈值设为极大值，普通点击必然属于短按分支
    await _pumpPage(tester, const _TestPage(longPressThreshold: 100000));

    await tester.tap(find.byKey(const ValueKey('test-textfield')));
    await tester.pumpAndSettle();
    expect(_textFieldFocusNode.hasFocus, isTrue, reason: '输入框应已聚焦');

    await tester.tap(find.byKey(const ValueKey('test-button')),
        warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_textFieldFocusNode.hasFocus, isFalse, reason: '短按后应结束编辑');

    // 阈值设为 0，任何点击都走长按分支
    await _pumpPage(tester, const _TestPage(longPressThreshold: 0));

    await tester.tap(find.byKey(const ValueKey('test-textfield')));
    await tester.pumpAndSettle();
    expect(_textFieldFocusNode.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey('test-button')),
        warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_textFieldFocusNode.hasFocus, isTrue, reason: '长按不应结束编辑');

    // needEndEditingWhileTouch=false 时短按也不结束编辑
    await _pumpPage(
        tester,
        const _TestPage(
            longPressThreshold: 100000, endEditingWhileTouch: false));

    await tester.tap(find.byKey(const ValueKey('test-textfield')));
    await tester.pumpAndSettle();
    expect(_textFieldFocusNode.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey('test-button')),
        warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_textFieldFocusNode.hasFocus, isTrue,
        reason: 'needEndEditingWhileTouch=false 时短按不应结束编辑');
  });

  testWidgets('canPop=false 拦截返回并触发 handlePopFailure', (tester) async {
    final log = <String>[];
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute(
        builder: (_) => _TestPage(pageCanPop: false, popLog: log)));
    await tester.pumpAndSettle();

    // 本 Flutter 版本 maybePop 的返回值表示"是否处理了 pop 请求"，
    // 路由是否真的弹出以 PopScope 回调与页面是否仍在树上为准
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(log, ['failure'], reason: 'canPop=false 时 pop 被拦截，走 handlePopFailure');
    expect(find.byType(_TestPage), findsOneWidget, reason: '路由不应被弹出');
  });

  testWidgets('canPop=true 正常返回并触发 handlePopSuccess', (tester) async {
    final log = <String>[];
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute(
        builder: (_) => _TestPage(pageCanPop: true, popLog: log)));
    await tester.pumpAndSettle();

    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(log, ['success'], reason: 'canPop=true 时正常返回，走 handlePopSuccess');
    expect(find.byType(_TestPage), findsNothing, reason: '路由应被弹出');
  });
}
