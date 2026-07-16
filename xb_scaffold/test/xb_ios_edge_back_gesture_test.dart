import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  testWidgets('indicator height stops growing at maxIndicatorHeight',
      (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: XBIosEdgeBackGesture(
            supportRightEdge: false,
            triggerDistance: 1000,
            triggerVelocity: double.infinity,
            maxDragOffset: 300,
            maxIndicatorHeight: 220,
            onBack: () {},
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      );

      final TestGesture gesture = await tester.startGesture(
        const Offset(1, 300),
      );
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();

      final Finder indicator = find.descendant(
        of: find.byType(XBIosEdgeBackGesture),
        matching: find.byType(Opacity),
      );
      expect(indicator, findsOneWidget);
      expect(tester.getSize(indicator).height, 182);

      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();

      expect(tester.getSize(indicator).height, 220);
      await gesture.cancel();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
