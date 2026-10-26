// 设备层输出解析单测：用真实命令的样本输出锁定解析行为。
//
// 覆盖：adb devices -l / adb logcat -b crash / hdc list targets /
// xcrun simctl list devices --json / 按键别名。
library;

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/adb.dart';
import '../bin/src/device/bridge.dart';
import '../bin/src/device/hdc.dart';
import '../bin/src/device/simctl.dart';

void main() {
  group('adb devices -l', () {
    test('解析在线与未授权设备', () {
      const raw = '''
List of devices attached
emulator-5554          device product:sdk_gphone64_x86_64 model:sdk_gphone64_x86_64 device:emu64xa transport_id:1
R58M12345AB            unauthorized usb:1-2 transport_id:2
''';
      final list = parseAdbDevices(raw);
      expect(list, hasLength(2));
      expect(list[0].id, 'emulator-5554');
      expect(list[0].state, 'device');
      expect(list[0].model, 'sdk_gphone64_x86_64');
      expect(list[0].platform, 'android');
      expect(list[0].usable, isTrue);
      expect(list[1].id, 'R58M12345AB');
      expect(list[1].state, 'unauthorized');
      expect(list[1].usable, isFalse);
    });

    test('空列表不产生设备', () {
      expect(parseAdbDevices('List of devices attached\n\n'), isEmpty);
    });
  });

  group('adb logcat -b crash', () {
    // 真实 `logcat -d` 是旧的在前（时间递增），解析后应反转为新的在前。
    const raw = '''
--------- beginning of crash
10-26 17:00:00.001  4321  4321 E AndroidRuntime: FATAL EXCEPTION: main
10-26 17:00:00.002  4321  4321 E AndroidRuntime: Process: com.other.app, PID: 4321
10-26 17:00:00.003  4321  4321 E AndroidRuntime: java.lang.NullPointerException

10-26 18:00:00.123  1234  1234 E AndroidRuntime: FATAL EXCEPTION: main
10-26 18:00:00.124  1234  1234 E AndroidRuntime: Process: com.example.demo, PID: 1234
10-26 18:00:00.125  1234  1234 E AndroidRuntime: java.lang.IllegalStateException: boom
10-26 18:00:00.126  1234  1234 E AndroidRuntime: \tat com.example.demo.Main.main(Main.java:1)
''';

    test('每个 FATAL EXCEPTION 一条，新的在前', () {
      final list = parseAndroidCrashLog(raw);
      expect(list, hasLength(2));
      expect(list[0].report.id, 'c0');
      expect(list[0].report.package, 'com.example.demo');
      expect(list[0].report.title, contains('IllegalStateException'));
      expect(list[0].report.time?.hour, 18);
      expect(list[1].report.id, 'c1');
      expect(list[1].report.package, 'com.other.app');
      expect(list[0].raw, contains('Main.java:1'));
    });

    test('按 packageId 过滤', () {
      final list = parseAndroidCrashLog(raw, packageId: 'com.other.app');
      expect(list, hasLength(1));
      expect(list.single.report.package, 'com.other.app');
    });

    test('空日志返回空', () {
      expect(parseAndroidCrashLog(''), isEmpty);
    });
  });

  group('hdc list targets', () {
    test('跳过 [Empty] 占位行', () {
      const raw = '''
7001005458323933328XXXXX
127.0.0.1:5555
[Empty]
''';
      final list = parseHdcTargets(raw);
      expect(list, hasLength(2));
      expect(list[0].id, '7001005458323933328XXXXX');
      expect(list[0].platform, 'harmonyos');
      expect(list[0].usable, isTrue);
      expect(list[1].id, '127.0.0.1:5555');
    });
  });

  group('xcrun simctl list devices --json', () {
    const raw = '''
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-17-2" : [
      {"udid":"AAA-111","name":"iPhone 15 Pro","state":"Shutdown","isAvailable":true},
      {"udid":"BBB-222","name":"iPhone 15","state":"Booted","isAvailable":true}
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-16-4" : [
      {"udid":"CCC-333","name":"iPhone 8","state":"Shutdown","isAvailable":false}
    ]
  }
}
''';

    test('解析 udid/状态/iOS 版本，Booted 优先', () {
      final list = parseSimctlDevices(raw);
      expect(list, hasLength(3));
      expect(list.first.id, 'BBB-222');
      expect(list.first.state, 'Booted');
      expect(list.first.osVersion, 'iOS 17.2');
      expect(list[1].usable, isFalse); // Shutdown
      final unavailable = list.firstWhere((d) => d.id == 'CCC-333');
      expect(unavailable.state, 'unavailable');
      expect(unavailable.osVersion, 'iOS 16.4');
    });

    test('坏 JSON 返回空而不抛', () {
      expect(parseSimctlDevices('not json'), isEmpty);
    });
  });

  group('按键解析', () {
    test('名称与常见别名', () {
      expect(parseDeviceKey('back'), DeviceKey.back);
      expect(parseDeviceKey('Vol-Up'), DeviceKey.volumeUp);
      expect(parseDeviceKey('recent'), DeviceKey.appSwitch);
      expect(parseDeviceKey('backspace'), DeviceKey.delete);
      expect(parseDeviceKey('nope'), isNull);
    });

    test('每个枚举都能解析回自身', () {
      for (final k in DeviceKey.values) {
        expect(parseDeviceKey(k.name), k);
      }
    });
  });
}
