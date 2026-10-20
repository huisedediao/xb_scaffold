import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/ui/xb_ume_detail_scroll_content.dart';

void main() {
  // 桌面端（macOS/Windows/Linux）的 ScrollView 默认不继承 PrimaryScrollController，
  // 若 Scrollbar 不传 controller 而回退到 PrimaryScrollController，就会在帧回调里
  // 报 "The Scrollbar's ScrollController has no ScrollPosition attached."。
  testWidgets('桌面端详情滚动区域不触发 no ScrollPosition attached 断言', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: PrimaryScrollController(
            controller: ScrollController(),
            child: Scaffold(
              body: AlertDialog(
                content: SizedBox(
                  width: 400,
                  height: 120,
                  child: XBUmeDetailScrollContent(
                    child: SelectableText(List.filled(80, 'line').join('\n')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Scrollbar), findsWidgets);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
