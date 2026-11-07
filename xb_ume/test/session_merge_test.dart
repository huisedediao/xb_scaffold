// 逻辑会话合并（P0）：VM 通道与直连通道按 app 配对，VM 优先。
//
// 配对错了会让工具跑到另一台设备的 app 上，所以三条规则（精确/兼底/不合并）
// 都钉死：宁可多一条并列会话，也不要错配。
library;

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/session/capability.dart';
import '../bin/src/session/discovery.dart';

DiscoveredSession vm(
  int port, {
  String device = 'adb:S1',
  int? remotePort,
  String name = 'example',
}) {
  return DiscoveredSession(
    wsUrl: 'ws://127.0.0.1:$port/ws',
    port: port,
    source: '$device#port:$port',
    fingerprint: 'iso-$port',
    name: name,
    remotePort: remotePort,
  );
}

DiscoveredAgent agent(
  int port, {
  String device = 'adb:S1',
  String pkg = 'com.example.app',
  String bootId = 'boot-1',
  int? vmPort,
  bool obfuscated = false,
}) {
  return DiscoveredAgent(
    port: port,
    baseUrl: 'http://127.0.0.1:$port',
    source: '$device#port:$port',
    appId: pkg,
    packageName: pkg,
    bootId: bootId,
    version: '0.9.6',
    obfuscated: obfuscated,
    caps: const <String>['inspect', 'fs', 'act'],
    vmPort: vmPort,
  );
}

