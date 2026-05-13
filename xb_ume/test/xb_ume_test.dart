import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/xb_ume.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initialize with default plugins (all enabled)', () {
    final binding = XBUmeBinding.ensureInitialized(
      config: const XBUmeConfig(enable: true, persistenceEnabled: false),
    );

    final ids = binding.controller.plugins.map((p) => p.id).toSet();
    expect(ids, contains('console'));
    expect(ids, contains('route'));
    expect(ids, contains('performance'));
    expect(ids, contains('network'));
    expect(ids, contains('inspector'));
    expect(ids, contains('widget_locator'));
    expect(ids, contains('device'));
    expect(ids, contains('storage'));
    expect(ids.length, 8);

    binding.dispose();
  });

  test('disable all default plugins via config booleans', () {
    final binding = XBUmeBinding.ensureInitialized(
      config: const XBUmeConfig(
        enable: true,
        persistenceEnabled: false,
        enableConsole: false,
        enableRoute: false,
        enablePerformance: false,
        enableNetwork: false,
        enableInspector: false,
        enableWidgetLocator: false,
        enableDevice: false,
        enableStorage: false,
      ),
    );

    expect(binding.controller.plugins, isEmpty);

    binding.dispose();
  });

  test('enable only specific plugins via config booleans', () {
    final binding = XBUmeBinding.ensureInitialized(
      config: const XBUmeConfig(
        enable: true,
        persistenceEnabled: false,
        enableConsole: true,
        enableRoute: false,
        enablePerformance: false,
        enableNetwork: true,
        enableInspector: false,
        enableWidgetLocator: false,
        enableDevice: false,
        enableStorage: true,
      ),
    );

    final ids = binding.controller.plugins.map((p) => p.id).toSet();
    expect(ids, contains('console'));
    expect(ids, contains('network'));
    expect(ids, contains('storage'));
    expect(ids.length, 3);

    binding.dispose();
  });

  test('copyWith preserves new plugin toggles', () {
    const base = XBUmeConfig(
      enableConsole: false,
      enableRoute: false,
    );
    expect(base.enableConsole, false);
    expect(base.enableRoute, false);
    expect(base.enablePerformance, true);

    final updated = base.copyWith(enableConsole: true, enableRoute: true);
    expect(updated.enableConsole, true);
    expect(updated.enableRoute, true);
    expect(updated.enablePerformance, true);
  });

  test('manual network reporter records request lifecycle', () {
    final binding = XBUmeBinding.ensureInitialized(
      config: const XBUmeConfig(enable: true, persistenceEnabled: false),
    );

    final requestId = XBUmeNetworkReporter.begin(
      method: 'GET',
      url: Uri.parse('https://example.com/path'),
      requestHeaders: {'token': 'abc'},
    );

    XBUmeNetworkReporter.complete(
      requestId,
      statusCode: 200,
      responseBody: {'ok': true},
    );

    final records = binding.controller.network;
    expect(records.isNotEmpty, true);
    expect(records.last.statusCode, 200);

    binding.dispose();
  });
}
