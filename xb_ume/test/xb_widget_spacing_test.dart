import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/core/xb_ume_widget_spacing_calculator.dart';

const Key _kTarget = Key('spacing_target');

XBUmeWidgetSpacing? _calculateOf(WidgetTester tester) {
  final element = tester.element(find.byKey(_kTarget));
  final searchRoot = tester.element(find.byType(MaterialApp));
  return const XBUmeWidgetSpacingCalculator()
      .calculate(element, searchRoot: searchRoot);
}

Widget _app(Widget body) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(body: body),
  );
}

void main() {
  testWidgets('Column 布局：上下取最近可见组件间距，左右回退父边缘', (tester) async {
    await tester.pumpWidget(
      _app(
        Column(
          // 视口 800x600：top 0..100，target 275..325，bottom 500..600。
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(key: const Key('top'), height: 100, color: Colors.red),
            Container(key: _kTarget, height: 50, color: Colors.green),
            Container(
              key: const Key('bottom'),
              height: 100,
              color: Colors.blue,
            ),
          ],
        ),
      ),
    );

    final spacing = _calculateOf(tester);
    expect(spacing, isNotNull);

    // 上方最近可见组件：275 - 100 = 175。
    expect(spacing!.up, isNotNull);
    expect(spacing.up!.distance, closeTo(175, 0.1));
    expect(spacing.up!.source, XBUmeSpacingSource.component);

    // 下方最近可见组件：500 - 325 = 175。
    expect(spacing.down, isNotNull);
    expect(spacing.down!.distance, closeTo(175, 0.1));
    expect(spacing.down!.source, XBUmeSpacingSource.component);

    // 左右方向没有可见组件（Column 内全部水平铺满），回退到父边缘。
    expect(spacing.left, isNotNull);
    expect(spacing.left!.source, XBUmeSpacingSource.parentEdge);
    expect(spacing.left!.distance, closeTo(0, 0.1));
    expect(spacing.right, isNotNull);
    expect(spacing.right!.source, XBUmeSpacingSource.parentEdge);
    expect(spacing.right!.distance, closeTo(0, 0.1));

    // 参照组件 rect：上/下行为对应行 box，父边缘回退指向 Column 全屏。
    expect(spacing.up!.sourceRect, const Rect.fromLTWH(0, 0, 800, 100));
    expect(spacing.down!.sourceRect, const Rect.fromLTWH(0, 500, 800, 100));
    expect(spacing.left!.sourceRect, const Rect.fromLTWH(0, 0, 800, 600));
    expect(spacing.right!.sourceRect, const Rect.fromLTWH(0, 0, 800, 600));
  });

  testWidgets('父边缘间距：Center 中单子组件到父组件四边均可见', (tester) async {
    await tester.pumpWidget(
      _app(
        const Center(
          child: SizedBox(key: _kTarget, width: 50, height: 50),
        ),
      ),
    );

    final spacing = _calculateOf(tester);
    expect(spacing, isNotNull);

    // 默认测试视口 800x600，组件居中 50x50；四周无其他可见组件，
    // 回退到父组件（Center，全屏）边缘。
    expect(spacing!.left!.source, XBUmeSpacingSource.parentEdge);
    expect(spacing.left!.distance, closeTo(375, 0.1));
    expect(spacing.right!.distance, closeTo(375, 0.1));
    expect(spacing.up!.distance, closeTo(275, 0.1));
    expect(spacing.down!.distance, closeTo(275, 0.1));
  });

  testWidgets('Stack 错位布局：无重叠方向回退父边缘，Positioned 包裹自动上溯', (tester) async {
    await tester.pumpWidget(
      _app(
        Padding(
          // 左侧组件：x 40..70，y 40..140（与目标垂直方向错位）；
          // 目标：x 140..190，y 60..110；右侧组件：x 240..290；
          // 下方组件：x 140..190，y 240..290。
          padding: const EdgeInsets.all(40),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                child: Container(
                  key: const Key('left'),
                  width: 30,
                  height: 100,
                  color: Colors.orange,
                ),
              ),
              Positioned(
                left: 100,
                top: 20,
                child: Container(
                  key: _kTarget,
                  width: 50,
                  height: 50,
                  color: Colors.green,
                ),
              ),
              Positioned(
                left: 200,
                top: 20,
                child: Container(
                  key: const Key('right'),
                  width: 50,
                  height: 50,
                  color: Colors.purple,
                ),
              ),
              Positioned(
                left: 100,
                top: 200,
                child: Container(
                  key: const Key('below'),
                  width: 50,
                  height: 50,
                  color: Colors.teal,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final spacing = _calculateOf(tester);
    expect(spacing, isNotNull);

    // 上方没有水平重叠的可见组件，回退到 Stack 边缘（60 - 40 = 20），
    // 且 Positioned（ParentDataWidget）与目标共享 renderObject，需上溯到 Stack。
    expect(spacing!.up!.source, XBUmeSpacingSource.parentEdge);
    expect(spacing.up!.distance, closeTo(20, 0.1));

    // 左侧可见组件：140 - 70 = 70。
    expect(spacing.left!.source, XBUmeSpacingSource.component);
    expect(spacing.left!.distance, closeTo(70, 0.1));

    // 右侧可见组件：240 - 190 = 50。
    expect(spacing.right!.source, XBUmeSpacingSource.component);
    expect(spacing.right!.distance, closeTo(50, 0.1));

    // 下方可见组件：240 - 110 = 130。
    expect(spacing.down!.source, XBUmeSpacingSource.component);
    expect(spacing.down!.distance, closeTo(130, 0.1));

    // 参照组件 rect：上为 Stack 边缘（父边缘），其余为对应可见组件。
    expect(spacing.up!.sourceRect, const Rect.fromLTWH(40, 40, 720, 520));
    expect(spacing.left!.sourceRect, const Rect.fromLTWH(40, 40, 30, 100));
    expect(spacing.right!.sourceRect, const Rect.fromLTWH(240, 60, 50, 50));
    expect(spacing.down!.sourceRect, const Rect.fromLTWH(140, 240, 50, 50));
  });

  testWidgets('跨层级测量：嵌套在单元格内的组件量到周围行的可见距离', (tester) async {
    await tester.pumpWidget(
      _app(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 上方行：0..100。
            Container(key: const Key('above'), height: 100, color: Colors.green),
            // 不可见的 20px 间隔，不应作为参照。
            const SizedBox(height: 20),
            // 单元格：120..180，内部目标：130..170。
            Container(
              color: Colors.teal,
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Container(
                key: _kTarget,
                height: 40,
                color: Colors.white,
              ),
            ),
            // 不可见的 30px 间隔，不应作为参照。
            const SizedBox(height: 30),
            // 下方行：210..310。
            Container(key: const Key('below'), height: 100, color: Colors.red),
          ],
        ),
      ),
    );

    final spacing = _calculateOf(tester);
    expect(spacing, isNotNull);

    // 上方：130 - 100 = 30（量到上方行可见底边，而不是不可见间隔）。
    expect(spacing!.up!.source, XBUmeSpacingSource.component);
    expect(spacing.up!.distance, closeTo(30, 0.1));

    // 下方：210 - 170 = 40。
    expect(spacing.down!.source, XBUmeSpacingSource.component);
    expect(spacing.down!.distance, closeTo(40, 0.1));

    // 左右无可见邻居，回退到单元格（父级）边缘。
    expect(spacing.left!.source, XBUmeSpacingSource.parentEdge);
    expect(spacing.left!.distance, closeTo(0, 0.1));
    expect(spacing.right!.source, XBUmeSpacingSource.parentEdge);
    expect(spacing.right!.distance, closeTo(0, 0.1));

    // 参照组件 rect：上/下行为对应行 box，左右为单元格 box。
    expect(spacing.up!.sourceRect, const Rect.fromLTWH(0, 0, 800, 100));
    expect(spacing.down!.sourceRect, const Rect.fromLTWH(0, 210, 800, 100));
    expect(spacing.left!.sourceRect, const Rect.fromLTWH(0, 120, 800, 60));
    expect(spacing.right!.sourceRect, const Rect.fromLTWH(0, 120, 800, 60));
  });

  testWidgets('系统包装组件（Semantics/Listener）不作为参照', (tester) async {
    await tester.pumpWidget(
      _app(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 视口 800x600：above 0..100，target 120..170，below 200..300。
            Semantics(
              child: Container(
                key: const Key('above'),
                height: 100,
                color: Colors.green,
              ),
            ),
            const SizedBox(height: 20),
            Listener(
              child: Container(
                key: _kTarget,
                height: 50,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 30),
            Container(key: const Key('below'), height: 100, color: Colors.red),
          ],
        ),
      ),
    );

    final spacing = _calculateOf(tester);
    expect(spacing, isNotNull);

    // 参照组件类型不能是系统包装组件。
    expect(spacing!.up!.sourceWidgetType, isNot(contains('Semantics')));
    expect(spacing.down!.sourceWidgetType, isNot(contains('Listener')));

    // 距离仍量到可见行边缘：120 - 100 = 20，200 - 170 = 30。
    expect(spacing.up!.distance, closeTo(20, 0.1));
    expect(spacing.down!.distance, closeTo(30, 0.1));
  });

  testWidgets('summaryText 包含方向箭头与来源', (tester) async {
    await tester.pumpWidget(
      _app(
        Column(
          // 与首个用例相同的 spaceBetween 布局：上下可见间距均为 175。
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(key: const Key('top'), height: 100, color: Colors.red),
            Container(key: _kTarget, height: 50, color: Colors.green),
            Container(
              key: const Key('bottom'),
              height: 100,
              color: Colors.blue,
            ),
          ],
        ),
      ),
    );

    final spacing = _calculateOf(tester);
    expect(spacing, isNotNull);
    expect(spacing!.hasAny, isTrue);
    expect(spacing.summaryText, contains('↑175.0('));
    expect(spacing.summaryText, contains('↓175.0('));
    expect(spacing.summaryText, contains('(parent)'));
  });

  testWidgets('被上层路由覆盖/Offstage 的残留组件不作为参照', (tester) async {
    // 模拟下层路由残留：Navigator 中被不透明路由覆盖的页面会转
    // offstage，其 Element 树仍完成布局（尺寸有效），但命中测试不可达、
    // 不再绘制。此处用 Stack + Offstage 复现同等条件。
    await tester.pumpWidget(
      _app(
        Stack(
          children: [
            // above 0..100，target 120..170，below 200..300。
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                    key: const Key('above'),
                    height: 100,
                    color: Colors.green),
                const SizedBox(height: 20),
                Container(key: _kTarget, height: 50, color: Colors.white),
                const SizedBox(height: 30),
                Container(key: const Key('below'), height: 100, color: Colors.red),
              ],
            ),
            // 残留组件恰好横在 target 与 above 之间的空隙里（110..118），
            // 若无可见性过滤，↑ 会错误量到它（120 - 118 = 2）。
            Positioned(
              top: 110,
              left: 0,
              child: Offstage(
                offstage: true,
                child: Container(
                    width: 800, height: 8, color: Colors.purple),
              ),
            ),
          ],
        ),
      ),
    );

    final spacing = _calculateOf(tester);
    expect(spacing, isNotNull);

    // 上方仍量到可见的 above 行：120 - 100 = 20。
    expect(spacing!.up!.source, XBUmeSpacingSource.component);
    expect(spacing.up!.distance, closeTo(20, 0.1));
    expect(spacing.up!.sourceRect, const Rect.fromLTWH(0, 0, 800, 100));

    // 下方不受影响：200 - 170 = 30。
    expect(spacing.down!.distance, closeTo(30, 0.1));
  });
}
