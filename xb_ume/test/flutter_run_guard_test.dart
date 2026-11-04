// 「AI 再起一个 flutter run」的启动前体检：
// - 同设备 + 同目录已有 flutter run 时才提示（避免在手机上重装包顶掉 IDE 的会话）
// - 命令行解析与路径归一都是纯函数，可在不碰真实设备的情况下验证
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/bridge.dart';
import '../bin/src/device/flutter_run.dart';
import '../bin/src/device/process.dart';

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

    test('provider authority 冲突提示改 manifest 或卸载占用方', () {
      final s = launchFailureSummary(const <String>[
        "adb: failed to install app.apk: Failure [INSTALL_FAILED_CONFLICTING_PROVIDER: "
            'Can not install because provider name com.jf.jlink.fileProvider '
            '(in package com.jf.jlink) is already used by com.jf.jlinkiot]',
      ]);
      expect(s, contains('provider authority'));
      expect(s, contains('.xxx'));
      expect(s, contains('卸载'));
    });

    test('版本降级与存储不足各给一条建议', () {
      expect(
        launchFailureAdvice('Failure [INSTALL_FAILED_VERSION_DOWNGRADE]'),
        contains('versionCode'),
      );
      expect(
        launchFailureAdvice('Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]'),
        contains('存储不足'),
      );
    });

    test('空输出不抛异常', () {
      expect(launchFailureSummary(const <String>[]), '');
    });
  });

  // 实发：装包成功、app 已在手机上跑，只有 `hdc fport` 那一下报
  // 「Connect server failed」（hdc server 瞬时拒连）——这属于重试一次就好
  // 的抖动，不该让用户白等一次完整编译。
  group('isTransientHdcFailure + 自动重试', () {
    test('只认 hdc 拒连，编译错误不重试', () {
      expect(
        isTransientHdcFailure('hdc returned error:\nConnect server failed\n'),
        isTrue,
      );
      expect(isTransientHdcFailure('Gradle task assembleDebug failed'), isFalse);
      expect(isTransientHdcFailure('等待 VM service 超时（240s）'), isFalse);
    });

    test('拒连后自动重试一次，并带上说明', () async {
      final launcher = _FlakyLauncher(failures: 1);
      final r = await launcher.launch(device: 'ohos-device', timeout: const Duration(seconds: 1));
      expect(launcher.calls, 2);
      expect(r.pid, 4242);
      expect(r.note, contains('已自动重试'));
    });

    test('重试仍失败就把错误抛出去（不再循环）', () async {
      final launcher = _FlakyLauncher(failures: 5);
      await expectLater(
        launcher.launch(device: 'ohos-device', timeout: const Duration(seconds: 1)),
        throwsA(isA<DeviceCommandError>()),
      );
      expect(launcher.calls, 2);
    });

    test('非抖动失败不重试', () async {
      final launcher = _FlakyLauncher(failures: 1, message: 'Gradle task failed');
      await expectLater(
        launcher.launch(device: 'ohos-device'),
        throwsA(isA<DeviceCommandError>()),
      );
      expect(launcher.calls, 1);
    });
  });

  // 实发：GUI「日志」对每台设备常驻一个 `hdc -t <id> hilog`，旧版部署 kill -9
  // 后它成孤儿（PPID=1）并一直占着 hdc server 连接；攒够了 fport 就报
  //「Connect server failed」，表现为「app 装到手机上了，界面却没打印」。
  group('parseOrphanHdcLogClients', () {
    test('只认 PPID=1 的 hdc -t … hilog', () {
      const ps = '''
  PID  PPID ARGS
  100     1 hdc -t 2LQ0224125000898 hilog
  200     1 hdc -t 2LQ0224125000898 shell hilog -v time
  300  1000 hdc -t 2LQ0224125000898 hilog
  400     1 /opt/sdk/hdc -t 2LQ0224125000898 hilog
  500     1 hdc list targets
''';
      expect(parseOrphanHdcLogClients(ps), <int>[100, 400]);
    });

    test('空输出 / 无孤儿不抛异常', () {
      expect(parseOrphanHdcLogClients(''), isEmpty);
      expect(parseOrphanHdcLogClients('  123     1 /usr/bin/vim a.dart'), isEmpty);
    });
  });

  group('hdcPreflight', () {
    test('目标不是 hdc 设备就不动 hdc', () async {
      final trace = <String>[];
      final note = await hdcPreflight(
        'emulator-5554',
        ops: _fakeHdc(trace: trace, probes: <CmdResult>[_ok('2LQ0 device')]),
      );
      expect(note, isNull);
      expect(trace, isEmpty);
    });

    test('拒连时先回收孤儿，通了就不再重启 server', () async {
      final trace = <String>[];
      final note = await hdcPreflight(
        '2LQ0',
        assumeOhos: true,
        ops: _fakeHdc(trace: trace, orphans: <int>[11], probes: <CmdResult>[
          _timeout(),
          _ok('2LQ0'),
        ]),
      );
      expect(trace, <String>['kill:11']);
      expect(note, contains('回收 hdc 遗留日志客户端 1 个'));
      expect(note, isNot(contains('重启')));
    });

    test('回收后仍不通才重启 server，并说明', () async {
      final trace = <String>[];
      final note = await hdcPreflight(
        '2LQ0',
        assumeOhos: true,
        ops: _fakeHdc(trace: trace, probes: <CmdResult>[
          _timeout(),
          _timeout(),
          _ok('2LQ0'),
        ]),
      );
      expect(trace, <String>['restart']);
      expect(note, contains('hdc server 无响应，已自动重启'));
    });

    test('什么都没做就返回 null（日志流正常、hdc 健康）', () async {
      final trace = <String>[];
      final note = await hdcPreflight(
        '2LQ0',
        ops: _fakeHdc(trace: trace, probes: <CmdResult>[_ok('2LQ0 device')]),
      );
      expect(note, isNull);
      expect(trace, isEmpty);
    });
  });
}

