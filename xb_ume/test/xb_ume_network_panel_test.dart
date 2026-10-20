import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/plugins/network/xb_ume_network_plugin.dart';
import 'package:xb_ume/xb_ume.dart';

void main() {
  testWidgets('network detail shows initiator and jump action', (tester) async {
    final binding = XBUmeBinding.ensureInitialized(
      config: const XBUmeConfig(enable: true, persistenceEnabled: false),
    );
    final id = XBUmeNetworkReporter.begin(
      method: 'GET',
      url: Uri.parse('https://example.com/initiator'),
      sourceStackTrace: StackTrace.current,
    );
    XBUmeNetworkReporter.complete(id, statusCode: 200);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => XBUmeNetworkPlugin().buildPanel(
              context,
              binding.controller,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('example.com/initiator'));
    await tester.pumpAndSettle();

    expect(find.text('Network Detail'), findsOneWidget);
    expect(find.textContaining('发起位置:'), findsOneWidget);
    expect(find.text('跳转发起位置'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    binding.dispose();
  });
}
