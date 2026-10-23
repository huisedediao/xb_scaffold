import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/src/core/xb_process_stats_smaps.dart';

/// 生成一条 smaps 映射块（字段单位 kB），模拟 Android / OHOS 的 /proc 格式。
String _block(
  String header, {
  int pss = 0,
  int privateClean = 0,
  int privateDirty = 0,
  int sharedClean = 0,
  int sharedDirty = 0,
}) {
  final size = pss + privateClean + privateDirty + sharedClean + sharedDirty;
  return '''
$header
  Size:                $size kB
  KernelPageSize:         4 kB
  MMUPageSize:            4 kB
  Rss:                 $size kB
  Pss:                 $pss kB
  Pss_Dirty:           $privateDirty kB
  Shared_Clean:        $sharedClean kB
  Shared_Dirty:        $sharedDirty kB
  Private_Clean:       $privateClean kB
  Private_Dirty:       $privateDirty kB
  Referenced:          $pss kB
  Anonymous:           $privateDirty kB
  VmFlags: rd wr mr mw me ac
''';
}

final String _sample = _block(
      '7f0000000000-7f0000001000 rw-p 00000000 00:00 0 [anon:dalvik-main space]',
      pss: 100,
      privateDirty: 100,
    ) +
    _block(
      '7f0000001000-7f0000002000 rw-p 00000000 00:00 0 [anon:libc_malloc]',
      pss: 200,
      privateDirty: 150,
      privateClean: 50,
    ) +
    _block(
      '7f0000002000-7f0000003000 r--p 00000000 fd:01 1 /system/lib64/libc.so',
      pss: 50,
      privateClean: 10,
      sharedClean: 40,
    ) +
    _block(
      '7f0000003000-7f0000004000 rw-p 00000000 00:00 0 [stack]',
      pss: 8,
      privateDirty: 8,
    ) +
    _block(
      '7f0000004000-7f0000005000 rw-s 00000000 00:00 0 /dev/kgsl-3d0',
      pss: 40,
      privateDirty: 40,
    ) +
    _block(
      '7f0000005000-7f0000006000 r--s 00000000 00:00 0 [anon:shared buffer]',
      pss: 60,
      sharedClean: 60,
    ) +
    _block(
      '7f0000006000-7f0000007000 r--s 00000000 fd:01 2 /system/fonts/Roboto.ttf',
      pss: 20,
      privateClean: 5,
      sharedClean: 15,
    );

void main() {
  group('parseSmapsEntries', () {
    test('parses mapping name and kB fields', () {
      final entries = parseSmapsEntries(_sample);
      expect(entries.length, 7);
      expect(entries.first.name, '[anon:dalvik-main space]');
      expect(entries.first.pss, 100 * 1024);
      expect(entries.first.privateDirty, 100 * 1024);
      expect(entries[1].name, '[anon:libc_malloc]');
      expect(entries[1].privateBytes, 200 * 1024);
      expect(entries[2].name, '/system/lib64/libc.so');
    });

    test('keeps spaces in name and tolerates empty input', () {
      final text = _block(
        '7f0000000000-7f0000001000 rw-p 00000000 00:00 0 [anon:dalvik-main space (region space)]',
        pss: 4,
        privateDirty: 4,
      );
      expect(parseSmapsEntries(text).single.name,
          '[anon:dalvik-main space (region space)]');
      expect(parseSmapsEntries(''), isEmpty);
      expect(parseSmapsEntries('garbage\nPss: 1 kB\n'), isEmpty);
    });
  });

  group('androidPssBreakdown', () {
    test('classifies like dumpsys meminfo app summary', () {
      final b = androidPssBreakdown(parseSmapsEntries(_sample))!;
      expect(b.total, 478 * 1024);
      expect(b.items['Java'], 100 * 1024);
      expect(b.items['Native'], 150 * 1024);
      // .so 10 kB + .ttf 5 kB 私有页。
      expect(b.items['Code'], 15 * 1024);
      expect(b.items['Stack'], 8 * 1024);
      expect(b.items['Graphics'], 40 * 1024);
      // System = TOTAL PSS - 全部私有页；Private Other 兜底余量。
      expect(b.items['System'], (478 - 363) * 1024);
      expect(b.items['Private Other'], (478 - 115 - 100 - 150 - 15 - 8 - 40) * 1024);
    });

    test('rows always sum to total PSS', () {
      final b = androidPssBreakdown(parseSmapsEntries(_sample))!;
      final sum = b.items.values.fold<int>(0, (a, v) => a + v);
      expect(sum, b.total);
    });

    test('empty or zero entries yield null', () {
      expect(androidPssBreakdown(const <XBUmeSmapsEntry>[]), isNull);
      expect(
          androidPssBreakdown(
              const <XBUmeSmapsEntry>[XBUmeSmapsEntry(name: 'x', pss: 0)]),
          isNull);
    });
  });

  group('ohosPssBreakdown', () {
    test('splits by DevEco memory lane types', () {
      final b = ohosPssBreakdown(parseSmapsEntries(_sample))!;
      expect(b.total, 478 * 1024);
      expect(b.items['Native Heap'], 200 * 1024);
      expect(b.items['Stack'], 8 * 1024);
      expect(b.items['GL/Graph'], 40 * 1024);
      expect(b.items['.so'], 50 * 1024);
      expect(b.items['.ttf'], 20 * 1024);
      // dalvik 映射在 OHOS 上归入 AnonPage Other（与共享 anon 合并）。
      expect(b.items['AnonPage Other'], 160 * 1024);
      final sum = b.items.values.fold<int>(0, (a, v) => a + v);
      expect(sum, b.total);
    });

    test('classifies file page and device mappings', () {
      final text = _block(
            '7f0000000000-7f0000001000 r--s 00000000 fd:01 1 /data/storage/el2/base/app.hap',
            pss: 10,
          ) +
          _block(
            '7f0000001000-7f0000002000 rw-s 00000000 00:00 0 /dev/ion',
            pss: 6,
          ) +
          _block(
            '7f0000002000-7f0000003000 r--s 00000000 fd:01 2 /data/app/res/data.bin',
            pss: 4,
          );
      final b = ohosPssBreakdown(parseSmapsEntries(text))!;
      expect(b.items['.hap'], 10 * 1024);
      expect(b.items['GL/Graph'], 6 * 1024);
      expect(b.items['FilePage Other'], 4 * 1024);
    });
  });
}
