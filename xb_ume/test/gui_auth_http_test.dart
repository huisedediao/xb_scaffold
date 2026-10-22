import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/ide_gui.dart' as gui;

/// 用内存 HttpServer 驱动 handleRequest，验证真实 HTTP 层行为。
/// 不启动完整 GUI / 不触碰设备，避免影响本机正在运行的调试会话。
void main() {
  const token = 'test-token-0123456789abcdef';
  late HttpServer server;
  late int port;
  late gui.GuiState state;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    state = gui.GuiState();
    gui.setGuiAuthForTest(token, port);
    server.listen((req) {
      unawaited(gui.handleRequest(state, req));
    });
  });

  tearDown(() async {
    await state.dispose();
    await server.close(force: true);
    gui.setGuiAuthForTest('', 0);
  });

  Future<_Resp> get(
    String path, {
    String? cookie,
    String? headerToken,
    String? origin,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.get('127.0.0.1', port, path);
      if (cookie != null) req.headers.set('cookie', cookie);
      if (headerToken != null) req.headers.set('x-xbume-token', headerToken);
      if (origin != null) req.headers.set('origin', origin);
      final resp = await req.close();
      final body = await utf8.decoder.bind(resp).join();
      return _Resp(resp.statusCode, body, resp.headers);
    } finally {
      client.close(force: true);
    }
  }

  /// 原样发送 HTTP 文本，覆盖 Host / Content-Length 等 HttpClient 不便构造的头。
  Future<String> raw(String request) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    final bytes = <int>[];
    final done = Completer<void>();
    socket.listen(
      bytes.addAll,
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (_) {
        if (!done.isCompleted) done.complete();
      },
    );
    socket.write(request);
    await socket.flush();
    await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    socket.destroy();
    return utf8.decode(bytes, allowMalformed: true);
  }

  test('/ping 免令牌，并带安全响应头', () async {
    final r = await get('/ping');
    expect(r.status, 200);
    expect(r.body, 'xbume-gui');
    expect(r.headers.value('x-frame-options'), 'DENY');
    expect(r.headers.value('x-content-type-options'), 'nosniff');
  });

  test('根页面签发 HttpOnly + SameSite=Strict Cookie 并注入令牌', () async {
    final r = await get('/');
    expect(r.status, 200);
    expect(r.body, contains('name="xbume-token" content="$token"'));
    expect(r.body, isNot(contains('__XBUME_TOKEN__')));
    final setCookies =
        r.headers[HttpHeaders.setCookieHeader] ?? const <String>[];
    expect(setCookies, isNotEmpty);
    final cookie = Cookie.fromSetCookieValue(setCookies.first);
    expect(cookie.name, 'xbume_gui_$port');
    expect(cookie.value, token);
    expect(cookie.httpOnly, isTrue);
    expect(cookie.sameSite, SameSite.strict);
    expect(setCookies.first.toLowerCase(), contains('httponly'));
  });

  test('无令牌的受保护路径返回 403', () async {
    final r = await get('/view');
    expect(r.status, 403);
    expect(r.body, contains('未授权'));
  });

  test('Cookie 与 X-XBUME-Token 均可授权', () async {
    final viaCookie = await get('/view', cookie: 'xbume_gui_$port=$token');
    expect(viaCookie.status, 200);
    expect(viaCookie.body, contains('<html'));

    final viaHeader = await get('/api/logs.txt', headerToken: token);
    expect(viaHeader.status, 200);
  });

  test('query token 可用于 WS 之外的脚本访问', () async {
    final r = await get('/view?token=$token');
    expect(r.status, 200);
  });

  test('错误令牌返回 403', () async {
    final r = await get('/view', headerToken: 'wrong-token');
    expect(r.status, 403);
  });

  test('跨站 Origin 即使带令牌也拒绝', () async {
    final r = await get(
      '/view',
      headerToken: token,
      origin: 'http://evil.example',
    );
    expect(r.status, 403);
    expect(r.body, contains('Origin'));
  });

  test('DNS rebinding Host 在 /ping 之前就被拒绝', () async {
    final text = await raw(
      'GET /ping HTTP/1.1\r\n'
      'Host: evil.example:$port\r\n'
      'Connection: close\r\n\r\n',
    );
    expect(_statusOf(text), 403);
    expect(text, contains('Host'));
  });

  test('network clear 的 GET 返回 405 且声明 Allow: POST', () async {
    final r = await get(
      '/api/network/clear?uri=x',
      headerToken: token,
    );
    expect(r.status, 405);
    expect(r.headers.value('allow'), 'POST');
  });

  test('超过 24MB 的 Content-Length 直接 413', () async {
    // 真实浏览器会按 Content-Length 发送大 body；服务端在读取前就拒绝。
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/api/network/clear?uri=x'),
      );
      req.headers.set('cookie', 'xbume_gui_$port=$token');
      const total = gui.kGuiBodyLimitBytes + 1;
      req.contentLength = total;
      final chunk = List<int>.filled(256 * 1024, 0);
      var sent = 0;
      while (sent < total) {
        final n = total - sent < chunk.length ? total - sent : chunk.length;
        req.add(n == chunk.length ? chunk : chunk.sublist(0, n));
        sent += n;
        if (sent % (4 * 1024 * 1024) == 0) {
          try {
            await req.flush();
          } catch (_) {
            // 服务端提前关闭时写入可能失败，状态码仍可从 close 读取。
          }
        }
      }
      final resp = await req.close();
      expect(resp.statusCode, 413);
      await resp.drain<void>();
    } finally {
      client.close(force: true);
    }
  });

  test('未知路径带令牌时返回 404', () async {
    final r = await get('/no-such-path', headerToken: token);
    expect(r.status, 404);
  });

  test('日志导出对 VM service token 打码', () async {
    state.addEntry(<String, Object?>{
      'msg': 'listening on http://127.0.0.1:61829/AbCdEf0123456789ABCDEF/',
      'source': 'flutter',
      'level': 'I',
      'tag': 'test',
    });
    final r = await get('/api/logs.txt', headerToken: token);
    expect(r.status, 200);
    expect(r.body, contains('http://127.0.0.1:61829/***/'));
    expect(r.body, isNot(contains('AbCdEf0123456789ABCDEF')));
  });

  test('WS 无令牌被拒绝，有令牌可握手并收到快照', () async {
    await expectLater(
      WebSocket.connect('ws://127.0.0.1:$port/ws'),
      throwsA(isA<WebSocketException>()),
    );

    final ws = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws?token=$token',
    );
    final first = await ws.first.timeout(const Duration(seconds: 5));
    final msg = jsonDecode(first as String) as Map<String, dynamic>;
    expect(msg['type'], 'snapshot');
    await ws.close();
  });

  test('WS 跨站 Origin 被拒绝', () async {
    await expectLater(
      WebSocket.connect(
        'ws://127.0.0.1:$port/ws?token=$token',
        headers: <String, dynamic>{'origin': 'http://evil.example'},
      ),
      throwsA(isA<WebSocketException>()),
    );
  });
}

class _Resp {
  _Resp(this.status, this.body, this.headers);

  final int status;
  final String body;
  final HttpHeaders headers;
}

int _statusOf(String raw) {
  final m = RegExp(r'^HTTP/1\.[01] (\d{3})').firstMatch(raw);
  return m == null ? -1 : int.parse(m.group(1)!);
}
