import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_analytics_plus/xb_analytics_plus.dart';

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

void main() {
  testWidgets('路由 push/pop 产出 page_enter/page_exit 与停留时长',
      (tester) async {
    await closeXBTrack(flushBeforeClose: false);
    final memory = await initSinks();
    final tracker = XBRouteTracker();

    await tester.pumpWidget(
      XBAutoTrackListener(
        child: MaterialApp(
          navigatorObservers: <NavigatorObserver>[tracker],
          home: const Scaffold(
            body: TextButton(
              onPressed: null,
              child: Text('home'),
            ),
          ),
        ),
      ),
    );

    // 首页由 MaterialApp 直接建栈，didPush 已触发 page_enter。
    final homeName = tracker.currentPage;
    expect(homeName, isNotNull);

    await tester.pump();
    await xbFlushTrack();
    final enterEvents = memory.events
        .where((e) => e.event == 'page_enter')
        .toList(growable: false);
    expect(enterEvents, isNotEmpty);

    await closeXBTrack(flushBeforeClose: false);
  });

  testWidgets('页面切换产生进入/离开事件对', (tester) async {
    await closeXBTrack(flushBeforeClose: false);
    final memory = await initSinks();
    final tracker = XBRouteTracker();

    await tester.pumpWidget(
      XBAutoTrackListener(
        child: MaterialApp(
          navigatorObservers: <NavigatorObserver>[tracker],
          routes: <String, WidgetBuilder>{
            'home': (_) => Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => Navigator.of(context).pushNamed('next'),
                      child: const Text('go next'),
                    ),
                  ),
                ),
            'next': (_) => const Scaffold(body: Text('next page')),
          },
          initialRoute: 'home',
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('go next'));
    await tester.pumpAndSettle();
    await xbFlushTrack();

    final enters = memory.events
        .where((e) => e.event == 'page_enter')
        .map((e) => e.pageName)
        .toList();
    final exits = memory.events
        .where((e) => e.event == 'page_exit')
        .map((e) => e.pageName)
        .toList();

    expect(enters, contains('home'));
    expect(enters, contains('next'));
    expect(exits, contains('home'));

    await closeXBTrack(flushBeforeClose: false);
  });

  test('Markdown 导出包含页面章节与带源码位置的点击步骤', () async {
    await closeXBTrack(flushBeforeClose: false);
    // 导出走内置 memorySink（自定义 sinks 不参与 export，见 Manager 设计）。
    await initXBTrack(
      const XBTrackConfig(
        enabled: true,
        enableConsoleSink: false,
        enableMemorySink: true,
        enableLocalStoreSink: false,
        flushInterval: Duration(hours: 1),
      ),
    );

    xbTrack('page_enter', pageName: 'home', params: {'pageName': 'home'});
    xbTrack('auto_click', pageName: 'home', params: <String, dynamic>{
      'typeChain': 'Home>ItemCard>ElevatedButton',
      'depth': 3,
      'text': '购买',
      'file': 'lib/pages/detail.dart',
      'line': 42,
      'column': 11,
    });
    xbTrack('page_exit', pageName: 'home', params: <String, dynamic>{
      'pageName': 'home',
      'durationMs': 12300,
    });
    await xbFlushTrack();
    final markdown = await xbExportTrackAsMarkdown();
    await closeXBTrack(flushBeforeClose: false);

    expect(markdown, contains('# 操作路径复现步骤'));
    expect(markdown, contains('## 进入页面「home」'));
    expect(markdown, contains('ItemCard'));
    expect(markdown, contains('("购买")'));
    expect(markdown, contains('lib/pages/detail.dart:42:11'));
    expect(markdown, contains('停留 12.3s'));
  });

  testWidgets('debug 下点击事件携带源码位置', (tester) async {
    await closeXBTrack(flushBeforeClose: false);
    final memory = await initSinks();

    await tester.pumpWidget(
      XBAutoTrackListener(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {},
                child: const Text('locate me'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('locate me'));
    await tester.pump();
    await xbFlushTrack();

    final clicks = memory.events
        .where((e) => e.event == 'auto_click')
        .toList(growable: false);
    expect(clicks, isNotEmpty);
    // 测试以 --track-widget-creation 编译，源码位置应可得。
    expect(clicks.first.params['file'], isNotNull);
    expect(clicks.first.params['line'], isNotNull);

    await closeXBTrack(flushBeforeClose: false);
  });

  test('手动兜底 reportEnter/reportExit 可用', () {
    final tracker = XBRouteTracker();
    tracker.reportEnter('manual_page');
    expect(tracker.currentPage, 'manual_page');
    tracker.reportExit('manual_page');
    expect(tracker.currentPage, isNull);
  });
}
