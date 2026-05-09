import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xb_analytics_plus/xb_analytics_plus.dart';

void main() {
  tearDown(() async {
    await closeXBTrack(flushBeforeClose: false);
  });

  test('track and export json', () async {
    await initXBTrack(
      const XBTrackConfig(
        enableLocalStoreSink: false,
        enableMemorySink: true,
        flushBatchSize: 1,
      ),
    );

    xbSetTrackUser('u1');
    xbTrack('demo_event', params: {'k': 'v'});
    await xbFlushTrack();

    final jsonText = await xbExportTrackAsJson();
    final decoded = jsonDecode(jsonText);
    expect(decoded, isA<List>());
    final list = decoded as List;
    expect(list.isNotEmpty, true);
    expect(list.last['event'], 'demo_event');
    expect(list.last['userId'], 'u1');
  });

  test('sensitive key is masked', () async {
    await initXBTrack(
      const XBTrackConfig(
        enableLocalStoreSink: false,
        enableMemorySink: true,
        flushBatchSize: 1,
      ),
    );

    xbTrack('login', params: {'password': 'abc123'});
    await xbFlushTrack();

    final jsonText = await xbExportTrackAsJson();
    final decoded = jsonDecode(jsonText) as List;
    final params = decoded.last['params'] as Map<String, dynamic>;
    expect(params['password'], '***');
  });
}