void main() {
  group('逻辑会话基本形态', () {
    test('只有直连：id=a<port>，能力缺调试面', () {
      final out = mergeLogicalSessions(
        vmSessions: const <DiscoveredSession>[],
        agents: <DiscoveredAgent>[agent(47100)],
      );
      expect(out, hasLength(1));
      final s = out.single;
      expect(s.id, 'a47100');
      expect(s.transport, SessionTransport.agent);
      expect(s.uri, 'http://127.0.0.1:47100');
      expect(s.appName, 'com.example.app');
      expect(s.caps(), isNot(contains(Cap.debug)));
      expect(s.caps(), contains(Cap.inspect));
    });

    test('只有 VM：行为与以前一致（transport=vm）', () {
      final out = mergeLogicalSessions(
        vmSessions: <DiscoveredSession>[vm(50000)],
        agents: const <DiscoveredAgent>[],
      );
      expect(out.single.id, 's50000');
      expect(out.single.transport, SessionTransport.vm);
      expect(out.single.uri, 'ws://127.0.0.1:50000/ws');
      expect(out.single.caps(), contains(Cap.debug));
    });

    test('什么都没发现时返回空', () {
      expect(
        mergeLogicalSessions(
          vmSessions: const <DiscoveredSession>[],
          agents: const <DiscoveredAgent>[],
        ),
        isEmpty,
      );
    });
  });

  group('精确配对（app 自报 vmPort == 转发远端端口）', () {
    test('同设备同端口 → 合并为 both，id 沿用 s<port>', () {
      final out = mergeLogicalSessions(
        vmSessions: <DiscoveredSession>[vm(50000, remotePort: 40000)],
        agents: <DiscoveredAgent>[agent(47100, vmPort: 40000)],
      );
      expect(out, hasLength(1));
      final s = out.single;
      expect(s.transport, SessionTransport.both);
      expect(s.id, 's50000');
      expect(s.vmPort, 50000);
      expect(s.agentPort, 47100);
      expect(s.caps(), containsAll(<String>[Cap.debug, Cap.hot, Cap.gc]));
    });

    test('设备不一致不合并（防止串到另一台机器）', () {
      final out = mergeLogicalSessions(
        vmSessions: <DiscoveredSession>[vm(50000, remotePort: 40000)],
        agents: <DiscoveredAgent>[agent(47100, vmPort: 40000, device: 'adb:S2')],
      );
      expect(out, hasLength(2));
      expect(out.map((e) => e.transport).toSet(), <SessionTransport>{
        SessionTransport.vm,
        SessionTransport.agent,
      });
    });

    test('端口对不上时不精确配对，落到兼底规则', () {
      // 唯一候选 → 兼底配成 both（同设备只剩一条）。
      final out = mergeLogicalSessions(
        vmSessions: <DiscoveredSession>[vm(50000, remotePort: 40001)],
        agents: <DiscoveredAgent>[agent(47100, vmPort: 40000)],
      );
      expect(out, hasLength(1));
      expect(out.single.transport, SessionTransport.both);
    });
  });

  group('兼底配对（同设备互剩唯一候选）', () {
    test('无 vmPort（release）也能配上', () {
      final out = mergeLogicalSessions(
        vmSessions: <DiscoveredSession>[vm(50000)],
        agents: <DiscoveredAgent>[agent(47100)],
      );
      expect(out.single.transport, SessionTransport.both);
      expect(out.single.id, 's50000');
    });

    test('同设备两条直连时不兼底合并', () {
      final out = mergeLogicalSessions(
        vmSessions: <DiscoveredSession>[vm(50000)],
        agents: <DiscoveredAgent>[agent(47100), agent(47101)],
      );
      expect(out, hasLength(3));
      expect(
        out.where((e) => e.transport == SessionTransport.agent).length,
        2,
      );
    });

    test('不同设备互不影响', () {
      final out = mergeLogicalSessions(
        vmSessions: <DiscoveredSession>[vm(50000, device: 'adb:S1')],
        agents: <DiscoveredAgent>[agent(47100, device: 'adb:S2')],
      );
      expect(out, hasLength(2));
      expect(out.every((e) => e.transport != SessionTransport.both), isTrue);
    });
  });

  group('列表与序列化', () {
    test('按端口排序，两条通道的会话排在一起', () {
      final out = mergeLogicalSessions(
        vmSessions: <DiscoveredSession>[vm(50002), vm(50000)],
        agents: <DiscoveredAgent>[agent(47100), agent(47101)],
      );
      final ports = out.map((e) => e.port).toList();
      expect(ports, <int>[47100, 47101, 50000, 50002]);
    });

    test('toJson 带 transport / caps / agentPort，便于 GUI 置灰', () {
      final out = mergeLogicalSessions(
        vmSessions: <DiscoveredSession>[vm(50000, remotePort: 40000)],
        agents: <DiscoveredAgent>[agent(47100, vmPort: 40000, obfuscated: true)],
      );
      final json = out.single.toJson();
      expect(json['transport'], 'both');
      expect(json['agentPort'], 47100);
      expect(json['vmPort'], 50000);
      expect(json['obfuscated'], true);
      final caps = (json['caps'] as List).cast<String>();
      expect(caps, contains(Cap.debug));
      // 有 VM 通道时类型名总是可读（debug 包不混淆），直连侧的 obfuscated 不降级它。
      expect(caps, contains(Cap.names));
      // caps 排序便于前端稳定比较。
      expect(caps, List<String>.from(caps)..sort());
    });

    test('纯直连混淆包：类型名与精确源码定位都不可用', () {
      final out = mergeLogicalSessions(
        vmSessions: const <DiscoveredSession>[],
        agents: <DiscoveredAgent>[agent(47100, obfuscated: true)],
      );
      final caps = (out.single.toJson()['caps'] as List).cast<String>();
      expect(caps, isNot(contains(Cap.names)));
      expect(caps, isNot(contains(Cap.srclocateExact)));
      expect(caps, contains(Cap.srclocateHeuristic));
    });

    test('vmDegraded 时输出去掉调试能力', () {
      final out = mergeLogicalSessions(
        vmSessions: <DiscoveredSession>[vm(50000)],
        agents: <DiscoveredAgent>[agent(47100)],
      );
      final json = out.single.toJson(vmDegraded: true);
      expect(json['vmDegraded'], true);
      expect((json['caps'] as List).cast<String>(), isNot(contains(Cap.debug)));
    });
  });
}