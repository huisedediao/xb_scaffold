// 能力模型（P0）：transport → caps 的换算与缺口文案。
//
// 这套换算是工具前置校验与 GUI 置灰的唯一事实来源，两边说法必须一致，
// 所以边界（混淆 / VM 掉线 / 双通道并集）都在这里钉住。
library;

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/session/capability.dart';

void main() {
  group('transport 解析', () {
    test('三个已知值', () {
      expect(parseSessionTransport('vm'), SessionTransport.vm);
      expect(parseSessionTransport('agent'), SessionTransport.agent);
      expect(parseSessionTransport('both'), SessionTransport.both);
    });

    test('未知/空值返回 null（调用方按未知保守处理）', () {
      expect(parseSessionTransport(null), isNull);
      expect(parseSessionTransport(''), isNull);
      expect(parseSessionTransport('grpc'), isNull);
    });

    test('名字往返一致', () {
      for (final t in SessionTransport.values) {
        expect(parseSessionTransport(sessionTransportName(t)), t);
      }
    });
  });

  group('能力换算', () {
    test('VM 通道：调试面全开', () {
      final caps = sessionCaps(transport: SessionTransport.vm);
      expect(caps, containsAll(<String>[
        Cap.inspect,
        Cap.inspectable,
        Cap.fs,
        Cap.act,
        Cap.widgets,
        Cap.shot,
        Cap.perf,
        Cap.gc,
        Cap.debug,
        Cap.hot,
        Cap.srclocateExact,
        Cap.names,
        Cap.routeStack,
      ]));
      expect(caps, isNot(contains(Cap.srclocateHeuristic)));
    });

    test('直连通道：数据面/动作面在，调试面不在', () {
      final caps = sessionCaps(transport: SessionTransport.agent);
      expect(caps, containsAll(<String>[
        Cap.inspect,
        Cap.inspectable,
        Cap.fs,
        Cap.act,
        Cap.widgets,
        Cap.shot,
        Cap.perf,
        Cap.srclocateHeuristic,
        Cap.names,
      ]));
      for (final gone in <String>[
        Cap.debug,
        Cap.hot,
        Cap.gc,
        Cap.srclocateExact,
        // 路由栈详情要读 NavigatorState 私有历史，直连只有事件流。
        Cap.routeStack,
      ]) {
        expect(caps, isNot(contains(gone)), reason: '$gone 不应出现在直连会话');
      }
    });

    test('双通道取并集，精确源码定位优先', () {
      final caps = sessionCaps(transport: SessionTransport.both);
      expect(caps, containsAll(kVmCaps));
      expect(caps, isNot(contains(Cap.srclocateHeuristic)));
    });

    test('VM 掉线（vmDegraded）回落到直连能力', () {
      final caps = sessionCaps(
        transport: SessionTransport.both,
        vmDegraded: true,
      );
      expect(caps, isNot(contains(Cap.debug)));
      expect(caps, contains(Cap.inspect));
      expect(caps, contains(Cap.srclocateHeuristic));
    });

    test('混淆包没有可读类型名', () {
      final caps = sessionCaps(
        transport: SessionTransport.agent,
        obfuscated: true,
      );
      expect(caps, isNot(contains(Cap.names)));
      expect(caps, contains(Cap.inspect));
    });

    test('VM 侧永远是可读类型名（debug 不混淆）', () {
      final caps = sessionCaps(
        transport: SessionTransport.vm,
        obfuscated: true,
      );
      expect(caps, contains(Cap.names));
    });

    test('app 自报能力与理论上限求交（P1 只报 inspect）', () {
      final caps = sessionCaps(
        transport: SessionTransport.agent,
        agentCaps: const <String>{Cap.inspect},
      );
      // names 是混淆与否推出来的，不靠 app 自报。
      expect(caps, <String>[Cap.inspect, Cap.names]);
    });

    test('app 报的未知能力键不会凭空点亮（只取上限内的）', () {
      final caps = sessionCaps(
        transport: SessionTransport.agent,
        agentCaps: const <String>{Cap.inspect, Cap.debug, 'teleport'},
      );
      // debug 是 VM 独占，直连永远拿不到；teleport 无从映射。
      expect(caps, <String>[Cap.inspect, Cap.names]);
    });

    test('双通道里 agent 少报能力不影响 VM 侧', () {
      final caps = sessionCaps(
        transport: SessionTransport.both,
        agentCaps: const <String>{Cap.inspect},
      );
      expect(caps, containsAll(kVmCaps.where((c) => c != Cap.names)));
      expect(caps, contains(Cap.debug));
      expect(caps, contains(Cap.fs));
    });
  });

  group('缺口文案', () {
    test('直连会话说明原因', () {
      final msg = capGapMessage(
        <String>[Cap.debug, Cap.hot],
        transport: SessionTransport.agent,
      );
      expect(msg, contains('断点 / 单步 / 变量树 / 求值'));
      expect(msg, contains('热重载 / 热重启'));
      expect(msg, contains('release'));
    });

    test('VM 掉线时说明是临时降级', () {
      final msg = capGapMessage(
        <String>[Cap.debug],
        transport: SessionTransport.both,
        vmDegraded: true,
      );
      expect(msg, contains('VM 通道已断开'));
    });

    test('不缺能力时返回空串', () {
      expect(
        capGapMessage(const <String>[], transport: SessionTransport.vm),
        isEmpty,
      );
    });

    test('missingCaps / hasAllCaps 语义', () {
      final caps = sessionCaps(transport: SessionTransport.agent);
      expect(missingCaps(caps, <String>[Cap.inspect, Cap.debug]), <String>[Cap.debug]);
      expect(hasAllCaps(caps, <String>[Cap.inspect, Cap.act]), isTrue);
      expect(hasAllCaps(caps, <String>[Cap.debug]), isFalse);
    });
  });

  group('工具需求表', () {
    test('调试协议面登记 debug，热重载登记 hot', () {
      for (final t in <String>[
        'xbume_debug_attach',
        'xbume_debug_state',
        'xbume_debug_breakpoints',
        'xbume_debug_control',
        'xbume_debug_inspect',
        'xbume_debug_output',
        'xbume_eval',
      ]) {
        expect(kToolNeeds[t], contains(Cap.debug), reason: '$t 需要 debug');
      }
      expect(kToolNeeds['xbume_hot_reload'], contains(Cap.hot));
    });

    test('路由栈详情单独登记 route:stack（不混进 widgets）', () {
      expect(kToolNeeds['xbume_route_stack'], contains(Cap.routeStack));
      final agentCaps = sessionCaps(transport: SessionTransport.agent);
      expect(missingCaps(agentCaps, kToolNeeds['xbume_route_stack']!),
          <String>[Cap.routeStack]);
      expect(kCapLabels[Cap.routeStack], isNotEmpty);
    });

    test('数据面/动作面工具不得要求 debug（否则 release 会误报）', () {
      for (final t in <String>[
        'xbume_network',
        'xbume_console',
        'xbume_sandbox',
        'xbume_tap',
        'xbume_screenshot',
      ]) {
        final needs = kToolNeeds[t] ?? const <String>[];
        expect(needs, isNot(contains(Cap.debug)), reason: '$t 不该要求 debug');
      }
    });

    test('GUI 特性键与能力键对齐', () {
      for (final need in kFeatureNeeds.values) {
        for (final cap in need) {
          expect(kCapLabels.containsKey(cap), isTrue, reason: '$cap 没有文案');
        }
      }
    });
  });

  group('子操作能力闸门', () {
    test('沙盒：读不要 debug，上传 / 删除要 debug', () {
      final needs = kToolActionNeeds['xbume_sandbox']!;
      expect(needs.containsKey('list'), isFalse);
      expect(needs.containsKey('read'), isFalse);
      expect(needs.containsKey('download'), isFalse);
      expect(needs['upload'], <String>[Cap.debug]);
      expect(needs['delete'], <String>[Cap.debug]);
      final agentCaps = sessionCaps(transport: SessionTransport.agent);
      expect(missingCaps(agentCaps, needs['upload']!), <String>[Cap.debug]);
    });

    test('实例：stores / tree 不要 debug，find / set 要 debug', () {
      final needs = kToolActionNeeds['xbume_instances']!;
      expect(needs.containsKey('stores'), isFalse);
      expect(needs.containsKey('tree'), isFalse);
      expect(needs['find'], <String>[Cap.debug]);
      expect(needs['set'], <String>[Cap.debug]);
    });

    test('性能：snapshot 不要额外能力，leak / gc / reassemble 要 gc', () {
      final needs = kToolActionNeeds['xbume_perf']!;
      expect(needs.containsKey('snapshot'), isFalse);
      for (final action in <String>['leak', 'gc', 'reassemble']) {
        expect(needs[action], contains(Cap.gc), reason: action);
      }
      final agentCaps = sessionCaps(transport: SessionTransport.agent);
      expect(missingCaps(agentCaps, needs['gc']!), contains(Cap.gc));
    });

    test('表里出现的工具与能力键都合法', () {
      for (final entry in kToolActionNeeds.entries) {
        expect(entry.value, isNotEmpty, reason: '${entry.key} 空表没意义');
        for (final need in entry.value.values) {
          for (final cap in need) {
            expect(kCapLabels.containsKey(cap), isTrue,
                reason: '${entry.key} 用了未知能力 $cap');
          }
        }
      }
    });
  });
}