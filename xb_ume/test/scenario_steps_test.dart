// P3 场景 DSL 新步骤单测：waitFor / retry / if / observe / scrollUntil /
// 设备类步骤。全部用假 VM（按队列返回 eval 结果）与空设备注册表，
// 不连真机、不依赖 GUI。
library;

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/bridge.dart';
import '../bin/src/device/registry.dart';
import '../bin/src/scenario/runner.dart';
import '../bin/src/scenario/vm_client.dart';

/// 假 VM：evalStringOn 按 [replies] 队列出队，队空后回落到 [evalReply]。
class _FakeVm extends VmClient {
  _FakeVm() : super('ws://fake');

  final List<String> replies = <String>[];
  String evalReply = 'OK';
  String shot = '';

  @override
  Future<String> evalStringOn(String libraryUri, String expression) async {
    // 滑动的 down/move/up 注入固定回 OK，避免和条件结果抢队列。
    if (expression.contains('handlePointerEvent')) return 'OK';
    if (replies.isNotEmpty) return replies.removeAt(0);
    return evalReply;
  }

  @override
  Future<String> isolateId() async => 'iso';

  @override
  Future<String> screenshotBase64({double? maxPixelRatio}) async => shot;

  @override
  Future<Map<String, Object?>> rawRpc(
    String method, [
    Map<String, Object?>? params,
  ]) async =>
      <String, Object?>{'result': '{"a":1}'};
}

ScenarioRunner _runner(_FakeVm vm) => ScenarioRunner(
      vm,
      waitAfterMs: 0,
      devices: DeviceRegistry(const <DeviceBridge>[]),
    );

