// MCP 感知三件套（网络详情 / 结构化异常 / 时间轴）：
// 工具注册、schema 参数、表达式覆盖面与旧版本兜底。
//
// 表达式必须保持「单行 IIFE」——VM eval 对多行 IIFE 只会返回未调用的 Closure，
// 这里一并作为回归断言。工具 handler 内部的整形逻辑依赖真机，不在单测里跑。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/bridge.dart';
import '../bin/src/device/flutter_run.dart';
import '../bin/src/mcp/device_tools.dart';
import '../bin/src/mcp/tools.dart';
import '../bin/src/scenario/expressions.dart';

void main() {
  final core = coreTools();
  final all = <McpTool>[...core, ...deviceTools()];
  final byName = <String, McpTool>{for (final t in all) t.name: t};
  final src = File('bin/src/mcp/tools.dart').readAsStringSync();

  test('三个诊断工具已注册，且默认组（core）就能用', () {
    for (final name in <String>[
      'xbume_network_detail',
      'xbume_exceptions',
      'xbume_timeline',
    ]) {
      final tool = byName[name];
      expect(tool, isNotNull, reason: '$name 未注册');
      expect(tool!.group, ToolGroup.core, reason: '$name 应默认暴露');
    }
    // 工具名唯一（server 按 name 分发）。
    expect(byName.length, all.length);
    // 文档口径：core 18 + diagnose 3 + run-safe 3 + act 2 + device-write 3。
    expect(all.length, 29, reason: '新增/删除工具后同步 README / MCP_GUIDE / CHANGELOG');
    // 热重载默认可用；eval 必须显式 --allow-eval。
    expect(byName['xbume_hot_reload']?.group, ToolGroup.core);
    expect(byName.containsKey('xbume_eval'), isFalse);
    final withEval = coreTools(allowEval: true);
    expect(withEval.length, coreTools().length + 1);
    expect(withEval.map((t) => t.name), contains('xbume_eval'));
  });

  test('工具 schema 暴露关键参数', () {
    Set<String> props(String name) =>
        ((byName[name]!.inputSchema['properties'] as Map).keys.cast<String>())
            .toSet();

    expect(props('xbume_network_detail'),
        containsAll(<String>['sessionId', 'id', 'urlContains', 'maxChars', 'limit']));
    expect(props('xbume_exceptions'),
        containsAll(<String>['sessionId', 'kind', 'typeContains', 'keyword', 'sinceMs', 'limit']));
    expect(props('xbume_timeline'),
        containsAll(<String>['sessionId', 'kinds', 'keyword', 'sinceMs', 'limit']));
    expect(props('xbume_hot_reload'),
        containsAll(<String>['sessionId', 'pid', 'mode', 'timeoutMs']));
    final evalTool = coreTools(allowEval: true)
        .firstWhere((t) => t.name == 'xbume_eval');
    expect((evalTool.inputSchema['properties'] as Map).keys,
        containsAll(<String>['sessionId', 'expr', 'lib', 'maxChars']));
    expect(evalTool.inputSchema['required'], contains('expr'));
    final mode = ((byName['xbume_hot_reload']!.inputSchema['properties']
        as Map)['mode'] as Map)['enum'] as List;
    expect(mode, containsAll(<String>['reload', 'restart']));
    // kind 是枚举，模型不该自己编。
    final kind = ((byName['xbume_exceptions']!.inputSchema['properties']
        as Map)['kind'] as Map)['enum'] as List;
    expect(kind, containsAll(<String>['flutter', 'platform', 'app', 'all']));
  });

  test('网络详情表达式带齐头/体/发起栈，且注入 maxChars', () {
    final e = networkDetailExpr(
      urlContains: '/api/login',
      method: 'post',
      maxChars: 512,
      limit: 2,
    );
    expect(e.contains('\n'), isFalse, reason: 'VM eval 需要单行 IIFE');
    expect(e, startsWith('(() {'));
    expect(e, endsWith('})()'));
    expect(e, contains('XBUme.controller.network'));
    for (final key in <String>[
      'requestHeaders',
      'requestBody',
      'responseHeaders',
      'responseBody',
      'initiator',
      'initiatorStack',
      'NOT_FOUND',
    ]) {
      expect(e, contains(key), reason: '缺少 $key');
    }
    expect(e, contains("e.url.contains('/api/login')"));
    expect(e, contains("e.method.toUpperCase() == 'POST'"));
    expect(e, contains('512'));
  });

  test('异常表达式支持来源/类型/关键字/时间窗过滤', () {
    final e = exceptionsExpr(
      kind: 'flutter',
      typeContains: 'TypeError',
      keyword: 'null',
      sinceMs: 1700000000000,
      limit: 5,
    );
    expect(e.contains('\n'), isFalse, reason: 'VM eval 需要单行 IIFE');
    expect(e, contains('XBUme.controller.exceptions'));
    expect(e, contains("e.kind.name == 'flutter'"));
    expect(e, contains("e.type.contains('TypeError')"));
    expect(e, contains('e.time.millisecondsSinceEpoch >= 1700000000000'));
    expect(e, contains('e.count'));
    expect(e, contains('e.stack'));
  });

  test('时间轴聚合四类事件，异常段对旧 app 兜底', () {
    final e = timelineExpr(sinceMs: 1700000000000, limit: 30);
    expect(e.contains('\n'), isFalse, reason: 'VM eval 需要单行 IIFE');
    for (final key in <String>[
      'XBUme.controller.routes',
      'XBUme.controller.network',
      'XBUme.controller.logs',
      'XBUme.controller.exceptions',
    ]) {
      expect(e, contains(key), reason: '缺少 $key');
    }
    // 老版本 app 没有 exceptions getter：必须包住，否则整个时间轴报错。
    expect(e, contains('try {'));
    expect(e, contains('} catch (_) {}'));
    expect(e, contains('1700000000000'));
    expect(e, contains('30'), reason: 'limit 用于每段取末尾 N 条');
  });

  test('旧 app 没有异常缓冲时给出升级提示，而不是把 VM 报错直接抛出', () {
    expect(src, contains("m.contains('exceptions')"));
    expect(src, contains('升级 xb_ume'));
  });

  test('eval 未开启时拒绝执行，开启后能选库', () {
    // handler 内的二次开关（--allow-eval）必须是显式错误，而不是静默降级。
    expect(src, contains("!ctx.allowEval"));
    expect(src, contains('--allow-eval'));
    // 默认库上下文：xb_ume core，不可用退 dart:io。
    expect(src, contains('kLibXbUme'));
    expect(src, contains("'dart:io'"));
    // 表达式长度上限，避免把整个文件塞进 eval。
    expect(src, contains('表达式过长'));
  });

  test('热重载只接受本服务拉起的进程', () async {
    final launcher = FlutterRunLauncher();
    expect(launcher.pidForPort(52111), isNull);
    await expectLater(
      () => launcher.hotReload(999999),
      throwsA(isA<DeviceCommandError>()),
    );
  });
}
