import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// 最近创建的测试 VM（widgetDidBuilt 时登记，避免依赖 tester.state 查找）
_TestPageVM? _lastVM;

/// 测试用页面：暴露排队任务的执行情况
class _TestPage extends XBPage<_TestPageVM> {
  const _TestPage({required this.log});

  final List<String> log;

  @override
  _TestPageVM generateVM(BuildContext context) => _TestPageVM(context: context, log: log);

  @override
  String setTitle(BuildContext context) => 'test';

  @override
  Widget buildPage(BuildContext context) {
    return const SizedBox();
  }
}

class _TestPageVM extends XBPageVM<_TestPage> {
  _TestPageVM({required super.context, required this.log});

  final List<String> log;

  @override
  void widgetDidBuilt() {
    super.widgetDidBuilt();
    _lastVM = this;
  }

  void queueTask() {
    addEnsureAfterPushAnimationTask(() => log.add('task'));
  }
}

/// 可控转场时长的路由：transitionDuration 控制动画完成时机
class _TestRoute extends PageRouteBuilder<void> {
  _TestRoute({required Widget page, required Duration duration})
      : super(
          transitionDuration: duration,
          pageBuilder: (_, __, ___) => page,
          transitionsBuilder: (_, animation, __, child) {
            return Opacity(opacity: animation.value, child: child);
          },
        );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // XBPage 默认配置会读主题（如 navigationBarTitleFontWeight → app.fontWeights），
    // 测试环境无 XBScaffold，需预先注册主题
    XBThemeVM().setThemeForIndex(
        XBTheme(config: XBThemeConfig(primaryColor: Colors.blue, imgPrefix: 'a/')), 0);
    _lastVM = null;
  });

  tearDown(() {
    XBThemeVM().resetForTest();
    _lastVM = null;
  });

  testWidgets('转场动画 completed 后排队任务才执行', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [xbRouteObserver],
      home: const Scaffold(body: SizedBox()),
    ));

    tester.state<NavigatorState>(find.byType(Navigator)).push(
          _TestRoute(
            page: _TestPage(log: log),
            duration: const Duration(milliseconds: 300),
          ),
        );

    // 页面挂载 + 首帧完成，VM 已登记
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final pageVM = _lastVM!;
    expect(pageVM.isFinishedPushAnimation, isFalse, reason: '动画进行中');

    // 动画进行中排队任务，不应立即执行
    pageVM.queueTask();
    await tester.pump(const Duration(milliseconds: 100));
    expect(log, isEmpty, reason: '动画未完成，任务不应执行');

    // 300ms 整：动画完成，任务精确触发
    //（completed 通知在时长边界帧的下一帧触发，多 pump 一帧）
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 16));
    expect(pageVM.isFinishedPushAnimation, isTrue);
    expect(log, ['task'], reason: '动画 completed 后任务应精确触发');
  });

  testWidgets('动画完成后排队任务立即执行', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [xbRouteObserver],
      home: const Scaffold(body: SizedBox()),
    ));

    tester.state<NavigatorState>(find.byType(Navigator)).push(
          _TestRoute(
            page: _TestPage(log: log),
            duration: const Duration(milliseconds: 300),
          ),
        );
    await tester.pumpAndSettle();

    final pageVM = _lastVM!;
    expect(pageVM.isFinishedPushAnimation, isTrue);

    // 动画完成后排队 → 立即执行
    pageVM.queueTask();
    expect(log, ['task']);
  });

  testWidgets('零转场时长：立即视为动画完成', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [xbRouteObserver],
      home: const Scaffold(body: SizedBox()),
    ));

    tester.state<NavigatorState>(find.byType(Navigator)).push(
          _TestRoute(
            page: _TestPage(log: log),
            duration: Duration.zero,
          ),
        );
    await tester.pump();
    await tester.pumpAndSettle();

    final pageVM = _lastVM!;
    expect(pageVM.isFinishedPushAnimation, isTrue,
        reason: '零转场（零时长自定义转场）应立即视为完成');

    pageVM.queueTask();
    expect(log, ['task']);
  });

  testWidgets('首路由 home 页：转场完成后视为动画完成', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [xbRouteObserver],
      home: _TestPage(log: log),
    ));
    // 首路由同样有转场动画，pumpAndSettle 跑完后应视为完成
    await tester.pumpAndSettle();

    final pageVM = _lastVM!;
    expect(pageVM.isFinishedPushAnimation, isTrue,
        reason: '首路由转场完成后应视为动画完成');

    pageVM.queueTask();
    expect(log, ['task']);
  });
}
