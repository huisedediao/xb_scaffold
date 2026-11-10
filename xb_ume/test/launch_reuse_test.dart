// flutter run 复用底座（live_store + LaunchHandle）的单测：
// - 复用判定依赖的「命令行像不像 flutter run」纯函数
// - 清单读写 / 陈旧记录校验
// - FIFO 写 stdin（跨进程热重载的通道）
// 真实的「同设备同目录再启动一次 → reused」走 macOS example 端到端验证，
// 不在单测里起 flutter run（太慢且依赖设备）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/flutter_run.dart';
import '../bin/src/device/live_store.dart';

void main() {
  group('commandLooksLikeFlutterRun', () {
    test('flutter_tools.snapshot run 的各种真实命令行', () {
      expect(
        commandLooksLikeFlutterRun(
            '/opt/flutter/bin/cache/dart-sdk/bin/dart --disable-dart-dev '
            '/opt/flutter/bin/cache/flutter_tools.snapshot run -d macos'),
        isTrue,
      );
      expect(
        commandLooksLikeFlutterRun(
            'flutter_tools.snapshot run -d 2LQ0224125000898 --target lib/main.dart'),
        isTrue,
      );
    });

    test('Windows 的 flutter.bat run 也认', () {
      expect(
        commandLooksLikeFlutterRun(
            r'C:\Windows\system32\cmd.exe /d /s /c "C:\flutter\bin\flutter.bat run -d windows"'),
        isTrue,
      );
    });

    test('不是 run 子命令的不认（test / analyze / 空命令行）', () {
      expect(
        commandLooksLikeFlutterRun(
            'dart flutter_tools.snapshot test test/foo_test.dart'),
        isFalse,
      );
      expect(
        commandLooksLikeFlutterRun('dart flutter_tools.snapshot analyze'),
        isFalse,
      );
      expect(commandLooksLikeFlutterRun('flutter_tools.snapshot'), isFalse);
      expect(commandLooksLikeFlutterRun(''), isFalse);
      expect(commandLooksLikeFlutterRun('node server.js'), isFalse);
    });
  });

  group('isReleaseRunArgs', () {
    test('认 --release（含两侧空白），不误伤 --profile / --flavor', () {
      expect(isReleaseRunArgs(<String>['--release']), isTrue);
      expect(
        isReleaseRunArgs(<String>['--flavor', 'cn', ' --release ']),
        isTrue,
      );
      expect(isReleaseRunArgs(<String>['--profile']), isFalse);
      expect(isReleaseRunArgs(<String>['--flavor', 'cn']), isFalse);
      expect(isReleaseRunArgs(const <String>[]), isFalse);
      // 只认整参数：--release-notes 之类不能被当 release。
      expect(isReleaseRunArgs(<String>['--release-notes']), isFalse);
    });
  });

  group('LaunchRecord 序列化', () {
    test('toJson → fromJson 字段完整保留', () {
      final started = DateTime.parse('2026-10-28T10:00:00.000');
      final r = LaunchRecord(
        pid: 4321,
        device: 'macos',
        cwd: '/tmp/proj',
        startedAt: started,
        target: 'lib/main.dart',
        wsUri: 'http://127.0.0.1:54321/abc=/',
        logPath: '/tmp/launch/1-macos.log',
        fifo: '/tmp/launch/fifo-1',
        owner: 'gui',
      );
      final back = LaunchRecord.fromJson(r.toJson())!;
      expect(back.pid, 4321);
      expect(back.device, 'macos');
      expect(back.cwd, '/tmp/proj');
      expect(back.startedAt, started);
      expect(back.target, 'lib/main.dart');
      expect(back.wsUri, r.wsUri);
      expect(back.logPath, r.logPath);
      expect(back.fifo, r.fifo);
      expect(back.owner, 'gui');
    });

    test('vmless 能原样转回；老记录（没这个字段）按 false', () {
      LaunchRecord make({bool vmless = false}) => LaunchRecord(
            pid: 7,
            device: '26KUT23C26001579',
            cwd: '/tmp/proj',
            startedAt: DateTime.parse('2026-11-10T09:52:57.000'),
            vmless: vmless,
          );
      expect(LaunchRecord.fromJson(make(vmless: true).toJson())!.vmless, isTrue);
      expect(make().toJson()['vmless'], isFalse);
      final legacy = make().toJson()..remove('vmless');
      expect(LaunchRecord.fromJson(legacy)!.vmless, isFalse);
    });

    test('缺 pid / device / cwd 的记录视为坏数据', () {
      expect(LaunchRecord.fromJson(<String, Object?>{}), isNull);
      expect(
        LaunchRecord.fromJson(<String, Object?>{'pid': 1, 'device': 'macos'}),
        isNull,
      );
      expect(
        LaunchRecord.fromJson(
            <String, Object?>{'pid': 'not-int', 'device': 'macos', 'cwd': '/x'}),
        isNull,
      );
    });
  });

  group('清单读写', () {
    test('写入 → 读出 → 删除；坏 json 跳过', () {
      final tmp = Directory.systemTemp.createTempSync('xbume_live_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      writeLaunchRecord(
        LaunchRecord(
          pid: 111,
          device: 'macos',
          cwd: '/tmp/a',
          startedAt: DateTime.now(),
        ),
        dir: tmp.path,
      );
      writeLaunchRecord(
        LaunchRecord(
          pid: 222,
          device: 'ohos',
          cwd: '/tmp/b',
          startedAt: DateTime.now().add(const Duration(seconds: 1)),
        ),
        dir: tmp.path,
      );
      File('${tmp.path}/333.json').writeAsStringSync('{broken');
      File('${tmp.path}/notes.txt').writeAsStringSync('ignored');

      final list = readLaunchRecords(dir: tmp.path);
      expect(list.map((r) => r.pid), <int>[111, 222]); // 按启动时间升序
      expect(list.first.device, 'macos');

      removeLaunchRecord(111, dir: tmp.path);
      expect(readLaunchRecords(dir: tmp.path).map((r) => r.pid), <int>[222]);
    });
  });

  group('进程校验', () {
    test('pidAlive：自己活着，不存在的 pid 为 false', () {
      expect(pidAlive(pid), isTrue);
      expect(pidAlive(99999999), isFalse);
      expect(pidAlive(1), isFalse); // 0/1 直接拒绝
    });

    test('recordStillValid：当前测试进程不是 flutter run', () {
      final r = LaunchRecord(
        pid: pid,
        device: 'macos',
        cwd: Directory.current.path,
        startedAt: DateTime.now(),
      );
      // macOS/Linux 上能读到命令行（dart ...test）；Windows 只信 pid 存活。
      if (!Platform.isWindows) {
        expect(recordStillValid(r), isFalse);
      }
    });
  });

  group('FIFO', () {
    test('createLaunchFifo 出的管道能被写入（跨进程热重载通道）', () async {
      if (Platform.isWindows) return;
      final fifo = createLaunchFifo();
      expect(fifo, isNotNull);
      addTearDown(() => removeLaunchFifo(fifo));

      // 模拟 flutter run：读写方式打开（3<>）持续读 stdin，不会因写端关闭而 EOF。
      final reader = await Process.start(
        'sh',
        <String>['-c', r'exec 3<>"$1"; exec cat <&3 > /dev/null', 'sh', fifo!],
      );
      addTearDown(reader.kill);

      expect(await writeLaunchFifo(fifo, 'r\n'), isTrue);
      // FIFO 可重复写：多次热重载都走同一条管道。
      expect(await writeLaunchFifo(fifo, 'R\n'), isTrue);
      await writeLaunchFifo(fifo, 'r\n');
    });

    test('路径不存在时写 FIFO 返回 false，不抛异常', () async {
      expect(await writeLaunchFifo('/tmp/xbume_no_such_fifo_9527', 'r\n'),
          isFalse);
    });
  });

  group('LaunchResult', () {
    test('reused 默认 false，可显式标记', () {
      final fresh = LaunchResult(pid: 1, device: 'macos', logPath: '/tmp/a.log');
      expect(fresh.reused, isFalse);
      final reused = LaunchResult(
        pid: 1,
        device: 'macos',
        logPath: '/tmp/a.log',
        wsUri: 'http://127.0.0.1:1/',
        reused: true,
      );
      expect(reused.reused, isTrue);
    });

    test('LaunchHandle 认领来的进程没有 Process 句柄', () {
      final h = LaunchHandle(
        pid: 123,
        device: 'macos',
        target: null,
        logPath: '/tmp/a.log',
        startedAt: DateTime.now(),
        cwd: '/tmp/proj',
        adopted: true,
        owner: 'gui',
      );
      expect(h.process, isNull);
      expect(h.adopted, isTrue);
      expect(h.owner, 'gui');
      h.dispose();
    });
  });
}
