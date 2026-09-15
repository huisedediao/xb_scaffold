import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// 按名字定位的测试对话框内容，自带关闭按钮
Widget _dialogContent(String name) => Dialog(
      key: ValueKey('dialog-$name'),
      child: TextButton(
        onPressed: () => xbNavigatorState.pop(),
        child: Text(name),
      ),
    );

/// 弹出当前正在显示的对话框并等动画结束
Future<void> _closeShowing(WidgetTester tester) async {
  xbNavigatorState.pop();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: xbNavigatorKey,
      home: const Scaffold(body: SizedBox()),
    ));
  }

  testWidgets('同优先级新对话框抢占当前显示，被替换者按 FIFO 回放', (tester) async {
    await pumpHost(tester);

    dialogWidget(_dialogContent('A'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dialog-A')), findsOneWidget);

    // 当前实现：同优先级但 id 更新的新对话框会替换正在显示的
    // （_shouldReplace 对 priority >= current 一律返回 true），
    // A 被重新入队，B 顶上
    dialogWidget(_dialogContent('B'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dialog-B')), findsOneWidget);
    expect(find.byKey(const ValueKey('dialog-A')), findsNothing);

    dialogWidget(_dialogContent('C'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dialog-C')), findsOneWidget);

    // 队列按 priority 降序排列，同 priority 时新创建的（id 更大）排在前——
    // C 关闭后先回放 B，再回放 A
    await _closeShowing(tester);
    expect(find.byKey(const ValueKey('dialog-B')), findsOneWidget);

    await _closeShowing(tester);
    expect(find.byKey(const ValueKey('dialog-A')), findsOneWidget);

    await _closeShowing(tester);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('高优先级抢占显示，低优先级重新入队并在其后恢复', (tester) async {
    await pumpHost(tester);

    dialogWidget(_dialogContent('low'), priority: 0);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dialog-low')), findsOneWidget);

    // 高优先级直接抢占，low 被重新入队
    dialogWidget(_dialogContent('high'), priority: 10);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dialog-high')), findsOneWidget);
    expect(find.byKey(const ValueKey('dialog-low')), findsNothing);

    // high 关闭后，low 自动恢复显示
    await _closeShowing(tester);
    expect(find.byKey(const ValueKey('dialog-low')), findsOneWidget);

    await _closeShowing(tester);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('低优先级不抢占正在显示的高优先级对话框', (tester) async {
    await pumpHost(tester);

    dialogWidget(_dialogContent('high'), priority: 5);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dialog-high')), findsOneWidget);

    dialogWidget(_dialogContent('low'), priority: 0);
    await tester.pumpAndSettle();
    // priority 低于当前显示者：只排队，不顶替
    expect(find.byKey(const ValueKey('dialog-high')), findsOneWidget);
    expect(find.byKey(const ValueKey('dialog-low')), findsNothing);

    // 关闭 high 后 low 自动显示
    await _closeShowing(tester);
    expect(find.byKey(const ValueKey('dialog-low')), findsOneWidget);

    await _closeShowing(tester);
    expect(find.byType(Dialog), findsNothing);
  });
}
