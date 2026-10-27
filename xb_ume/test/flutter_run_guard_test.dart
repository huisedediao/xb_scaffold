// 「AI 再起一个 flutter run」的启动前体检：
// - 同设备 + 同目录已有 flutter run 时才提示（避免在手机上重装包顶掉 IDE 的会话）
// - 命令行解析与路径归一都是纯函数，可在不碰真实设备的情况下验证
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/flutter_run.dart';

void main() {
  group('parseFlutterRunDevice', () {
    test('识别 -d 与 --device-id 两种写法', () {
      expect(
        parseFlutterRunDevice(
            'dart ... flutter_tools.snapshot run -d 2LQ0224125000898 '
            '--target lib/main.dart'),
        '2LQ0224125000898',
      );
      expect(
        parseFlutterRunDevice('flutter_tools.snapshot run --device-id=macos'),
        'macos',
      );
    });

    test('没有显式设备时返回 null，不猜默认设备', () {
      expect(
        parseFlutterRunDevice(
            'flutter_tools.snapshot run --target lib/main.dart'),
        isNull,
      );
      expect(parseFlutterRunDevice('flutter_tools.snapshot run -d'), isNull);
    });
  });

  group('resolvePathForCompare', () {
    test('符号链接与尾部斜杠归一到同一路径', () {
      final dir = Directory.systemTemp.createTempSync('xbume_guard_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sub = Directory('${dir.path}/sub')..createSync();
      final link = Link('${dir.path}/link')..createSync(sub.path);
      expect(resolvePathForCompare(link.path),
          resolvePathForCompare(sub.path));
      expect(resolvePathForCompare('${sub.path}/'),
          resolvePathForCompare(sub.path));
    });

    test('不存在的路径回落到绝对路径而不是抛异常', () {
      final missing = '${Directory.systemTemp.path}/xbume_missing_dir';
      expect(resolvePathForCompare(missing), File(missing).absolute.path);
    });
  });
}
