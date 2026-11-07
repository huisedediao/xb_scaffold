// GUI 置灰与 API 字段（P0）：纯源码断言。
//
// GUI 是单文件里的 HTML/JS 字符串，没法直接跑 DOM 测试；这里钉住「声明式
// 置灰」的契约：控件只加属性、能力由后端下发、缺 caps 时保守全开。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final gui = File('bin/ide_gui.dart').readAsStringSync();
  final daemon = File('bin/ide.dart').readAsStringSync();
  final registry = File('bin/src/mcp/session_registry.dart').readAsStringSync();

  group('界面置灰框架', () {
    test('提示条与置灰样式存在', () {
      expect(gui, contains('id="cap-banner"'));
      expect(gui, contains('.cap-off'));
    });

    test('声明式属性 + 统一应用函数', () {
      expect(gui, contains('function dbgApplyCaps'));
      expect(gui, contains("[data-need-caps]"));
      expect(gui, contains('function dbgSetCurrentSession'));
      // 未选中会话 / 旧版 daemon 没给 caps 时不做任何置灰。
      expect(gui, contains('if (!caps) return true;'));
    });

    test('切换会话立即刷新置灰，不等 5s 轮询', () {
      final idx = gui.indexOf('function setVmFilter(v){');
      expect(idx, greaterThan(0));
      expect(gui.substring(idx, idx + 700), contains('dbgSetCurrentSession'));
    });

    test('VM 独占控件都声明了能力', () {
      for (final html in <String>[
        'onclick="dbgAttach(this)" data-need-caps="debug"',
        'onclick="dbgEval()" data-need-caps="debug"',
        'onclick="dbgStack()"',
        'id="dbg-b-pause" onclick="dbgPause()" data-need-caps="debug"',
        'id="dbg-b-over" onclick="dbgResume(\'over\')" data-need-caps="debug"',
        'id="dbg-b-hot" onclick="dbgHot(false)" data-need-caps="hot"',
        'id="dbg-b-restart" onclick="dbgHot(true)" data-need-caps="hot"',
        'onclick="rtOp(\'gc\')" data-need-caps="gc"',
        'onclick="leakCheck()" data-need-caps="gc"',
      ]) {
        expect(gui, contains(html), reason: '缺少 $html');
      }
    });

    test('下拉里能区分 VM / 直连 / 双通道', () {
      expect(gui, contains('function dbgSessionTransportText'));
      expect(gui, contains('（VM+直连）'));
      expect(gui, contains('（直连）'));
      expect(gui, contains('（VM）'));
      expect(gui, contains('dbgSessionTransportText(s)'));
    });

    test('直连会话的 uri 也记进 vmUriBySource（各 Tab 统一按 ?uri= 取数）', () {
      // 服务端按 http:// 前缀判定走 Agent，前端不需要区分通道。
      expect(gui, contains('vmUriBySource[v] = s.uri;'));
      expect(gui, isNot(contains("if (tr !== 'agent') vmUriBySource[v] = s.uri;")));
      expect(gui, contains('agentUrlBySource[v] = s.agentUrl;'));
    });

    test('置灰控件保留原 tooltip，追加原因', () {
      expect(gui, contains('data-cap-title'));
      expect(gui, contains('当前会话不支持：'));
    });

    test('置灰不覆盖既有的 disabled 逻辑（可叠加）', () {
      // dbgRenderBar 已按「已连接/已暂停」管着这些按钮的 disabled。
      expect(gui, contains("el.setAttribute('data-cap-blocked', ok ? '0' : '1')"));
      expect(gui, isNot(contains("el.disabled = !ok;")));
      expect(gui, contains('[data-cap-blocked="1"]'));
      expect(gui, contains("var pauseBtn = dbgEl('dbg-b-pause');"));
    });
    test('Tab 级置灰（直连会话按能力置灰，P2 截图/组件树已可用）', () {
      for (final tag in <String>[
        'data-tab="sandbox" data-need-caps="fs"',
        'data-tab="db" data-need-caps="fs"',
        'data-tab="storage" data-need-caps="fs"',
        'data-tab="routes" data-need-caps="route:stack"',
        'data-tab="wtree" style="display:none" data-need-caps="widgets"',
        'data-tab="shot" data-need-caps="shot"',
        'data-tab="perf" data-need-caps="perf"',
        'data-tab="instances" data-need-caps="inspectable"',
        'data-tab="auto" data-need-caps="act,debug"',
        'data-tab="compare" data-need-caps="debug"',
        'data-tab="ai" data-need-caps="shot,debug"',
      ]) {
        expect(gui, contains(tag), reason: '缺少 $tag');
      }
    });

    test('提示条按当前会话真实缺项生成，不写死能力名', () {
      expect(gui, contains("var all = ['inspect','inspectable','fs','act','widgets','route:stack','shot','perf','debug','hot','gc'];"));
      expect(gui, isNot(contains("['debug','hot','gc'].filter")));
    });

    test('直连会话选上即订阅异常轮询，切走就关', () {
      expect(gui, contains("var want = (tr === 'agent' && s && s.uri) ? s.uri : '';"));
      expect(gui, contains("'/api/agent/sub?uri='"));
      expect(gui, contains("'/api/agent/off'"));
      expect(gui, contains('if (want !== lastAgentSub) {'));
    });
  });

  group('daemon 下发的能力字段', () {
    test('状态列表带 transport / caps / agentPort', () {
      expect(daemon, contains('List<Map<String, Object?>> _statusSessions()'));
      expect(daemon, contains("'transport': sessionTransportName(l.transport)"));
      expect(daemon, contains("'caps': l.caps().toList()..sort()"));
      expect(daemon, contains("'agentPort': l.agentPort"));
    });

    test('每轮轮询会探测直连服务，且跳过自身端口', () {
      expect(daemon, contains('await _pollAgents();'));
      expect(daemon, contains('await discoverLocalAgents('));
      expect(daemon, contains('..._selfPorts,'));
      expect(daemon, contains('for (final d in _lastDiscovered) d.port,'));
      expect(daemon, contains('kLockPort,'));
    });

    test('设备上的直连服务先建转发再探测，转发结果优先', () {
      expect(daemon, contains('await ensureAgentForwards();'));
      expect(daemon, contains('...forwarded, ...scanned'));
      expect(daemon, contains('byFingerprint.putIfAbsent(a.fingerprint'));
    });

    test('手工 --uri 会话不被扫描结果挤掉', () {
      expect(daemon, contains("if (!manual) continue;"));
      expect(daemon, contains("'transport': kTransportVm"));
    });

    test('不把无信息量的 getVM 名（vm）当应用名透传', () {
      expect(daemon, contains("if (l.appName.isNotEmpty && l.appName != 'vm') 'app': l.appName,"));
    });
  });

  group('MCP 会话表', () {
    test('会话带 transport / caps，直连会话没有 VM 通道', () {
      expect(registry, contains("'transport': sessionTransportName(transport)"));
      expect(registry, contains("'caps': caps.toList()..sort()"));
      expect(registry, contains('bool get hasVm => wsUrl.isNotEmpty;'));
      expect(registry, contains('直连会话（无 VM 通道）'));
    });

    test('扫描时合并直连通道', () {
      expect(registry, contains('await discoverLocalAgents('));
      expect(registry, contains('skipPorts: skipPorts,'));
      expect(registry, contains('mergeLogicalSessions('));
      expect(registry, contains('McpSession.fromLogical'));
      expect(registry, contains('existing.applyLogical(l);'));
    });

    test('MCP 单独跑也能看见设备上的直连服务（自己建转发）', () {
      expect(registry, contains('await ensureAgentForwards(force: force);'));
      expect(registry, contains('[...forwardedAgents, ...scannedAgents]'));
    });
  });

  group('沙盒写动作按能力置灰', () {
    test('上传 / 删除按 debug 判定，直连渲染成不可点文本', () {
      // 这两个动作要往沙盒里写（dart:io 写 + eval 删除），直连 Agent 不提供。
      expect(gui, contains("capHas(sbCaps, 'debug')"));
      expect(gui, contains('var sbCanWrite = '));
      expect(gui, contains('sbCanWrite\n        ? \' <a href="javascript:void(0)" onclick="sbUpload(this)"'));
      expect(gui, contains("' <span class=\"cap-off\" title=\"' + sbReadOnlyTip + '\">上传</span>'"));
    });

    test('浏览 / 读取 / 下载不受影响（只要 fs）', () {
      for (final fn in <String>[
        'function sbRefresh',
        'function sbOpenSub',
        'function dbOpenFromSandbox',
      ]) {
        expect(gui, contains(fn));
      }
      expect(gui, contains('/api/sandbox/download?uri='));
      expect(gui, contains('/api/sandbox/downloadDir?uri='));
    });
  });

  group('MCP 子操作闸门接线', () {
    test('_callTool 按 action 查 kToolActionNeeds，与整工具闸门共用同一段逻辑', () {
      final server = File('bin/src/mcp/server.dart').readAsStringSync();
      expect(server, contains('Map<String, Object?>? capGap('));
      expect(server, contains('final gap = capGap(need);'));
      expect(server, contains(
          'kToolActionNeeds[name]?[(args[\'action\'] ?? \'\').toString()]'));
      expect(server, contains('final gap = capGap(actionNeed);'));
    });
  });
}