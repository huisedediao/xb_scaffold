import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

Finder _indicatorFinder() {
  return find.descendant(
    of: find.byType(XBIosEdgeBackGesture),
    matching: find.byWidgetPredicate(
      (Widget widget) => widget is Opacity && widget.child is Stack,
    ),
  );
}

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

      final Finder indicator = _indicatorFinder();
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

  testWidgets('indicator follows slow pointer movement before drag acceptance',
      (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: XBIosEdgeBackGesture(
            supportRightEdge: false,
            triggerDistance: 1000,
            triggerVelocity: double.infinity,
            indicatorRevealDistance: 40,
            onBack: () {},
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      );

      final TestGesture gesture = await tester.startGesture(
        const Offset(1, 300),
      );
      await tester.pump();

      final Finder indicator = _indicatorFinder();
      expect(indicator, findsOneWidget);
      expect(tester.getSize(indicator), Size.zero);
      expect(tester.widget<Opacity>(indicator).opacity, 0);

      await gesture.moveBy(const Offset(4, 20));
      await tester.pump();

      final Size firstSize = tester.getSize(indicator);
      expect(firstSize.width, greaterThan(0));
      expect(firstSize.height, greaterThan(0));
      expect(tester.getCenter(indicator).dy, moreOrLessEquals(320));
      expect(tester.widget<Opacity>(indicator).opacity, greaterThan(0));
      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);

      await gesture.moveBy(const Offset(4, 0));
      await tester.pump();

      final Size expandedSize = tester.getSize(indicator);
      expect(expandedSize.width, greaterThan(firstSize.width));
      expect(expandedSize.height, greaterThan(firstSize.height));

      await gesture.moveBy(const Offset(-6, 0));
      await tester.pump();

      final Size retractedSize = tester.getSize(indicator);
      expect(retractedSize.width, lessThan(expandedSize.width));
      expect(retractedSize.height, lessThan(expandedSize.height));

      await gesture.cancel();
      await tester.pump();
      expect(_indicatorFinder(), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('right edge indicator mirrors and follows pointer vertically',
      (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: XBIosEdgeBackGesture(
            supportLeftEdge: false,
            indicatorRevealDistance: 40,
            onBack: () {},
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      );

      final double rightEdge =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final TestGesture gesture = await tester.startGesture(
        Offset(rightEdge - 1, 300),
      );
      await gesture.moveBy(const Offset(-8, 15));
      await tester.pump();

      final Finder indicator = _indicatorFinder();
      expect(indicator, findsOneWidget);
      expect(tester.getTopRight(indicator).dx, moreOrLessEquals(rightEdge));
      expect(tester.getCenter(indicator).dy, moreOrLessEquals(315));

      await gesture.cancel();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