void main() {
  group('waitFor', () {
    test('条件立即满足', () async {
      final vm = _FakeVm()..evalReply = '2';
      final report = await _runner(vm).run('t', [
        {
          'type': 'waitFor',
          'until': {'kind': 'expr', 'expr': '1+1', 'expect': '2'},
          'timeoutMs': 200,
          'intervalMs': 20,
        },
      ]);
      final r = report.results.single;
      expect(r.status, 'pass');
      expect(r.actual, contains('满足'));
    });

    test('超时后失败并带最后一次条件说明', () async {
      final vm = _FakeVm()..evalReply = 'abc';
      final report = await _runner(vm).run('t', [
        {
          'type': 'waitFor',
          'until': {'expr': '1+1', 'expect': 'zzz'},
          'timeoutMs': 60,
          'intervalMs': 20,
        },
      ]);
      final r = report.results.single;
      expect(r.status, 'fail');
      expect(r.error, contains('等待超时'));
      expect(r.error, contains('zzz'));
    });

    test('visible 条件缺 widget 时报配置错误', () async {
      final report = await _runner(_FakeVm()).run('t', [
        {
          'type': 'waitFor',
          'until': {'kind': 'visible'},
        },
      ]);
      expect(report.results.single.error, contains('需要 widget'));
    });

    test('log 条件在 CLI 明确说明不可用', () async {
      final report = await _runner(_FakeVm()).run('t', [
        {
          'type': 'waitFor',
          'until': {'kind': 'log', 'contains': 'x'},
          'timeoutMs': 0,
        },
      ]);
      expect(report.results.single.error, contains('CLI 无日志订阅上下文'));
    });
  });

  group('retry', () {
    test('第一次失败、第二次通过', () async {
      final vm = _FakeVm()..replies.addAll(<String>['1', '2']);
      final report = await _runner(vm).run('t', [
        {
          'type': 'retry',
          'max': 3,
          'intervalMs': 0,
          'steps': [
            {'type': 'eval', 'expr': '1+1', 'expect': '2'},
          ],
        },
      ]);
      final r = report.results.single;
      expect(r.status, 'pass');
      expect(r.actual, contains('第 2 次尝试通过'));
    });

    test('用尽次数后失败，带内层错误', () async {
      final vm = _FakeVm()..evalReply = 'x';
      final report = await _runner(vm).run('t', [
        {
          'type': 'retry',
          'max': 2,
          'intervalMs': 0,
          'steps': [
            {'type': 'eval', 'expr': '1', 'expect': '2'},
          ],
        },
      ]);
      final r = report.results.single;
      expect(r.status, 'fail');
      expect(r.error, contains('重试 2 次仍失败'));
      expect(r.error, contains('期望包含'));
    });

    test('空 steps 报配置错误', () async {
      final report = await _runner(_FakeVm()).run('t', [
        {'type': 'retry', 'steps': <Object?>[]},
      ]);
      expect(report.results.single.error, contains('非空 steps'));
    });
  });

  group('if', () {
    test('条件成立执行 then', () async {
      final vm = _FakeVm()..evalReply = 'OK';
      final report = await _runner(vm).run('t', [
        {
          'type': 'if',
          'condition': {'expr': '1', 'expect': 'OK'},
          'then': [
            {'type': 'wait', 'ms': 1},
          ],
          'else': [
            {'type': 'nope'},
          ],
        },
      ]);
      final r = report.results.single;
      expect(r.status, 'pass');
      expect(r.actual, contains('then 1 步'));
    });

    test('条件不成立执行 else', () async {
      final vm = _FakeVm()..evalReply = 'nope';
      final report = await _runner(vm).run('t', [
        {
          'type': 'if',
          'condition': {'expr': '1', 'expect': 'OK'},
          'then': [
            {'type': 'nope'},
          ],
          'else': [
            {'type': 'wait', 'ms': 1},
          ],
        },
      ]);
      final r = report.results.single;
      expect(r.status, 'pass');
      expect(r.actual, contains('else 1 步'));
    });

    test('分支内失败透出错误', () async {
      final vm = _FakeVm()..evalReply = 'OK';
      final report = await _runner(vm).run('t', [
        {
          'type': 'if',
          'condition': {'expr': '1', 'expect': 'OK'},
          'then': [
            {'type': 'nope'},
          ],
        },
      ]);
      final r = report.results.single;
      expect(r.status, 'fail');
      expect(r.error, contains('then 分支失败'));
    });
  });

  group('observe / scrollUntil', () {
    test('observe 只采集请求的项', () async {
      final vm = _FakeVm()..replies.add('/home');
      final report = await _runner(vm).run('t', [
        {
          'type': 'observe',
          'include': ['routes'],
        },
      ]);
      final r = report.results.single;
      expect(r.status, 'pass');
      expect(r.actual, contains('routes=/home'));
    });

    test('observe 要求截图时把图挂到步骤结果', () async {
      final vm = _FakeVm()..shot = 'QUJD';
      final report = await _runner(vm).run('t', [
        {
          'type': 'observe',
          'include': ['shot'],
        },
      ]);
      final r = report.results.single;
      expect(r.status, 'pass');
      expect(r.shotB64, 'QUJD');
    });

    test('scrollUntil 首次检查命中就不滚动', () async {
      final vm = _FakeVm()
        ..replies.addAll(<String>['2\u0001400\u0001800']) // dpr、逻辑宽、逻辑高
        ..evalReply = 'FOUND'; // visible 条件
      final report = await _runner(vm).run('t', [
        {
          'type': 'scrollUntil',
          'condition': {'kind': 'visible', 'widget': 'ListView'},
          'max': 1,
        },
      ]);
      final r = report.results.single;
      expect(r.status, 'pass');
      expect(r.actual, contains('第 0 次检查命中'));
    });

    test('scrollUntil 滚动一次后命中', () async {
      final vm = _FakeVm()
        ..replies.addAll(
            <String>['2\u0001400\u0001800', 'NOT_FOUND', 'FOUND']);
      final report = await _runner(vm).run('t', [
        {
          'type': 'scrollUntil',
          'condition': {'kind': 'visible', 'widget': 'ListView'},
          'max': 1,
          'ms': 60,
        },
      ]);
      final r = report.results.single;
      expect(r.status, 'pass');
      expect(r.actual, contains('第 1 次检查命中'));
    });

    test('scrollUntil 用尽次数失败', () async {
      final vm = _FakeVm()
        ..replies.addAll(<String>['2\u0001400\u0001800', 'NOT_FOUND', 'NOT_FOUND'])
        ..evalReply = 'NOT_FOUND';
      final report = await _runner(vm).run('t', [
        {
          'type': 'scrollUntil',
          'condition': {'kind': 'visible', 'widget': 'ListView'},
          'max': 1,
          'ms': 60,
        },
      ]);
      final r = report.results.single;
      expect(r.status, 'fail');
      expect(r.error, contains('滚动 1 次仍未满足'));
    });
  });

  group('设备类步骤（空注册表，只验契约）', () {
    test('未知按键直接报错，不访问设备', () async {
      final report = await _runner(_FakeVm()).run('t', [
        {'type': 'pressKey', 'deviceId': 'x', 'key': 'nope'},
      ]);
      final r = report.results.single;
      expect(r.status, 'fail');
      expect(r.error, contains('未知按键'));
    });

    test('缺 deviceId 时提示清楚', () async {
      final report = await _runner(_FakeVm()).run('t', [
        {'type': 'nativeTap', 'x': 1, 'y': 2},
      ]);
      expect(report.results.single.error, contains('需要 deviceId'));
    });

    test('uninstall 未确认时拒绝执行', () async {
      final report = await _runner(_FakeVm()).run('t', [
        {'type': 'uninstall', 'deviceId': 'x', 'packageId': 'a.b'},
      ]);
      final r = report.results.single;
      expect(r.status, 'fail');
      expect(r.error, contains('confirm: true'));
    });

    test('设备不存在时给出可读错误', () async {
      final report = await _runner(_FakeVm()).run('t', [
        {'type': 'assertNoCrash', 'deviceId': 'gone'},
      ]);
      final r = report.results.single;
      expect(r.status, 'fail');
      expect(r.error, contains('设备 gone 未找到'));
    });

    test('record 明确标注未实现（不做假支持）', () async {
      final report = await _runner(_FakeVm()).run('t', [
        {'type': 'record', 'deviceId': 'x', 'action': 'start'},
      ]);
      final r = report.results.single;
      expect(r.status, 'fail');
      expect(r.error, contains('尚未实现'));
    });
  });
}
