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

void _onBack() {}

void main() {
  test('defaults match the tuned gesture values', () {
    const XBIosEdgeBackGesture gesture = XBIosEdgeBackGesture(
      onBack: _onBack,
      child: SizedBox(),
    );

    expect(gesture.edgeWidth, 32);
    expect(gesture.triggerDistance, 25);
    expect(gesture.triggerVelocity, 644);
    expect(gesture.maxDragOffset, 25);
    expect(gesture.maxIndicatorHeight, 124);
    expect(gesture.indicatorRevealDistance, 46);
    expect(gesture.indicatorSlowdownStartProgress, 0);
    expect(gesture.iconSize, 16);
  });

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
            maxIndicatorHeight: 160,
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
      expect(tester.getSize(indicator).height, lessThan(160));
      expect(
        tester.widget<Icon>(find.byIcon(Icons.arrow_back_ios_new_rounded)).size,
        16,
      );

      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();

      expect(tester.getSize(indicator).height, 160);
      await gesture.cancel();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('indicator width never exceeds or shrinks back to maxDragOffset',
      (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: XBIosEdgeBackGesture(
            supportRightEdge: false,
            triggerDistance: 1000,
            triggerVelocity: double.infinity,
            maxDragOffset: 20,
            indicatorRevealDistance: 10,
            onBack: () {},
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      );

      final TestGesture gesture = await tester.startGesture(
        const Offset(1, 300),
      );
      final List<double> widths = <double>[];
      for (int i = 0; i < 3; i++) {
        await gesture.moveBy(i == 0 ? const Offset(10, 0) : const Offset(5, 0));
        await tester.pump();
        widths.add(tester.getSize(_indicatorFinder()).width);
      }

      expect(widths, everyElement(lessThanOrEqualTo(20)));
      expect(widths[1], greaterThanOrEqualTo(widths[0]));
      expect(widths[2], greaterThanOrEqualTo(widths[1]));
      expect(widths.last, moreOrLessEquals(20));

      await gesture.cancel();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('indicator growth slows progressively after configured start',
      (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: XBIosEdgeBackGesture(
            supportRightEdge: false,
            triggerDistance: 1000,
            triggerVelocity: double.infinity,
            maxDragOffset: 40,
            maxIndicatorHeight: 220,
            indicatorRevealDistance: 100,
            indicatorSlowdownStartProgress: 0.6,
            onBack: () {},
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      );

      final TestGesture gesture = await tester.startGesture(
        const Offset(1, 300),
      );
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();

      final Finder indicator = _indicatorFinder();
      final List<Size> sizes = <Size>[tester.getSize(indicator)];
      for (int i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(10, 0));
        await tester.pump();
        sizes.add(tester.getSize(indicator));
      }

      final List<double> widthGrowth = <double>[
        for (int i = 1; i < sizes.length; i++)
          sizes[i].width - sizes[i - 1].width,
      ];
      final List<double> heightGrowth = <double>[
        for (int i = 1; i < sizes.length; i++)
          sizes[i].height - sizes[i - 1].height,
      ];

      for (int i = 1; i < widthGrowth.length; i++) {
        expect(widthGrowth[i], lessThan(widthGrowth[i - 1]));
        expect(heightGrowth[i], lessThan(heightGrowth[i - 1]));
      }
      expect(sizes.last.width, moreOrLessEquals(40));
      expect(sizes.last.height, moreOrLessEquals(220));

      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
      expect(tester.getSize(indicator), sizes.last);

      await gesture.cancel();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('slowdown start supports custom and fully linear values',
      (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      Future<Size> measureIndicator({
        required double slowdownStart,
        required double dragDistance,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: XBIosEdgeBackGesture(
              supportRightEdge: false,
              triggerDistance: 1000,
              triggerVelocity: double.infinity,
              maxDragOffset: 40,
              maxIndicatorHeight: 220,
              indicatorRevealDistance: 100,
              indicatorSlowdownStartProgress: slowdownStart,
              onBack: () {},
              child: const ColoredBox(color: Colors.white),
            ),
          ),
        );
        final TestGesture gesture = await tester.startGesture(
          const Offset(1, 300),
        );
        await gesture.moveBy(Offset(dragDistance, 0));
        await tester.pump();
        final Size size = tester.getSize(_indicatorFinder());
        await gesture.cancel();
        await tester.pump();
        return size;
      }

      final Size beforeCustomStart = await measureIndicator(
        slowdownStart: 0.8,
        dragDistance: 70,
      );
      expect(beforeCustomStart.width, moreOrLessEquals(28));
      expect(beforeCustomStart.height, moreOrLessEquals(141.4));

      final Size afterCustomStart = await measureIndicator(
        slowdownStart: 0.8,
        dragDistance: 90,
      );
      expect(afterCustomStart.width, moreOrLessEquals(35.5));
      expect(afterCustomStart.height, moreOrLessEquals(195.25));

      final Size fullyLinear = await measureIndicator(
        slowdownStart: 1,
        dragDistance: 90,
      );
      expect(fullyLinear.width, moreOrLessEquals(36));
      expect(fullyLinear.height, moreOrLessEquals(198));
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
