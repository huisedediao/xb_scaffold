import 'package:flutter_test/flutter_test.dart';

import '../bin/ide_gui.dart' as gui;

void main() {
  group('parseAdbDevices', () {
    test('解析多设备（含 model 与状态）', () {
      const out = '''
* daemon not running; starting now at tcp:5037
List of devices attached
 emulator-5554          device product:sdk_gphone64_x86_64 model:Sdk_Gphone64_X86_64 device:emu64xa
 8ABCD123E              device product:foo model:Pixel_8 device:bar
 0123456789ABCDEF       unauthorized usb:1-1
''';
      final devices = gui.parseAdbDevices(out);
      expect(devices, hasLength(3));
      expect(devices[0]['id'], 'emulator-5554');
      expect(devices[0]['name'], 'Sdk_Gphone64_X86_64');
      expect(devices[0]['state'], 'device');
      expect(devices[0]['platform'], 'android');
      expect(devices[1]['name'], 'Pixel_8');
      expect(devices[2]['state'], 'unauthorized');
    });

    test('空输出与表头行被忽略', () {
      expect(gui.parseAdbDevices(''), isEmpty);
      expect(gui.parseAdbDevices('List of devices attached\n'), isEmpty);
    });
  });

  group('parseHdcTargets', () {
    test('解析设备 key，忽略空行与错误行', () {
      const out = '''
127.0.0.1:5555
[Fail] connect error

COM123
''';
      expect(gui.parseHdcTargets(out), <String>['127.0.0.1:5555', 'COM123']);
    });
  });

  group('parseBootedSimulators', () {
    test('解析已启动模拟器（名称 + UDID）', () {
      const out = '''
== Devices ==
    iPhone 15 Pro (3F2A1B2C-1234-5678-9ABC-DEF012345678) (Booted)
    iPad Pro (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) (Booted)
    iPhone SE (11111111-2222-3333-4444-555555555555) (Shutdown)
''';
      final sims = gui.parseBootedSimulators(out);
      expect(sims, hasLength(2));
      expect(sims[0]['name'], 'iPhone 15 Pro');
      expect(sims[0]['udid'], '3F2A1B2C-1234-5678-9ABC-DEF012345678');
      expect(sims[1]['name'], 'iPad Pro');
    });
  });

  group('parseIdeviceIds', () {
    test('提取 UDID，忽略短行', () {
      const out = '''
00008101-000A2B3C4D5E6F70
00008101-000112233445566

short
''';
      expect(
        gui.parseIdeviceIds(out),
        <String>['00008101-000A2B3C4D5E6F70', '00008101-000112233445566'],
      );
    });
  });

  group('parseLogcatLine', () {
    test('解析 logcat -v time 标准行', () {
      final entry = gui.parseLogcatLine(
        '10-12 14:23:01.123  D/Flutter( 1234): hello world',
      );
      expect(entry, isNotNull);
      expect(entry!['ts'], '10-12 14:23:01.123');
      expect(entry['level'], 'D');
      expect(entry['tag'], 'Flutter');
      expect(entry['msg'], 'hello world');
    });

    test('非标准行返回 null', () {
      expect(gui.parseLogcatLine('--------- beginning of main'), isNull);
    });
  });

  group('parseHilogLine', () {
    test('解析 hilog 标准行', () {
      final entry = gui.parseHilogLine(
        '01-01 08:00:00.000  1234  5678 I C01800/MyTag: message body',
      );
      expect(entry, isNotNull);
      expect(entry!['level'], 'I');
      expect(entry['tag'], 'C01800/MyTag');
      expect(entry['msg'], 'message body');
    });
  });

  group('parseIosLogLine', () {
    test('解析 idevicesyslog 行', () {
      final entry = gui.parseIosLogLine(
        'Oct 12 14:23:01  MyApp[1234] <Notice>: launched',
      );
      expect(entry, isNotNull);
      expect(entry!['level'], 'I');
      expect(entry['tag'], 'MyApp');
      expect(entry['msg'], 'launched');
    });

    test('解析 simctl log stream compact 行（Error 级别）', () {
      final entry = gui.parseIosLogLine(
        '2026-10-12 14:23:01.123456-0700  MyApp[1234:5678] [Error] boom',
      );
      expect(entry, isNotNull);
      expect(entry!['level'], 'E');
      expect(entry['msg'], 'boom');
    });

    test('未知行返回 null', () {
      expect(gui.parseIosLogLine('random text'), isNull);
    });
  });

  group('makeLogEntry', () {
    test('logcat 来源解析失败时保留原文兜底', () {
      final entry = gui.makeLogEntry('--------- beginning of main', 'logcat');
      expect(entry['level'], 'I');
      expect(entry['tag'], 'logcat');
      expect(entry['msg'], '--------- beginning of main');
      expect(entry['source'], 'logcat');
    });

    test('flutter 来源不做行解析，原文直出', () {
      final entry = gui.makeLogEntry('I/flutter (1234): hi', 'flutter');
      expect(entry['msg'], 'I/flutter (1234): hi');
      expect(entry['source'], 'flutter');
    });
  });
}
