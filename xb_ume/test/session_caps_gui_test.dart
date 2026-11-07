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

    test('纯直连会话不把 http 地址当 VM ws 用', () {
      expect(gui, contains("if (tr !== 'agent') vmUriBySource[v] = s.uri;"));
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
  });
}