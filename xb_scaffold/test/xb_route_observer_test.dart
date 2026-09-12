import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// 按名字登记的测试 VM（widgetDidBuilt 时记录，避免依赖 tester.state 查找）
final Map<String, _ObsVM> _vmsByName = {};

/// 记录生命周期事件的测试页面
class _ObsPage extends XBPage<_ObsVM> {
  const _ObsPage({required this.name, required this.log});

  final String name;
  final List<String> log;

  @override
  _ObsVM generateVM(BuildContext context) =>
      _ObsVM(context: context, name: name, log: log);

  @override
  Widget buildPage(BuildContext context) => const SizedBox();
}

class _ObsVM extends XBPageVM<_ObsPage> {
  _ObsVM({required super.context, required this.name, required this.log});

  final String name;
  final List<String> log;

  @override
  void widgetDidBuilt() {
    super.widgetDidBuilt();
    _vmsByName[name] = this;
  }

  @override
  void didPush() {
    super.didPush();
    log.add('$name didPush');
  }

  @override
  void didPushNext() {
    super.didPushNext();
    log.add('$name didPushNext');
  }

  @override
  void didPop() {
    super.didPop();
    log.add('$name didPop');
  }

  @override
  void didPopNext() {
    super.didPopNext();
    log.add('$name didPopNext');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // XBPage 默认配置会读主题，测试环境无 XBScaffold，需预先注册主题
    XBThemeVM().setThemeForIndex(
        XBTheme(config: XBThemeConfig(primaryColor: Colors.blue, imgPrefix: 'a/')), 0);
    _vmsByName.clear();
  });

  tearDown(() {
    XBThemeVM().resetForTest();
    _vmsByName.clear();
  });

  testWidgets('push/pop 全流程：各页面收到正确的生命周期回调', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [xbRouteObserver],
      home: _ObsPage(name: 'A', log: log),
    ));
    await tester.pumpAndSettle();

    // home 页订阅时 RouteObserver 补发 didPush
    expect(log, contains('A didPush'));
    expect(_vmsByName['A']!.isTop, isTrue, reason: '栈顶页面 isTop 应为 true');

    // push B：A 收到 didPushNext，B 订阅后收到 didPush
    tester.state<NavigatorState>(find.byType(Navigator)).push(
          MaterialPageRoute(
            builder: (_) => _ObsPage(name: 'B', log: log),
          ),
        );
    await tester.pumpAndSettle();

    expect(log, contains('A didPushNext'));
    expect(log, contains('B didPush'));
    expect(_vmsByName['A']!.isTop, isFalse, reason: '被覆盖页面 isTop 应为 false');
    expect(_vmsByName['B']!.isTop, isTrue);

    // pop B：B 收到 didPop，A 收到 didPopNext 重新回到栈顶
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    expect(log, contains('B didPop'));
    expect(log, contains('A didPopNext'));
    expect(_vmsByName['A']!.isTop, isTrue, reason: 'pop 后 A 恢复栈顶');

    // 完整顺序校验（pop 时 RouteObserver 先通知前一页 didPopNext，再通知出栈页 didPop）
    expect(log, [
      'A didPush',
      'A didPushNext',
      'B didPush',
      'A didPopNext',
      'B didPop',
    ]);
  });

  testWidgets('三层路由：中间页面的压栈/出栈回调', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [xbRouteObserver],
      home: _ObsPage(name: 'A', log: log),
    ));
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute(
        builder: (_) => _ObsPage(name: 'B', log: log)));
    await tester.pumpAndSettle();
    navigator.push(MaterialPageRoute(
        builder: (_) => _ObsPage(name: 'C', log: log)));
    await tester.pumpAndSettle();

    expect(_vmsByName['A']!.isTop, isFalse);
    expect(_vmsByName['B']!.isTop, isFalse);
    expect(_vmsByName['C']!.isTop, isTrue);

    // 只 pop C，B 应恢复，A 不受影响
    log.clear();
    navigator.pop();
    await tester.pumpAndSettle();

    // pop 时先通知前一页 didPopNext，再通知出栈页 didPop
    expect(log, ['B didPopNext', 'C didPop']);
    expect(_vmsByName['B']!.isTop, isTrue);
    expect(_vmsByName['A']!.isTop, isFalse,
        reason: 'A 仍被 B 覆盖，不应恢复栈顶');
  });

  testWidgets('页面销毁后自动取消订阅，不影响后续页面', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [xbRouteObserver],
      home: _ObsPage(name: 'A', log: log),
    ));
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute(
        builder: (_) => _ObsPage(name: 'B', log: log)));
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();

    // B 已销毁。再 push/pop 一个新页面，B 不应再收到任何回调
    log.clear();
    navigator.push(MaterialPageRoute(
        builder: (_) => _ObsPage(name: 'C', log: log)));
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();

    expect(log, [
      'A didPushNext',
      'C didPush',
      'A didPopNext',
      'C didPop',
    ], reason: '已销毁的 B 不应再出现于回调列表');
  });
}
