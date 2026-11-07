// 直连端口转发（P1）：设备列表解析与主机端口分配。
//
// 这两块是纯函数，直接决定「主机到哪去读 app 里的 Agent」。分配错了会读到
// 另一台设备的数据，所以稳定性和区间约束都在这里钉死。
library;

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/session/agent_forward.dart';

void main() {
  group('设备列表解析', () {
    test('adb 只取 state=device，跳过表头与不可用设备', () {
      final out = parseForwardTargets(
        adbDevices: 'List of devices attached\n'
            'R58M12345\tdevice\n'
            'R58M99999\tunauthorized\n'
            'emulator-5554\toffline\n'
            '\n',
      );
      expect(out.map((t) => t.source), <String>['adb:R58M12345']);
    });

    test('hdc 跳过 [Empty] 与 error 行', () {
      final out = parseForwardTargets(
        hdcTargets: '[Empty]\n'
            '7001005458323933328CCE1E2E1B0000\n'
            '[Fail]ExecuteCommand need connect-key\n',
      );
      expect(out.map((t) => t.source), <String>['hdc:7001005458323933328CCE1E2E1B0000']);
    });

    test('adb 与 hdc 同时在线时都保留', () {
      final out = parseForwardTargets(
        adbDevices: 'List of devices attached\nS1\tdevice\n',
        hdcTargets: 'H1\n',
      );
      expect(out, hasLength(2));
      expect(out.first.backend, 'adb');
      expect(out.last.backend, 'hdc');
    });

    test('空输入返回空列表', () {
      expect(parseForwardTargets(), isEmpty);
      expect(parseForwardTargets(adbDevices: 'List of devices attached'), isEmpty);
    });
  });

  group('主机端口分配', () {
    test('落在默认区间内', () {
      for (final id in <String>{
        'adb:S1',
        'adb:emulator-5554',
        'hdc:7001005458323933328CCE1E2E1B0000',
        'adb:R58M12345',
      }) {
        final port = agentHostPortFor(id);
        expect(port, greaterThanOrEqualTo(kAgentHostPortBase));
        expect(
          port,
          lessThan(kAgentHostPortBase + kAgentHostPortSpan),
          reason: '$id 分配到 $port，越界会撞进 VM 扫描段',
        );
      }
    });

    test('同一台设备每次都是同一个端口（重启 daemon 也不漂移）', () {
      final a = agentHostPortFor('adb:R58M12345');
      expect(agentHostPortFor('adb:R58M12345'), a);
      expect(agentHostPortFor('adb:R58M12345'), a);
    });

    test('span=1 时全部落在基点（可预测）', () {
      expect(agentHostPortFor('adb:S1', span: 1), kAgentHostPortBase);
      expect(agentHostPortFor('hdc:H1', span: 1), kAgentHostPortBase);
    });

    test('自定义区间按 span 取模', () {
      final port = agentHostPortFor('adb:S1', base: 50000, span: 3);
      expect(port, greaterThanOrEqualTo(50000));
      expect(port, lessThan(50003));
    });

    test('非法 span 退回基点，不抛异常', () {
      expect(agentHostPortFor('adb:S1', span: 0), kAgentHostPortBase);
      expect(agentHostPortFor('adb:S1', span: -5), kAgentHostPortBase);
    });
  });
}