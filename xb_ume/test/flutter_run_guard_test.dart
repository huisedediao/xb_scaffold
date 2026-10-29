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

  group('parseDescendantPids（Windows 停止时找 app 进程）', () {
    // Get-CimInstance Win32_Process | Select ProcessId,ParentProcessId | ConvertTo-Csv
    const csv = '\r\n'
        '"ProcessId","ParentProcessId"\r\n'
        '"100","10"\r\n' // cmd /c flutter.bat
        '"200","100"\r\n' // dart.exe（flutter_tools）
        '"300","200"\r\n' // app.exe
        '"400","11"\r\n'; // 另一棵树的进程

    test('递归到底：cmd → dart → app 都能取到', () {
      expect(parseDescendantPids(csv, 10), <int>[100, 200, 300]);
    });

    test('不含 root 自己，也不把别的树的进程算进来', () {
      final pids = parseDescendantPids(csv, 10);
      expect(pids, isNot(contains(10)));
      expect(pids, isNot(contains(400)));
      expect(parseDescendantPids(csv, 100), <int>[200, 300]);
      expect(parseDescendantPids(csv, 300), isEmpty);
    });

    test('表头与非数字行被跳过，不抛异常', () {
      expect(parseDescendantPids('garbage\n\n', 10), isEmpty);
    });
  });

  // 启动失败时 GUI 只拿到这一条摘要（详见输出面板）：必须取日志末尾，
  // 开头是预启动与编译进度，真正的原因（装包 / 端口转发）总在最后。
  group('launchFailureSummary', () {
    test('超长输出保留末尾，丢掉开头的进度噪声', () {
      final tail = <String>[
        '[pre-run] \$ bash scripts/dev_run.sh --prepare --mode debug',
        ...List<String>.filled(30, '正在编译（Hvigor assembleHap）…'),
        'Connect server failed',
        'Command: hdc -t 2LQ0224125000898 fport tcp:56181 tcp:41035',
      ];
      final s = launchFailureSummary(tail, max: 120);
      expect(s, startsWith('…'));
      expect(s, contains('fport tcp:56181'));
      expect(s, isNot(contains('pre-run')));
    });

    test('hdc 端口转发失败附可执行建议', () {
      final s = launchFailureSummary(const <String>[
        'Error waiting for a debug connection: ProcessException: hdc returned error:',
        'Connect server failed',
        '  Command: .../hdc -t X fport tcp:56181 tcp:41035',
      ]);
      expect(s, contains('Connect server failed'));
      expect(s, contains('hdc kill -r'));
    });

    test('其它失败不硬塞建议', () {
      const line = 'Gradle task assembleDebug failed';
      expect(launchFailureSummary(const <String>[line]), line);
      expect(launchFailureAdvice(line), isNull);
    });

    test('空输出不抛异常', () {
      expect(launchFailureSummary(const <String>[]), '');
    });
  });
}
