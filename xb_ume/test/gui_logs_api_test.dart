// GUI /api/logs（日志历史分页）的接口级单测：起一个真实 HttpServer 挂
// gui.handleRequest，往 GuiState 缓冲里塞日志，再按 query 参数取。
//
// 纯函数 queryGuiLog 的逻辑已在 log_history_test.dart 覆盖，这里只守「接线」：
// 参数有没有读进来、返回字段齐不齐、两个游标真能接力、VM token 不外泄。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/ide_gui.dart' as gui;

void main() {
  const token = 'test-logs-token-0123456789';
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

  void entry(String source, String msg, {String tag = 'tag'}) {
    state.addEntry(<String, Object?>{
      'ts': '12:00:00',
      'level': 'I',
      'tag': tag,
      'msg': msg,
      'source': source,
    });
  }

  Future<Map<String, Object?>> getLogs(String query) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:$port/api/logs$query'),
      );
      req.headers.set('x-xbume-token', token);
      final resp = await req.close();
      final text = await utf8.decoder.bind(resp).join();
      expect(resp.statusCode, 200, reason: text);
      return jsonDecode(text) as Map<String, Object?>;
    } finally {
      client.close(force: true);
    }
  }

  List<Map<String, Object?>> items(Map<String, Object?> body) =>
      ((body['items'] as List?) ?? const <Object?>[])
          .cast<Map<String, Object?>>();

  test('默认 tail：取末尾 limit 条，字段与 sources 齐全', () async {
    for (final m in <String>['a', 'b', 'c']) {
      entry('logcat', m);
    }
    entry('flutter', 'hello world');
    final body = await getLogs('?limit=2');
    expect(body['ok'], isTrue);
    expect(body['total'], 4);
    expect(body['count'], 2);
    expect(items(body).map((e) => e['msg']), <String>['c', 'hello world']);
    expect(body['hasMore'], isFalse);
    expect(body['sources'], <String>['flutter', 'logcat']);
    // 每条都带齐 AI 需要的字段。
    for (final e in items(body)) {
      expect(e.keys, containsAll(<String>['ts', 'level', 'tag', 'msg', 'source', 'rcvMs']));
    }
  });

  test('keyword / source 过滤真的读进来了', () async {
    entry('logcat', 'ERROR boom', tag: 'AndroidRuntime');
    entry('logcat', 'ok');
    entry('flutter', 'error again');
    final byKeyword = await getLogs('?keyword=ERROR');
    expect(byKeyword['total'], 2);
    final bySource = await getLogs('?source=flutter');
    expect(bySource['total'], 1);
    expect(items(bySource).single['source'], 'flutter');
  });

  test('offset 游标翻页读完，不重不漏', () async {
    for (var i = 0; i < 5; i++) {
      entry('logcat', 'line-$i');
    }
    final seen = <String>[];
    var offset = 0;
    while (true) {
      final body = await getLogs('?tail=0&limit=2&offset=$offset');
      seen.addAll(items(body).map((e) => '${e['msg']}'));
      if (body['hasMore'] != true) break;
      offset = body['nextOffset'] as int;
    }
    expect(seen, <String>[
      'line-0',
      'line-1',
      'line-2',
      'line-3',
      'line-4',
    ]);
  });

  test('sinceMs 游标只拿新行（增量跟日志）', () async {
    entry('logcat', 'old');
    final first = await getLogs('?limit=10');
    final cursor = first['nextSinceMs'] as int;
    expect((await getLogs('?sinceMs=$cursor'))['total'], 0);
    entry('logcat', 'new');
    final next = await getLogs('?sinceMs=$cursor');
    expect(items(next).map((e) => e['msg']), <String>['new']);
    expect(next['nextSinceMs'] as int, greaterThan(cursor));
  });

  test('VM service token 在返回前打码', () async {
    entry('flutter', 'listening on http://127.0.0.1:61829/AbCdEf0123456789ABCDEF/');
    final body = await getLogs('?limit=10');
    final msg = '${items(body).single['msg']}';
    expect(msg, contains('http://127.0.0.1:61829/***'));
    expect(msg, isNot(contains('AbCdEf0123456789ABCDEF')));
  });
}
