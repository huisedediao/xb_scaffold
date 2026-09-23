import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_analytics_plus/xb_analytics_plus.dart';

import 'package:xb_analytics_plus_example/main.dart';

void main() {
  testWidgets('demo app 首页冒烟测试', (WidgetTester tester) async {
    // 先初始化（禁用本地存储与定时器），避免 Manager 以默认配置自举产生
    // path_provider IO 调用与挂起 Timer（见设计文档第七节第 7 条）。
    await closeXBTrack(flushBeforeClose: false);
    await initXBTrack(
      const XBTrackConfig(
        enabled: true,
        enableConsoleSink: false,
        enableMemorySink: true,
        enableLocalStoreSink: false,
        flushInterval: Duration(hours: 1),
      ),
    );

    final routeTracker = XBRouteTracker();

    await tester.pumpWidget(
      XBAutoTrackListener(
        config: const XBAutoTrackConfig(blacklist: <String>['XBUme']),
        child: MyApp(routeTracker: routeTracker),
      ),
    );
    await tester.pumpAndSettle();

    // 首页关键元素在位。
    expect(find.text('Track Increment'), findsOneWidget);
    expect(find.text('Open Timeline Page'), findsOneWidget);
    // 路由观察者已记录首页。
    expect(routeTracker.currentPage, 'home');

    // 先卸载应用树（dispose 里的 xbTrackPageLeave 需在 config 失效前发出），
    // 再 close，避免 dispose 时的 track 以默认配置自举产生挂起 Timer。
    await tester.pumpWidget(const SizedBox());
    await closeXBTrack(flushBeforeClose: false);
  });
}
