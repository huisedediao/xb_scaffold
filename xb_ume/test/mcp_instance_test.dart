// MCP 实例登记（一 AI 一进程时的实例清单）+ 写工具的租约接线守卫。
//
// 实例登记是「谁在驱动」的展示层，真正拦人的是 lease；这里一并做源码级守卫，
// 防止以后新增写工具忘记走 resolveDriveSession / requireDeviceFree。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/live_store.dart' show pidAlive;
import '../bin/src/mcp/instances.dart';
import '../bin/src/mcp/tools.dart';

/// 找一个确定不存在的 pid（不用 0：0 在不同平台上语义不一）。
int _deadPid() {
  for (var p = 999900; p < 999960; p++) {
    if (!pidAlive(p)) return p;
  }
  return 999999;
}

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('xb_inst_');
  });

  tearDown(() {
    try {
      home.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('实例名', () {
    test('只保留安全字符，超长截断', () {
      expect(sanitizeInstanceName('claude a'), 'claude-a');
      expect(sanitizeInstanceName('  mac/win  '), 'mac-win');
      expect(sanitizeInstanceName('claude-甲'), 'claude-甲');
      expect(sanitizeInstanceName(''), '');
      expect(sanitizeInstanceName('x' * 80).length, 40);
    });

    test('默认名：http 按端口、stdio 按 pid', () {
      expect(defaultInstanceName(http: true, port: 46141), 'mcp-46141');
      expect(defaultInstanceName(http: false, port: 46141), 'mcp-$pid');
    });
  });

  group('实例登记', () {
    test('写读一致，list 只返回活着的实例', () {
      writeInstance(<String, Object?>{
        'name': 'claude-a',
        'transport': 'http',
        'port': 46141,
        'pid': pid,
        'hasEval': true,
      }, home: home.path);
      final rec = readInstance('claude-a', home: home.path);
      expect(rec?['port'], 46141);
      expect(rec?['hasEval'], true);

      final list = listInstances(home: home.path);
      expect(list.length, 1);
      expect(list.single['name'], 'claude-a');
      expect(list.single['alive'], true);
    });

    test('pid 已不在的登记被 prune 掉', () {
      writeInstance(<String, Object?>{
        'name': 'ghost',
        'pid': _deadPid(),
        'port': 46150,
      }, home: home.path);
      expect(listInstances(home: home.path), isEmpty);
      // 文件也删了，不留垃圾。
      expect(File('${home.path}/mcp/instances/ghost.json').existsSync(), isFalse);
    });

    test('同名冲突只在对方活着且不是自己时才报', () {
      writeInstance(<String, Object?>{'name': 'claude-a', 'pid': pid},
          home: home.path);
      // 自己占的名字不算冲突（否则重启后自己起不来）。
      expect(instanceNameConflict('claude-a', home: home.path), isNull);

      writeInstance(<String, Object?>{'name': 'claude-b', 'pid': _deadPid()},
          home: home.path);
      expect(instanceNameConflict('claude-b', home: home.path), isNull);
      expect(instanceNameConflict('没这个名字', home: home.path), isNull);
    });

    test('removeInstance 带 onlyPid：pid 对不上就不删', () {
      writeInstance(<String, Object?>{'name': 'claude-a', 'pid': pid},
          home: home.path);
      removeInstance('claude-a', home: home.path, onlyPid: pid + 1);
      expect(readInstance('claude-a', home: home.path), isNotNull);
      removeInstance('claude-a', home: home.path, onlyPid: pid);
      expect(readInstance('claude-a', home: home.path), isNull);
    });
  });

  group('写工具的租约接线（源码守卫）', () {
    final toolsSrc = File('bin/src/mcp/tools.dart').readAsStringSync();
    final deviceSrc = File('bin/src/mcp/device_tools.dart').readAsStringSync();
    final debugSrc = File('bin/src/mcp/debug_tools.dart').readAsStringSync();

    test('两个新工具在 core 组', () {
      final core = coreTools();
      final names = core.map((t) => t.name).toSet();
      expect(names, containsAll(<String>['xbume_clients', 'xbume_lease']));
      for (final n in <String>['xbume_clients', 'xbume_lease']) {
        expect(core.firstWhere((t) => t.name == n).group, ToolGroup.core);
      }
      // clients 不需要参数；lease 必须给 op，且 op 是闭集。
      final lease = core.firstWhere((t) => t.name == 'xbume_lease');
      expect(lease.inputSchema['required'], contains('op'));
      final ops = ((lease.inputSchema['properties'] as Map)['op'] as Map)['enum'];
      expect((ops as List).cast<String>(),
          containsAll(<String>['status', 'acquire', 'release', 'steal']));
    });

    test('会话级写工具都走 resolveDriveSession / requireDriveSession', () {
      for (final op in <String>[
        'tap',
        'input',
        'swipe',
        'navigate',
        'eval',
        'hot_reload',
        'scenario_run',
      ]) {
        expect(toolsSrc, contains("resolveDriveSession(ctx, args, '$op')"),
            reason: '$op 没接写租约');
      }
      // use_session 也按 drive / observe 分流。
      expect(toolsSrc, contains('drive'));
      expect(toolsSrc, contains('observe'));
      expect(toolsSrc, contains('releaseOthers'));
    });

    test('设备级写操作与启动租约', () {
      // 拉起 / force 重启 = 启动租约（同设备同目录只能一个人拉）。
      expect(deviceSrc, contains('requireLaunchLease('));
      expect(deviceSrc, contains('steal: force'));
      expect(deviceSrc, contains('launchLease'));
      // 装包 / 卸包 / 按键 / 原生点按：同设备上有别人在驱动就拒绝注入。
      expect(deviceSrc, contains("requireDeviceFree(ctx, device.id, '装包')"));
      expect(deviceSrc, contains("requireDeviceFree(ctx, device.id, '卸载')"));
      expect(deviceSrc, contains('requireDeviceFree(ctx, device.id, \'按键 '));
      expect(deviceSrc, contains("requireDeviceFree(ctx, device.id, '原生点击')"));
    });

    test('调试工具的写动作要租约，读动作不拦', () {
      expect(debugSrc, contains('_bpReadOps'));
      expect(debugSrc, contains("resolveDriveSession(ctx, args, 'debug_breakpoints"));
      expect(debugSrc, contains("resolveDriveSession(ctx, args, 'debug_control"));
      expect(debugSrc, contains("resolveDriveSession(ctx, args, 'debug_inspect:eval')"));
    });

    test('审计日志先建 logs/ 再写：全新 XB_UME_HOME 不能把进程带走', () {
      // openWrite 的失败是异步抛的，外层 try/catch 接不到；必须建目录 + 接住
      // sink.done，否则「新机器 / 新 XB_UME_HOME 的第一次工具调用」直接崩服务。
      final src = File('bin/src/mcp/server.dart').readAsStringSync();
      expect(src, contains('f.parent.createSync(recursive: true)'));
      expect(src, contains('sink.done.catchError'));
    });
  });
}
