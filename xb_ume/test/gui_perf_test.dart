import 'package:flutter_test/flutter_test.dart';

import '../bin/src/perf/perf_metrics.dart' as gui;

void main() {
  group('perfCpuFromSamples', () {
    test('counts busy samples over the window', () {
      final samples = <Map<String, Object?>>[
        for (var i = 0; i < 10; i++) <String, Object?>{'vmTag': 'GC New'},
        for (var i = 0; i < 10; i++) <String, Object?>{'vmTag': 'GC Old'},
        for (var i = 0; i < 380; i++) <String, Object?>{'vmTag': 'Dart'},
        for (var i = 0; i < 100; i++) <String, Object?>{'vmTag': 'Idle'},
      ];
      final r = gui.perfCpuFromSamples(<String, Object?>{
        'samplePeriod': 1000,
        'timeExtentMicros': 1000000,
        'samples': samples,
      });
      expect(r['samples'], 500);
      expect(r['idle'], 100);
      expect(r['gc'], 20);
      expect(r['busy'], 400);
      expect(r['percent'], 40.0);
    });

    test('clamps busy ratio to 100%', () {
      final samples = <Map<String, Object?>>[
        for (var i = 0; i < 2000; i++) <String, Object?>{'vmTag': 'Dart'},
      ];
      final r = gui.perfCpuFromSamples(<String, Object?>{
        'samplePeriod': 1000,
        'timeExtentMicros': 1000000,
        'samples': samples,
      });
      expect(r['percent'], 100.0);
    });

    test('missing samples or extent degrades to zero', () {
      final r = gui.perfCpuFromSamples(<String, Object?>{});
      expect(r['percent'], 0.0);
      expect(r['samples'], 0);
      expect(r['periodUs'], 0);
    });
  });

  group('perfExtensionData', () {
    test('unwraps data map', () {
      final r = gui.perfExtensionData(<String, Object?>{
        'type': 'ExtensionData',
        'data': <String, Object?>{'supported': true, 'cpuPercent': 12.5},
      });
      expect(r?['cpuPercent'], 12.5);
    });

    test('decodes data json string', () {
      final r = gui.perfExtensionData(<String, Object?>{
        'data': '{"supported":true,"cpuPercent":3.2}',
      });
      expect(r?['supported'], true);
      expect(r?['cpuPercent'], 3.2);
    });

    test('accepts direct payload and rejects unknown shapes', () {
      expect(
          gui.perfExtensionData(<String, Object?>{'supported': false})
              ?['supported'],
          false);
      expect(gui.perfExtensionData(<String, Object?>{'type': 'Sentinel'}), isNull);
      expect(gui.perfExtensionData('oops'), isNull);
    });
  });

  group('perfProcessMemory', () {
    test('flattens root children sorted by size', () {
      final r = gui.perfProcessMemory(<String, Object?>{
        'root': <String, Object?>{
          'name': 'Process',
          'size': 300,
          'children': <Object?>[
            <String, Object?>{
              'name': 'Dart',
              'description': 'Dart heap',
              'size': 100,
            },
            <String, Object?>{
              'name': 'Flutter',
              'description': 'Flutter engine',
              'size': 200,
            },
            <String, Object?>{'name': 'Empty', 'description': '', 'size': 0},
          ],
        },
      });
      expect(r['rss'], 300);
      expect(r['name'], 'Process');
      final items = r['items'] as List;
      expect(items.length, 2);
      expect((items.first as Map)['name'], 'Flutter');
      expect((items.last as Map)['name'], 'Dart');
    });

    test('appends remainder row when children do not cover total', () {
      // macOS 只回一个 Dart VM 分桶，其余常驻内存要补成「其他」行。
      final r = gui.perfProcessMemory(<String, Object?>{
        'root': <String, Object?>{
          'name': 'Process',
          'size': 500,
          'children': <Object?>[
            <String, Object?>{'name': 'Dart VM', 'size': 200},
          ],
        },
      });
      final items = r['items'] as List;
      expect(items.length, 2);
      expect((items.last as Map)['name'], '其他');
      expect((items.last as Map)['size'], 300);
    });

    test('missing root reports error', () {
      final r = gui.perfProcessMemory(<String, Object?>{});
      expect(r['error'], '进程内存不可用');
    });

    test('non-positive root size yields null rss', () {
      final r = gui.perfProcessMemory(<String, Object?>{
        'root': <String, Object?>{'name': 'Process', 'size': -1},
      });
      expect(r['rss'], isNull);
      expect(r['items'], isEmpty);
    });
  });
}
