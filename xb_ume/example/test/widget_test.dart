import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_analytics_plus/xb_analytics_plus.dart';
import 'package:xb_ume/xb_ume.dart';

import 'package:xb_ume_example/main.dart';

void main() {
  setUpAll(() async {
    XBUmeBinding.ensureInitialized(
      config: const XBUmeConfig(
        captureDebugPrint: false,
        captureFlutterError: false,
        capturePlatformError: false,
      ),
    );
    await initXBTrack(
      const XBTrackConfig(
        enableMemorySink: true,
        enableLocalStoreSink: false,
      ),
    );
  });

  tearDownAll(() async {
    await closeXBTrack(flushBeforeClose: false);
    XBUmeBinding.instance.dispose();
  });

  testWidgets('opens the XB Track debug page', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    final testPageButton = find.text('XB Analytics Locator Test');
    await tester.ensureVisible(testPageButton);
    await tester.tap(testPageButton);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('local-project-control-area')),
      findsOneWidget,
    );

    await tester.tap(find.text('Show third-party UI'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const ValueKey<String>('local-project-track-debug-wrapper'),
      ),
      findsOneWidget,
    );
    expect(find.text('XB Track Debug'), findsOneWidget);
    expect(find.text('Search by event or params'), findsOneWidget);
    expect(find.text('Local project UI'), findsOneWidget);
  });
}
