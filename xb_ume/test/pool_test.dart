// 服务池：槽位分配 / 绑定 TTL / 续期 / 释放 / 接管 / 池满排队 / 回收即杀。
//
// 场景：同一个助手开多个窗口。每个窗口一条连接，各绑一个实例；空闲槽一律
// 杀掉残留进程、重绑拉起全新实例（严格模式）；没满就新建，5 个都绑满就回
// 「需要排队」。这里用假的 now / pidAlive / kill 把时间与进程拿在手里。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/mcp/pool.dart';

void main() {
  late Directory tmp;
  late DateTime now;
  late Set<int> alive;
  late List<int> kills;

  PoolStore store({int max = 5}) => PoolStore(
        home: tmp.path,
        max: max,
        now: () => now,
        pidAliveFn: (p) => alive.contains(p),
        killFn: kills.add,
      );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xbume_pool_test');
    now = DateTime(2026, 11, 5, 10);
    alive = <int>{};
    kills = <int>[];
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('空池从槽 1 开始分配，并生成绑定标识', () async {
    final p = store();
    final a = await p.allocate(owner: 'A', client: 'sid-a', note: 'screenshot');
    expect(a, isNotNull);
    expect(a!.slot, 1);
    expect(a.bindingId, matches(RegExp(r'^b-[0-9a-f]{6}$')));
    expect(a.client, 'sid-a');
    expect(a.ttlMs, kPoolBindingTtl.inMilliseconds);
    expect(File('${tmp.path}/pool/slot-1.json').existsSync(), isTrue);
  });

  test('同一条连接再分配还拿到同一个槽，换连接才新占一个', () async {
    final p = store();
    final a1 = await p.allocate(owner: 'A', client: 'sid-a');
    final a2 = await p.allocate(owner: 'A', client: 'sid-a');
    expect(a2!.slot, a1!.slot);
    expect(a2.bindingId, a1.bindingId);

    final b = await p.allocate(owner: 'B', client: 'sid-b');
    expect(b!.slot, isNot(a1.slot));
    expect(p.boundSlots().length, 2);
  });

  test('5 个都绑满时第 6 条连接拿不到，排队文案说清谁占着', () async {
    final p = store();
    for (var i = 0; i < 5; i++) {
      final s = await p.allocate(owner: 'AI$i', client: 'sid-$i', note: 'tap');
      expect(s, isNotNull);
    }
    expect(await p.allocate(owner: 'AI6', client: 'sid-6'), isNull);

    final text = poolBusyText(p, mineClient: 'sid-6');
    expect(text, contains('服务池已满（5/5'));
    expect(text, contains('AI3'));
    expect(text, contains('还剩'));
    expect(text, contains('三条出路'));
    expect(text, contains('steal'));
  });

  test('池上限可配：2 个槽的池第 3 条连接就排队', () async {
    final p = store(max: 2);
    await p.allocate(owner: 'A', client: 'sid-a');
    await p.allocate(owner: 'B', client: 'sid-b');
    expect(await p.allocate(owner: 'C', client: 'sid-c'), isNull);
    expect(p.status()['max'], 2);
  });

  test('绑定 10 分钟不续期就过期，槽回到池里给下一个连接', () async {
    final p = store();
    final a = await p.allocate(owner: 'A', client: 'sid-a');

    now = now.add(const Duration(minutes: 9));
    expect(p.isBound(p.list()[a!.slot - 1]), isTrue);

    now = now.add(const Duration(minutes: 2));
    expect(p.isBound(p.list()[a.slot - 1]), isFalse);
    expect(p.boundSlots(), isEmpty);

    final b = await p.allocate(owner: 'B', client: 'sid-b');
    expect(b!.slot, a.slot);
    expect(b.bindingId, isNot(a.bindingId));
    expect(b.client, 'sid-b');
  });

  test('持有者进程没了，绑定自动失效', () async {
    final p = store();
    final a = await p.allocate(owner: 'A', client: 'sid-a');
    await p.attachWorker(a!.slot, name: 'pool-1', port: 46141, pid: 999);

    alive.add(999);
    expect(p.isBound(p.list()[0]), isTrue);

    alive.remove(999);
    expect(p.isBound(p.list()[0]), isFalse);

    final b = await p.allocate(owner: 'B', client: 'sid-b');
    expect(b!.slot, 1);
  });

  test('释放只能释放自己的', () async {
    final p = store();
    await p.allocate(owner: 'A', client: 'sid-a');
    await p.allocate(owner: 'B', client: 'sid-b');

    expect(await p.releaseFor('sid-x'), isFalse);
    expect(await p.releaseSlot(1, client: 'sid-b'), isFalse);
    expect(p.boundSlots().length, 2);

    expect(await p.releaseFor('sid-a'), isTrue);
    expect(p.boundSlots().length, 1);
    // 槽还在，只是没人绑：下一次分配直接复用它。
    final c = await p.allocate(owner: 'C', client: 'sid-c');
    expect(c!.slot, 1);
  });

  test('释放就停实例：严格模式下不把进程留给下一个人', () async {
    final p = store();
    final a = await p.allocate(owner: 'A', client: 'sid-a');
    await p.attachWorker(a!.slot, name: 'pool-1', port: 46141, pid: 999);
    alive.add(999);

    expect(await p.releaseFor('sid-a'), isTrue);
    expect(kills, contains(999));
    final slot = p.list()[a.slot - 1];
    expect(slot.pid, 0);
    expect(slot.bindingId, isEmpty);
  });

  test('空闲槽不继承旧进程：重绑一定拉起新实例', () async {
    final p = store();
    final a = await p.allocate(owner: 'A', client: 'sid-a');
    await p.attachWorker(a!.slot, name: 'pool-1', port: 46141, pid: 999);
    alive.add(999);

    // A 闲置过期、扫描器还没跑到：B 来分配也不会接管这个进程（拿空槽，pid=0
    // 由调用方拉起新的），槽 1 的残留进程留给扫描器收。
    now = now.add(const Duration(minutes: 11));
    final b = await p.allocate(owner: 'B', client: 'sid-b');
    expect(b!.pid, 0);
    expect(b.slot, isNot(a.slot));
    expect(p.list()[a.slot - 1].pid, 999); // 还没被动过

    expect(await p.sweep(), 1);
    expect(kills, contains(999));
    expect(p.list()[a.slot - 1].pid, 0);
  });

  test('回收扫描：过期绑定与残留进程都清掉', () async {
    final p = store();
    final a = await p.allocate(owner: 'A', client: 'sid-a');
    await p.attachWorker(a!.slot, name: 'pool-1', port: 46141, pid: 999);
    alive.add(999);

    expect(await p.sweep(), 0); // 还在有效期内，不动
    now = now.add(const Duration(minutes: 11));
    expect(await p.sweep(), 1);
    expect(kills, contains(999));
    final slot = p.list()[a.slot - 1];
    expect(slot.pid, 0);
    expect(slot.port, 0);
    expect(slot.bindingId, isEmpty);
  });

  test('有场景在跑就不回收：只续期，等它跑完', () async {
    final p = store();
    final a = await p.allocate(owner: 'A', client: 'sid-a');
    await p.attachWorker(a!.slot, name: 'pool-1', port: 46141, pid: 999);
    alive.add(999);

    now = now.add(const Duration(minutes: 11));
    await p.markRunning(a.slot, true);
    expect(await p.sweep(), 0);
    expect(kills, isEmpty);
    // 滚动续期：从这一刻重新算 TTL，别的连接抢不走。
    expect(p.isBound(p.list()[a.slot - 1]), isTrue);

    await p.markRunning(a.slot, false);
    now = now.add(const Duration(minutes: 11));
    expect(await p.sweep(), 1);
    expect(kills, contains(999));
  });

  test('steal 会停掉原实例，接管方拿到干净槽', () async {
    final p = store();
    final a = await p.allocate(owner: 'A', client: 'sid-a');
    await p.attachWorker(a!.slot, name: 'pool-1', port: 46141, pid: 999);
    alive.add(999);

    final text = await poolOpText(pool: p, client: 'sid-c', owner: 'C', op: 'steal');
    expect(text, contains('原实例已停掉'));
    expect(kills, contains(999));
    final got = p.mine('sid-c')!;
    expect(got.slot, a.slot);
    expect(got.pid, 0);
  });

  test('steal 接管最久没动的那个', () async {
    final p = store();
    await p.allocate(owner: 'A', client: 'sid-a');
    now = now.add(const Duration(minutes: 1));
    await p.allocate(owner: 'B', client: 'sid-b');

    expect(p.oldestBound()!.client, 'sid-a');
    final text = await poolOpText(
      pool: p,
      client: 'sid-c',
      owner: 'C',
      op: 'steal',
    );
    expect(text, contains('已接管槽 1'));
    // 原属者写进结果里，方便追「我抢了谁」。
    expect(text, contains('A'));
    expect(p.mine('sid-c')!.slot, 1);
    expect(p.boundSlots().length, 2);
  });

  test('续期限频：20 秒内重复调用不重写文件，之后才更新', () async {
    final p = store();
    final a = await p.allocate(owner: 'A', client: 'sid-a', note: 'screenshot');
    final first = p.list()[0].renewedAt;
    expect(first, isNotNull);

    now = now.add(const Duration(seconds: 5));
    await p.renewFor('sid-a', note: 'tap');
    expect(p.list()[0].renewedAt, first);
    expect(p.list()[0].note, 'screenshot');

    now = now.add(const Duration(seconds: 20));
    await p.renewFor('sid-a', note: 'tap');
    expect(p.list()[0].note, 'tap');
    expect(p.list()[0].renewedAt!.isAfter(first!), isTrue);
    expect(p.mine('sid-a')!.bindingId, a!.bindingId);
  });

  test('池状态给出 5 个槽的所有者、状态与剩余时间', () async {
    final p = store();
    await p.allocate(owner: 'A', client: 'sid-a', note: 'tap');
    now = now.add(const Duration(minutes: 3));

    final st = p.status(mine: 'sid-a');
    expect(st['bound'], 1);
    expect(st['free'], 4);
    final slots = (st['slots'] as List<Object?>).cast<Map<String, Object?>>();
    expect(slots.length, 5);
    expect(slots[0]['mine'], isTrue);
    expect('${slots[0]['state']}', 'bound');
    expect('${slots[1]['state']}', 'empty');

    final left = (slots[0]['leftMs'] as num).toInt();
    expect(left, inInclusiveRange(6 * 60000, 7 * 60000 + 1000));

    final text = await poolOpText(
      pool: p,
      client: 'sid-a',
      owner: 'A',
      op: 'status',
      now: now,
    );
    expect(text, contains('服务池 5 个槽'));
    expect(text, contains('槽 1'));
    // 3 分钟前绑定、TTL 10 分钟 → 还剩 7 分钟。
    expect(text, contains('还剩 7 分钟'));
    expect(text.contains('你：槽 1'), isTrue);
  });

  test('传输层接线（源码守卫）：入口按连接转发、池操作本地答', () {
    final mcpSrc = File('bin/mcp.dart').readAsStringSync();
    expect(mcpSrc, contains("'--pool-entry'"));
    expect(mcpSrc, contains("'--pool-max'"));
    expect(mcpSrc, contains('_runPoolEntry'));

    final router = File('bin/src/mcp/router.dart').readAsStringSync();
    expect(router, contains("req.headers.set('Mcp-Session-Id', sid)"));
    expect(router, contains("name == 'xbume_pool'"));
    expect(router, contains('_ensureSlot'));
    // 严格模式靠入口的后台回收扫描兑现：过期/残留进程必须有人收。
    expect(router, contains('kPoolSweepEvery'));
    expect(router, contains('pool.sweep()'));

    final tools = File('bin/src/mcp/tools.dart').readAsStringSync();
    expect(tools, contains("name: 'xbume_pool'"));

    // worker 上报自己槽里有没有场景在跑（否则回收扫描会把自动化腰斩）。
    final poolSrc = File('bin/src/mcp/pool.dart').readAsStringSync();
    expect(poolSrc, contains('markRunning'));
    final mcpSrc2 = File('bin/mcp.dart').readAsStringSync();
    expect(mcpSrc2, contains('markRunning'));

    // GUI 单文件部署不 import bin/src，只能守着四个接点都在：端点、无名启动带入口、
    // 读池状态、卡片容器（漏一个就会出现「服务在跑但卡片是空的」）。
    final gui = File('bin/ide_gui.dart').readAsStringSync();
    expect(gui, contains("'/api/pool'"));
    expect(gui, contains("'--pool-entry'"));
    expect(gui, contains('readPoolStatus'));
    expect(gui, contains('releasePoolSlot'));
    expect(gui, contains('id="mcp-pool"'));

    // 指令里的池说明：AI 得知道有 release / steal，池满时先问人。
    final prompt = File('bin/src/ai/prompt.dart').readAsStringSync();
    expect(prompt, contains('xbume_pool'));
    expect(prompt, contains('release'));
  });
}