CmdResult _ok(String out) => CmdResult(0, out, '');

CmdResult _timeout() => CmdResult(-1, '', 'timeout', timedOut: true);

/// 假 hdc：探测结果按 [probes] 顺序返回，[orphans] 是遗留客户端，[trace] 记副作用。
HdcOps _fakeHdc({
  required List<String> trace,
  required List<CmdResult> probes,
  List<int> orphans = const <int>[],
}) {
  var i = 0;
  return HdcOps(
    listTargets: (t) async =>
        probes[i < probes.length ? i++ : probes.length - 1],
    listOrphanPids: () async => orphans,
    killPid: (pid) {
      trace.add('kill:$pid');
      return true;
    },
    restartServer: () async => trace.add('restart'),
  );
}

/// 前 [failures] 次抛「Connect server failed」，之后返回一个假结果。
class _FlakyLauncher extends FlutterRunLauncher {
  _FlakyLauncher({required this.failures, this.message = ''});

  final int failures;
  final String message;
  int calls = 0;

  @override
  Future<LaunchResult> launchOnce({
    required String device,
    String? target,
    String? cwd,
    String? platform,
    bool waitVm = true,
    bool force = false,
    String owner = 'mcp',
    Duration timeout = const Duration(seconds: 180),
    String? retryNote,
    String? config,
    List<String> extraArgs = const <String>[],
  }) async {
    calls++;
    if (calls <= failures) {
      throw DeviceCommandError(
        'flutter-run',
        'flutter run',
        message.isEmpty
            ? 'hdc returned error:\nConnect server failed\n\n  Command: hdc -t X fport tcp:1 tcp:2'
            : message,
      );
    }
    return LaunchResult(
      pid: 4242,
      device: device,
      logPath: '/tmp/xb_ume_fake.log',
      wsUri: 'ws://127.0.0.1:1/token=/ws',
      note: retryNote,
    );
  }
}
