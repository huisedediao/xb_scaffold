import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_analytics_plus/xb_analytics_plus.dart';

/// 模拟业务组合组件（无独立 RenderObject）。
class _PathCard extends StatelessWidget {
  const _PathCard({required this.title, this.onTap});

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(title),
        onTap: onTap,
      ),
    );
  }
}

/// 模拟调试工具自身 UI（用于黑名单过滤验证）。
class _XBUmePanel extends StatelessWidget {
  const _XBUmePanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {},
      child: Container(width: 50, height: 50, color: Colors.red),
    );
  }
}

void main() {
  Future<XBMemorySink> initSinks() async {
    final memory = XBMemorySink();
    await initXBTrack(
      XBTrackConfig(
        enabled: true,
        enableConsoleSink: false,
        enableMemorySink: false,
        enableLocalStoreSink: false,
        flushInterval: const Duration(hours: 1),
        sinks: <XBTrackSink>[memory],
      ),
    );
    return memory;
  }

  testWidgets('点击产出 auto_click 事件，携带类型链与文本', (tester) async {
    final memory = await initSinks();

    await tester.pumpWidget(
      XBAutoTrackListener(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {},
                child: const Text('increment'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('increment'));
    await tester.pump();
    await xbFlushTrack();
    await closeXBTrack(flushBeforeClose: false);

    final clicks = memory.events
        .where((e) => e.event == 'auto_click')
        .toList(growable: false);
    expect(clicks, isNotEmpty);

    final params = clicks.first.params;
    expect(params['typeChain'], contains('TextButton'));
    expect(params['text'], 'increment');
    // MaterialApp 默认 initialRoute 为 '/'。
    expect(clicks.first.pageName, '/');
  });

  testWidgets('类型链穿透组合组件，拿到业务类型名', (tester) async {
    final memory = await initSinks();

    await tester.pumpWidget(
      XBAutoTrackListener(
        child: MaterialApp(
          home: Scaffold(
            body: _PathCard(
              title: 'Custom Card Demo',
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Custom Card Demo'));
    await tester.pump();
    await xbFlushTrack();
    await closeXBTrack(flushBeforeClose: false);

    final clicks = memory.events
        .where((e) => e.event == 'auto_click')
        .toList(growable: false);
    expect(clicks, isNotEmpty);
    expect(clicks.first.params['typeChain'], contains('_PathCard'));
    expect(clicks.first.params['text'], 'Custom Card Demo');
  });

  testWidgets('黑名单命中时丢弃事件', (tester) async {
    final memory = await initSinks();

    await tester.pumpWidget(
      const XBAutoTrackListener(
        config: XBAutoTrackConfig(blacklist: <String>['_XBUmePanel']),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: _XBUmePanel(child: SizedBox()),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(_XBUmePanel));
    await tester.pump();
    await xbFlushTrack();
    await closeXBTrack(flushBeforeClose: false);

    expect(
      memory.events.where((e) => e.event == 'auto_click'),
      isEmpty,
    );
  });

  testWidgets('enabled=false 时不产出事件', (tester) async {
    final memory = await initSinks();

    await tester.pumpWidget(
      XBAutoTrackListener(
        config: const XBAutoTrackConfig(enabled: false),
        child: MaterialApp(
          home: Scaffold(
            body: TextButton(onPressed: () {}, child: const Text('btn')),
          ),
        ),
      ),
    );

    await tester.tap(find.text('btn'));
    await tester.pump();
    await xbFlushTrack();
    await closeXBTrack(flushBeforeClose: false);

    expect(
      memory.events.where((e) => e.event == 'auto_click'),
      isEmpty,
    );
  });

  testWidgets('命名路由下携带 routeName', (tester) async {
    final memory = await initSinks();

    await tester.pumpWidget(
      XBAutoTrackListener(
        child: MaterialApp(
          routes: <String, WidgetBuilder>{
            'demo': (_) => Scaffold(
                  body: TextButton(
                    onPressed: () {},
                    child: const Text('named'),
                  ),
                ),
          },
          initialRoute: 'demo',
        ),
      ),
    );

    await tester.tap(find.text('named'));
    await tester.pump();
    await xbFlushTrack();
    await closeXBTrack(flushBeforeClose: false);

    final clicks = memory.events
        .where((e) => e.event == 'auto_click')
        .toList(growable: false);
    expect(clicks, isNotEmpty);
    expect(clicks.first.pageName, 'demo');
    expect(clicks.first.params['routeName'], 'demo');
  });
}
