// 会话自检（xbume_session_check）：
// - 判定是纯函数：给定探测信号就能算出结论，测试不碰进程与网络；
// - 通道选路是纯函数：pid / 平台 → signal / stdin / none；
// - 工具必须挂在 core 组，否则 AI 默认拿不到它。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/flutter_run.dart';
import '../bin/src/mcp/session_check.dart';
import '../bin/src/mcp/tools.dart';

/// 一条正常的 live 记录（默认 pid 用当前进程，保证 pidAlive 为真）。
LaunchHandle _handle({
  int? fakePid,
  String cwd = '/tmp/proj',
  String? config,
  bool adopted = false,
  String owner = 'gui',
  Process? process,
}) =>
    LaunchHandle(
      pid: fakePid ?? pid,
      device: '26KUT23C26001579',
      target: 'lib/main.dart',
      logPath: '/tmp/x.log',
      startedAt: DateTime(2026, 11, 4),
      cwd: cwd,
      config: config,
      process: process,
      adopted: adopted,
      owner: owner,
    );

/// 全能力都通的信号基线。
SessionSignals _ok({ReloadChannel channel = ReloadChannel.signal}) =>
    SessionSignals(
      source: 'adb:26KUT23C26001579#port:54110',
      channel: channel,
      launcherCwd: '/tmp/proj',
      launcherDevice: '26KUT23C26001579',
      launcherOwner: 'gui',
      inspector: true,
      perf: true,
      evalOk: true,
      libraries: 5397,
      reloadVerified: true,
    );

