// 同一个 MCP 进程里多个客户端连接（同一助手开多个会话）的「当前会话」隔离。
//
// 场景：Qoder 开两个窗口都连 HTTP 46140 —— 进程里只有一个 SessionRegistry，
// 如果当前会话是进程级单值，A 选完 B 又选，A 后面不带 sessionId 的调用会静默
// 打到 B 的会话上。这里守住「按连接各记各的」+ 传输层确实把标识传进来。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/mcp/client_scope.dart';
import '../bin/src/mcp/lease.dart';
import '../bin/src/mcp/session_registry.dart';

void main() {
  /// 造一个会话（不连 VM：VmClient 是懒建的）。
  String add(SessionRegistry reg, int port) =>
      reg.addManual('ws://127.0.0.1:$port/abc/ws').id;

  test('两个客户端连接各记各的当前会话，互不覆盖', () async {
    final reg = SessionRegistry();
    final a = add(reg, 46001);
    final b = add(reg, 46002);

    // 没有连接上下文（= --uri 注入那条路径）时选中的会话兼作默认值。
    expect(reg.currentId, b);

    await runAsMcpClient('A', () async {
      expect(await reg.use(a), isNotNull);
      expect(reg.currentId, a);
    });

    await runAsMcpClient('B', () async {
      // B 还没选过：先落到默认（最后注入的那个）。
      expect(reg.currentId, b);
      expect(await reg.use(b), isNotNull);
      expect(reg.currentId, b);
    });

    // 关键：B 选过之后，A 仍然是自己那个。
    await runAsMcpClient('A', () async {
      expect(reg.currentId, a);
    });

    // 默认值也没被 A/B 改写。
    expect(reg.currentId, b);
  });

  test('没回传 Mcp-Session-Id 的客户端退回共享当前会话（与旧版一致）', () async {
    final reg = SessionRegistry();
    final a = add(reg, 46011);
    await runAsMcpClient('A', () async => reg.use(a));
    // 空串 = HTTP 请求没带 Mcp-Session-Id。
    await runAsMcpClient('', () async {
      expect(reg.currentId, a, reason: '兼容路径应仍能看到默认会话');
    });
  });

  test('currentByClient 能列出各连接选了哪个（排障用）', () async {
    final reg = SessionRegistry();
    final a = add(reg, 46021);
    final b = add(reg, 46022);
    await runAsMcpClient('A', () async => reg.use(a));
    await runAsMcpClient('B', () async => reg.use(b));
    expect(reg.currentByClient['A'], a);
    expect(reg.currentByClient['B'], b);
  });

  test('同一实例的两条连接驱动同一会话：第二条报 busy，不被当成自己续期', () async {
    final home = Directory.systemTemp.createTempSync('xb_scope_lease_');
    addTearDown(() {
      try {
        home.deleteSync(recursive: true);
      } catch (_) {}
    });
    final store = LeaseStore(
      instance: 'mcp-46140',
      instancePid: pid,
      instancePort: 46140,
      home: home.path,
    );
    const key = 'session-s46001';

    final a = await runAsMcpClient(
        'window-a-1a2b3c', () => store.acquire(key, note: 'tap'));
    expect(a.ok, isTrue);
    expect(a.lease!.owner.client, '1a2b3c');
    expect(ownerLabel(a.lease!.owner), 'mcp-46140:46140（连接 …1a2b3c）');

    // 同一个进程、同一个会话，另一条连接不能冒充持有者。
    final b = await runAsMcpClient(
        'window-b-9f8e7d', () => store.acquire(key, note: 'tap'));
    expect(b.ok, isFalse, reason: '同实例另一条连接必须排队');
    expect(b.holder!.owner.client, '1a2b3c');
    expect(b.holder!.note, 'tap');

    // 同一条连接再来一次 = 续期，不算抢。
    final again = await runAsMcpClient(
        'window-a-1a2b3c', () => store.acquire(key, note: 'input'));
    expect(again.ok, isTrue);
    expect(again.lease!.note, 'input');
    expect(again.lease!.owner.client, '1a2b3c');
  });

  test('只有唯一会话时，第二个连接不扫描也能拿到当前会话（不被 3 秒缓存吞掉）', () async {
    final reg = SessionRegistry();
    // 'seed' 这条连接注入会话：它自己选中，但不写默认值（''）。
    final id = await runAsMcpClient(
        'seed', () async => reg.addManual('ws://127.0.0.1:46051/abc/ws').id);
    await runAsMcpClient('win-b', () async {
      expect(reg.currentId, id,
          reason: '唯一会话应直接算选中；命中扫描缓存的窗口不能停在「未选择会话」');
    });
  });

  test('传输层把连接标识传给 handleMessage', () {
    final serverSrc = File('bin/src/mcp/server.dart').readAsStringSync();
    // stdio：一个进程一个连接，固定标识。
    expect(serverSrc, contains("handleMessage(raw, client: 'stdio')"));
    // HTTP：客户端回传的 Mcp-Session-Id 就是连接标识。
    expect(serverSrc, contains("req.headers.value('Mcp-Session-Id')"));
    expect(serverSrc, contains('runAsMcpClient(client'));
    final regSrc = File('bin/src/mcp/session_registry.dart').readAsStringSync();
    expect(regSrc, contains('client_scope.dart'));
    expect(regSrc, contains('currentByClient'));
  });
}
