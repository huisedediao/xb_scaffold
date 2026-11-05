// 会话 / 启动租约内核（多 AI 争用同一台机器时唯一的跨进程互斥点）：
// 空闲即拿、别人占着报 busy、自己续期、TTL / 进程退出自动失效、
// steal 接管、release 只删自己的、并发只有一个成功。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/mcp/lease.dart';

void main() {
  late Directory home;
  late DateTime now;

  LeaseStore store(String name, {bool alive = true}) => LeaseStore(
        instance: name,
        instancePid: pid,
        instancePort: 46140,
        home: home.path,
        now: () => now,
        pidAliveFn: (_) => alive,
      );

  setUp(() {
    home = Directory.systemTemp.createTempSync('xb_lease_');
    now = DateTime(2026, 1, 1, 10);
  });

  tearDown(() {
    try {
      home.deleteSync(recursive: true);
    } catch (_) {}
  });

  const key = 'session-s65296';

  test('空闲时直接拿到并落盘', () async {
    final a = store('claude-a');
    expect(a.peek(key), isNull);
    final att = await a.acquire(key, note: 'tap');
    expect(att.ok, isTrue);
    expect(att.lease!.owner.instance, 'claude-a');
    expect(att.lease!.note, 'tap');
    expect(att.lease!.kind, 'session');
    // 落盘可见：别的实例 list() 也能看到。
    expect(a.list().single.key, key);
    expect(File('${home.path}/leases/$key.json').existsSync(), isTrue);
  });

  test('别人持有时报 busy，且不覆盖原租约', () async {
    final a = store('claude-a');
    await a.acquire(key, note: 'hot_reload');
    final b = store('claude-b');
    final att = await b.acquire(key, note: 'tap');
    expect(att.ok, isFalse);
    expect(att.holder!.owner.instance, 'claude-a');
    expect(att.holder!.note, 'hot_reload');
    // 文件仍是 a 的，b 的尝试没有把 note 改掉。
    final onDisk = jsonDecode(File('${home.path}/leases/$key.json').readAsStringSync())
        as Map<String, Object?>;
    expect((onDisk['owner'] as Map)['instance'], 'claude-a');
    expect(onDisk['note'], 'hot_reload');
  });

  test('自己重复 acquire 只续期，不重置 acquiredAt', () async {
    final a = store('claude-a');
    final first = (await a.acquire(key, note: 'tap')).lease!;
    now = now.add(const Duration(minutes: 4));
    final again = (await a.acquire(key, note: 'input')).lease!;
    expect(again.acquiredAt, first.acquiredAt);
    expect(again.renewedAt, now);
    expect(again.note, 'input');
  });

  test('TTL 到期后自动失效，别人可以拿', () async {
    final a = store('claude-a');
    await a.acquire(key);
    final b = store('claude-b');
    expect((await b.acquire(key)).ok, isFalse);
    now = now.add(kDefaultLeaseTtl + const Duration(seconds: 1));
    // peek 顺手把过期文件清掉。
    expect(b.peek(key), isNull);
    expect((await b.acquire(key)).ok, isTrue);
  });

  test('持有者进程不存活即视为过期（AI 崩了不会把会话锁死）', () async {
    final a = store('claude-a');
    await a.acquire(key);
    final b = store('claude-b', alive: false);
    expect(b.peek(key), isNull);
    expect((await b.acquire(key)).ok, isTrue);
  });

  test('steal 强行接管，原持有者失去租约', () async {
    final a = store('claude-a');
    await a.acquire(key);
    final b = store('claude-b');
    final att = await b.acquire(key, steal: true, note: 'take over');
    expect(att.ok, isTrue);
    expect(att.lease!.owner.instance, 'claude-b');
    expect(a.peek(key)?.owner.instance, 'claude-b');
  });

  test('release 只删自己的，不误删别人的', () async {
    final a = store('claude-a');
    await a.acquire(key);
    final b = store('claude-b');
    expect(await b.release(key), isFalse);
    expect(a.peek(key), isNotNull);
    expect(await a.release(key), isTrue);
    expect(a.peek(key), isNull);
  });

  test('releaseOthers 保留指定的那份', () async {
    final a = store('claude-a');
    await a.acquire('session-s1');
    await a.acquire('session-s2');
    final released = await a.releaseOthers(keep: 'session-s1');
    expect(released, <String>['session-s2']);
    expect(a.list().map((l) => l.key), <String>['session-s1']);
  });

  test('残文件 / 手改坏了当作没有，后续 acquire 能覆盖', () async {
    Directory('${home.path}/leases').createSync(recursive: true);
    File('${home.path}/leases/$key.json').writeAsStringSync('{"owner":');
    final a = store('claude-a');
    expect(a.peek(key), isNull);
    expect((await a.acquire(key)).ok, isTrue);
  });

  test('并发 acquire 只有一个成功', () async {
    final a = store('claude-a');
    final b = store('claude-b');
    final results = await Future.wait(<Future<LeaseAttempt>>[
      a.acquire(key, note: 'a'),
      b.acquire(key, note: 'b'),
    ]);
    expect(results.where((r) => r.ok).length, 1);
    expect(results.where((r) => r.holder != null).length, 1);
  });

  test('waitMs 等对方释放后再拿', () async {
    final a = store('claude-a');
    await a.acquire(key);
    final b = store('claude-b');
    // 200ms 后 a 释放；b 最多等 5 秒。
    unawaited(Future<void>.delayed(const Duration(milliseconds: 200), () async {
      now = now.add(const Duration(seconds: 1));
      await a.release(key);
    }));
    final att = await b.acquire(
      key,
      wait: const Duration(seconds: 5),
    );
    expect(att.ok, isTrue);
    expect(att.lease!.owner.instance, 'claude-b');
  });

  test('key 形状：会话按 id、启动按设备 + cwd 摘要且稳定', () {
    expect(LeaseStore.sessionKey('s1'), 'session-s1');
    final k1 = LeaseStore.launchKey('emulator-5554', '/tmp/app');
    final k2 = LeaseStore.launchKey('emulator-5554', '/tmp/app');
    final k3 = LeaseStore.launchKey('emulator-5554', '/tmp/app2');
    expect(k1, k2);
    expect(k1, isNot(k3));
    expect(k1, startsWith('launch-emulator-5554-'));
    // 落盘名里不含路径分隔符（否则会写到别的目录）。
    expect(k1.contains('/'), isFalse);
  });

  test('leaseAgo / leaseLeft 给人读的时间描述', () async {
    final a = store('claude-a');
    final l = (await a.acquire(key)).lease!;
    expect(leaseAgo(l.renewedAt, now: now), '刚刚');
    expect(leaseAgo(now.subtract(const Duration(minutes: 3)), now: now), '3 分钟前');
    expect(leaseLeft(l, now: now), '10 分钟');
    final later = now.add(const Duration(minutes: 9, seconds: 30));
    expect(leaseLeft(l, now: later), '30 秒');
    expect(leaseLeft(l, now: now.add(const Duration(minutes: 11))), '已过期');
  });
}