void main() {
  group('来源解析', () {
    test('从 source 里取设备序列号，纯端口来源返回 null', () {
      expect(serialFromSource('adb:26KUT23C26001579#port:54110'),
          '26KUT23C26001579');
      expect(serialFromSource('hdc:2LQ0224125000898#port:41000'),
          '2LQ0224125000898');
      expect(serialFromSource('idevice:00008101#port:5000'), '00008101');
      // GUI/MCP 直接扫端口时没有设备前缀：不猜。
      expect(serialFromSource('port:54110'), isNull);
      expect(serialFromSource('adb:#port:54110'), isNull);
      expect(serialFromSource('weird:54110'), isNull);
    });
  });

  group('热重载通道', () {
    test('信号参数：USR1 热重载、USR2 热重启', () {
      expect(reloadSignalArgs(81728, restart: false),
          <String>['-USR1', '81728']);
      expect(reloadSignalArgs(81728, restart: true),
          <String>['-USR2', '81728']);
    });

    test('pid 非法 / 已退出 → none；本机 POSIX 存活 → signal', () {
      // SIGUSR1 对普通进程是终止信号，pid<=1 绝不能发。
      expect(reloadChannelOf(_handle(fakePid: 1)), ReloadChannel.none);
      expect(reloadChannelOf(_handle(fakePid: 0)), ReloadChannel.none);
      // 一个几乎不可能存在的 pid：进程不在就不发信号。
      expect(reloadChannelOf(_handle(fakePid: 999999)), ReloadChannel.none);
      if (!Platform.isWindows) {
        expect(reloadChannelOf(_handle()), ReloadChannel.signal);
      }
    });

    test('线上标记固定为 signal / stdin / none', () {
      expect(reloadChannelName(ReloadChannel.signal), 'signal');
      expect(reloadChannelName(ReloadChannel.stdin), 'stdin');
      expect(reloadChannelName(ReloadChannel.none), 'none');
    });
  });

  group('判定：先连得上，再是不是我要的，最后能不能改', () {
    test('VM 连不上 → stale，且不再评估能力', () {
      final j = judgeSession(const SessionSignals(
        source: 'adb:X#port:1',
        channel: ReloadChannel.signal,
        vmError: 'WebSocketException: 连接被拒绝',
      ));
      expect(j.verdict, SessionVerdict.stale);
      expect(j.usable, isFalse);
      expect(j.warnings.first, contains('VM service 连不上'));
      expect(j.next, contains(contains('refresh')));
    });

    test('设备不对 → wrong_device（热重载会打错包，必须停手）', () {
      final j = judgeSession(const SessionSignals(
        source: 'adb:26KUT23C26001579#port:54110',
        channel: ReloadChannel.signal,
        expectDevice: '2LQ0224125000898',
        inspector: true,
        evalOk: true,
        reloadVerified: true,
      ));
      expect(j.verdict, SessionVerdict.wrongDevice);
      expect(j.usable, isFalse);
      expect(j.warnings.first, contains('2LQ0224125000898'));
      expect(j.next.first, contains('不要继续操作'));
    });

    test('GUI 拉的会话只有 port:，设备号从 live 记录兜底后能判出来', () {
      final j = judgeSession(const SessionSignals(
        source: 'port:54110',
        channel: ReloadChannel.signal,
        expectDevice: '2LQ0224125000898',
        launcherDevice: '26KUT23C26001579',
        inspector: true,
        evalOk: true,
        reloadVerified: true,
      ));
      expect(j.verdict, SessionVerdict.wrongDevice);
      expect(j.warnings.first, contains('26KUT23C26001579'));
    });

    test('项目不对 → wrong_project（可识别符号链接与尾斜杠差异）', () {
      final same = judgeSession(const SessionSignals(
        source: 'adb:X#port:1',
        channel: ReloadChannel.signal,
        expectCwd: '/tmp/proj/',
        launcherCwd: '/tmp/proj',
        inspector: true,
        evalOk: true,
        reloadVerified: true,
      ));
      expect(same.verdict, isNot(SessionVerdict.wrongProject));

      final diff = judgeSession(const SessionSignals(
        source: 'adb:X#port:1',
        channel: ReloadChannel.signal,
        expectCwd: '/tmp/other',
        launcherCwd: '/tmp/proj',
        inspector: true,
        evalOk: true,
        reloadVerified: true,
      ));
      expect(diff.verdict, SessionVerdict.wrongProject);
      expect(diff.usable, isFalse);
    });

    test('没有通道 → ready_no_reload：能看能点，但改代码不能靠本工具', () {
      final j = judgeSession(_ok(channel: ReloadChannel.none));
      expect(j.verdict, SessionVerdict.readyNoReload);
      expect(j.usable, isTrue);
      expect(j.warnings, contains(contains('没有热重载通道')));
      expect(j.next, contains(contains('force')));
    });

    test('通道实测失败 → degraded，并提示别用它下结论', () {
      final j = judgeSession(const SessionSignals(
        source: 'adb:X#port:1',
        channel: ReloadChannel.signal,
        launcherCwd: '/tmp/proj',
        inspector: true,
        evalOk: true,
        reloadVerified: false,
      ));
      expect(j.verdict, SessionVerdict.degraded);
      expect(j.usable, isTrue);
      expect(j.warnings, contains(contains('实测失败')));
    });

    test('inspector / 求值缺失 → degraded（release 包）', () {
      final j = judgeSession(const SessionSignals(
        source: 'adb:X#port:1',
        channel: ReloadChannel.signal,
        inspector: false,
        evalOk: false,
        reloadVerified: true,
      ));
      expect(j.verdict, SessionVerdict.degraded);
      expect(j.warnings.length, 2);
      expect(j.next, contains(contains('只读排查')));
    });

    test('全通 → ready，并给出重载级别建议', () {
      final j = judgeSession(_ok());
      expect(j.verdict, SessionVerdict.ready);
      expect(j.usable, isTrue);
      expect(j.warnings, isEmpty);
      expect(j.next.single, contains('hot_reload'));
      expect(j.next.single, contains('restart'));
    });
  });

  group('结论文本', () {
    test('describe 给出结论、四项能力、进程与下一步', () {
      final r = SessionCheckResult(
        sessionId: 's54110',
        port: 54110,
        source: 'adb:26KUT23C26001579#port:54110',
        app: 'com.jf.jlinkiot',
        judgement: judgeSession(_ok()),
        caps: const <String, Object?>{
          'eval': true,
          'inspector': true,
          'screenshot': true,
          'widgetTree': true,
          'perf': false,
          'reloadChannel': 'signal',
        },
        launcher: const <String, Object?>{
          'pid': 81728,
          'cwd': '/tmp/proj',
          'device': '26KUT23C26001579',
          'config': '(android cn)',
          'owner': 'gui',
          'adopted': true,
          'label': 'gui认领·可热重载(signal)',
        },
        libraries: 5397,
        probe: const ReloadProbe(
          ok: true,
          message: 'No changes detected',
          elapsedMs: 1909,
          channel: 'signal',
        ),
      );
      final text = r.describe();
      expect(text, contains('s54110'));
      expect(text, contains('gui认领·可热重载(signal)'));
      expect(text, contains('结论 ready'));
      expect(text, contains('可重载（signal，实测 ✓ 1909ms）'));
      expect(text, contains('5397 库'));
      expect(text, contains('pid 81728'));
      expect(text, contains('配置 (android cn)'));
      expect(r.toJson()['verdict'], 'ready');
      expect(r.toJson()['usable'], isTrue);
      expect((r.toJson()['reloadProbe'] as Map)['ok'], isTrue);
    });

    test('没有 live 记录时如实说「拿不到句柄」，不假装能重载', () {
      final r = SessionCheckResult(
        sessionId: 's1',
        port: 1,
        source: 'port:1',
        app: '',
        judgement: judgeSession(const SessionSignals(
          source: 'port:1',
          channel: ReloadChannel.none,
          inspector: true,
          evalOk: true,
        )),
        caps: const <String, Object?>{
          'eval': true,
          'inspector': true,
          'reloadChannel': 'none',
        },
      );
      final text = r.describe();
      expect(text, contains('没有 live 记录'));
      expect(text, contains('可重载 ✗'));
      // 没发实测就不冒充测过：不能出现「实测 ✓」。
      expect(text, isNot(contains('实测 ✓')));
    });
  });

  group('MCP 接线', () {
    test('xbume_session_check 挂在 core 组，schema 带设备/项目/实测开关', () {
      final tool =
          coreTools().firstWhere((t) => t.name == 'xbume_session_check');
      expect(tool.title, contains('自检'));
      final props =
          (tool.inputSchema['properties'] as Map).cast<String, Object?>();
      expect(props.keys,
          containsAll(<String>['sessionId', 'deviceId', 'cwd', 'verifyReload']));
      // 实测超时必须可调（编译慢的项目 5s 不够）。
      expect(props.keys, contains('timeoutMs'));
      // 都不传也要能跑：默认当前会话、默认实测。
      expect(tool.inputSchema['required'], isNull);
    });

    test('sessions 的标记与 hot_reload 同源，不再只看有没有 FIFO', () {
      final src = File('bin/src/mcp/tools.dart').readAsStringSync();
      expect(src, contains('h.reloadChannel'));
      expect(src, contains("json['reloadChannel']"));
      expect(src, isNot(contains('h.fifo != null && h.fifo!.isNotEmpty')));
      // 热重载文案要说明按通道发信号，不再写 r 键。
      expect(src, contains('SIGUSR1'));
    });

    test('hotReload 不再往 FIFO 写按键（写了也是静默丢弃）', () {
      final src = File('bin/src/device/flutter_run.dart').readAsStringSync();
      final start = src.indexOf('Future<HotReloadResult> hotReload(');
      expect(start, greaterThan(0));
      final body = src.substring(start, start + 6000);
      expect(body, isNot(contains('writeLaunchFifo')));
      expect(body, contains('ReloadChannel.signal'));
      expect(body, contains('pidLooksLikeFlutterRun'));
    });
  });
}
