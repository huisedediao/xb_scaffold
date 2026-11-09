// CLI 场景执行器（bin/run.dart + bin/src/scenario/*）单测：
// URI 归一化、场景解析、步骤语义（依赖注入假 VM）、HTML 报告生成。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/scenario/runner.dart';
import '../bin/src/scenario/scenario_file.dart';
import '../bin/src/scenario/vm_client.dart';

/// 假 VM：不建立连接，按需返回 eval 结果（步骤执行语义测试用）。
class _FakeVm extends VmClient {
  _FakeVm() : super('ws://fake');

  String evalReply = 'OK';

  @override
  Future<String> evalStringOn(String libraryUri, String expression) async =>
      evalReply;

  @override
  Future<String> isolateId() async => 'iso';

  @override
  Future<String> screenshotBase64({double? maxPixelRatio}) async => '';
}

void main() {
  group('normalizeVmUri', () {
    test('纯端口与 host:port 补全 ws 路径', () {
      expect(normalizeVmUri('65296'), 'ws://127.0.0.1:65296/ws');
      expect(normalizeVmUri('127.0.0.1:65296'), 'ws://127.0.0.1:65296/ws');
      expect(normalizeVmUri(' ws://127.0.0.1:65296/ws '),
          'ws://127.0.0.1:65296/ws');
    });

    test('http(s) 转 ws(s) 并补 /ws', () {
      expect(normalizeVmUri('http://127.0.0.1:65296/'),
          'ws://127.0.0.1:65296/ws');
      expect(normalizeVmUri('https://example.com'), 'wss://example.com/ws');
    });

    test('带 token 的 http 地址只换 scheme，保留原路径', () {
      // flutter run 打印的就是这个形态（DebugHub 的 wsUri 也存它），
      // /api/routestack 等直连 VM 的接口必须能吃下这一种。
      expect(normalizeVmUri('http://127.0.0.1:55333/nIpL2-QthcI=/'),
          'ws://127.0.0.1:55333/nIpL2-QthcI=/');
      expect(normalizeVmUri('https://127.0.0.1:55333/nIpL2-QthcI=/'),
          'wss://127.0.0.1:55333/nIpL2-QthcI=/');
    });

    test('带 token 路径的 ws 地址原样保留', () {
      const u = 'ws://127.0.0.1:54579/nIpL2-QthcI=/ws';
      expect(normalizeVmUri(u), u);
    });
  });

  group('inspectorRootId', () {
    test('兼容 JSON 与 Dart Map toString', () {
      expect(inspectorRootId('{"valueId":"inspector-3"}'), 'inspector-3');
      expect(
          inspectorRootId(
              '{description: [root], type: _ElementDiagnosticableTreeNode, '
              'valueId: inspector-7, summaryTree: true}'),
          'inspector-7');
      expect(inspectorRootId(''), 'root');
    });
  });

  group('loadScenario', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('xb_cli_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File write(String name, Object json) {
      final f = File('${tmp.path}/$name');
      f.writeAsStringSync(jsonEncode(json));
      return f;
    }

    test('纯数组取文件名作场景名', () {
      final f = write('demo.json', [
        {'type': 'wait', 'ms': 1},
      ]);
      final (name, steps) = loadScenario(f);
      expect(name, 'demo');
      expect(steps.length, 1);
    });

    test('{name, steps} 对象取 name 字段', () {
      final f = write('x.json', {
        'name': '登录流程',
        'steps': [
          {'type': 'eval', 'expr': '1+1', 'expect': '2'},
        ],
      });
      final (name, steps) = loadScenario(f);
      expect(name, '登录流程');
      expect(steps.single['expect'], '2');
    });

    test('空步骤与非对象步骤报错', () {
      expect(() => loadScenario(write('empty.json', [])),
          throwsA(isA<FormatException>()));
      expect(() => loadScenario(write('bad.json', ['x'])),
          throwsA(isA<FormatException>()));
    });
  });

  group('ScenarioRunner 步骤语义', () {
    test('未知类型 fail 且默认停止，后续步骤 skip', () async {
      final vm = _FakeVm();
      final report = await ScenarioRunner(vm, waitAfterMs: 0).run('t', [
        {'type': 'nope'},
        {'type': 'wait', 'ms': 1},
      ]);
      expect(report.total, 2);
      expect(report.results[0].status, 'fail');
      expect(report.results[0].error, contains('未知步骤类型'));
      expect(report.results[1].status, 'skip');
      expect(report.ok, isFalse);
    });

    test('continueOnFail 时失败后继续执行', () async {
      final report = await ScenarioRunner(_FakeVm(),
              waitAfterMs: 0, continueOnFail: true)
          .run('t', [
        {'type': 'tap'},
        {'type': 'wait', 'ms': 1},
      ]);
      expect(report.results[0].status, 'fail');
      expect(report.results[0].error, contains('tap 需要 x/y'));
      expect(report.results[1].status, 'pass');
    });

    test('eval 期望不匹配时 fail，实际值保留', () async {
      final vm = _FakeVm()..evalReply = '3';
      final report = await ScenarioRunner(vm, waitAfterMs: 0).run('t', [
        {'type': 'eval', 'expr': '1+1', 'expect': '2'},
      ]);
      final r = report.results.single;
      expect(r.status, 'fail');
      expect(r.actual, '3');
      expect(r.error, contains('期望包含「2」'));
    });

    test('eval 命中期望时 pass', () async {
      final vm = _FakeVm()..evalReply = '42';
      final report = await ScenarioRunner(vm, waitAfterMs: 0).run('t', [
        {'type': 'eval', 'expr': '6*7', 'expect': '42'},
      ]);
      expect(report.results.single.status, 'pass');
    });

    test('assertLog 在 CLI 下标 skip（无 GUI 日志上下文）', () async {
      final report = await ScenarioRunner(_FakeVm(), waitAfterMs: 0).run('t', [
        {'type': 'assertLog', 'contains': 'x'},
      ]);
      final r = report.results.single;
      expect(r.status, 'skip');
      expect(r.error, contains('CLI 无日志订阅上下文'));
      expect(report.ok, isTrue);
    });

    test('wait 不依赖 RPC', () async {
      final report =
          await ScenarioRunner(_FakeVm(), waitAfterMs: 0).run('t', [
        {'type': 'wait', 'ms': 5},
      ]);
      expect(report.results.single.status, 'pass');
      expect(report.results.single.actual, 'waited 5 ms');
    });
  });

  group('buildScenarioReportHtml', () {
    ScenarioRunReport makeReport({bool withShot = true}) {
      final r1 = ScenarioStepResult(0, 'eval', '2', {'type': 'eval'})
        ..actual = '<b>2</b>'
        ..status = 'pass'
        ..ms = 12;
      final r2 = ScenarioStepResult(1, 'assertRoute', '/home', {'type': 'assertRoute'})
        ..actual = '/login'
        ..error = '栈顶路由 /login 不匹配 /home'
        ..status = 'fail'
        ..ms = 30;
      if (withShot) {
        r2.shotB64 = base64Encode(<int>[1, 2, 3]);
      }
      return ScenarioRunReport(
        name: '登录流程',
        uri: 'ws://127.0.0.1:65296/ws',
        startedAt: DateTime(2026, 10, 21, 10),
        endedAt: DateTime(2026, 10, 21, 10, 0, 5),
        results: [r1, r2],
        continueOnFail: false,
      );
    }

    test('包含汇总、转义与内嵌截图', () {
      final html = buildScenarioReportHtml(makeReport(), version: '0.3.0');
      expect(html, contains('xb_ume 场景执行报告'));
      expect(html, contains('❌ 1 步失败'));
      expect(html, contains('总步数 <b>2</b>'));
      expect(html, contains('通过 <b class="pass">1</b>'));
      expect(html, contains('&lt;b&gt;2&lt;/b&gt;'), reason: '实际值需 HTML 转义');
      expect(html, contains('data:image/png;base64,AQID'));
      expect(html, contains('失败即停止'));
      expect(html, contains('0.3.0'));
    });

    test('全部通过时显示绿色徽章且无截图也可生成', () {
      final r = ScenarioRunReport(
        name: 'smoke',
        uri: 'ws://x/ws',
        startedAt: DateTime(2026, 10, 21, 10),
        endedAt: DateTime(2026, 10, 21, 10, 0, 1),
        results: [
          ScenarioStepResult(0, 'wait', '', {'type': 'wait'})
            ..actual = 'waited 1 ms'
            ..status = 'pass'
            ..ms = 1,
        ],
        continueOnFail: true,
      );
      final html = buildScenarioReportHtml(r);
      expect(html, contains('✅ 全部通过'));
      expect(html, contains('失败后继续执行'));
      expect(html, isNot(contains('data:image/png')));
    });
  });
}
