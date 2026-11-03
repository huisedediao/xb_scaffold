// GUI 日志历史分页器（bin/src/control/log_history.dart）单测：
// tail 语义、offset 翻页不重不漏、关键字/来源/时间窗过滤、两个游标、截断。
//
// 只测纯函数，不起 GUI 进程；/api/logs 与 MCP 的 xbume_log_history 共用它。
library;

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/control/log_history.dart';

Map<String, Object?> _entry(
  String source,
  String msg, {
  int ms = 0,
  String tag = 'tag',
  String level = 'I',
}) {
  return <String, Object?>{
    'ts': '12:00:00',
    'level': level,
    'tag': tag,
    'msg': msg,
    'source': source,
    'rcvMs': ms,
  };
}

List<Map<String, Object?>> _buffer() => <Map<String, Object?>>[
      _entry('logcat', 'app start', ms: 1000, tag: 'ActivityManager'),
      _entry('flutter', 'I/flutter hello', ms: 2000, tag: 'flutter'),
      _entry('logcat', 'ERROR boom', ms: 3000, tag: 'AndroidRuntime', level: 'E'),
      _entry('flutter', 'debugPrint world', ms: 4000, tag: 'debugPrint'),
      _entry('logcat', 'error again', ms: 5000, tag: 'AndroidRuntime', level: 'E'),
    ];

void main() {
  test('默认 tail：取末尾 limit 条，total 仍是过滤后的全量', () {
    final page = queryGuiLog(_buffer(), const GuiLogQuery(limit: 2));
    expect(page.items.map((e) => e['msg']),
        <String>['debugPrint world', 'error again']);
    expect(page.total, 5);
    expect(page.nextOffset, 5);
    expect(page.hasMore, isFalse);
  });

  test('tail=false + offset：翻页覆盖全量且不重不漏', () {
    final buf = _buffer();
    final seen = <String>[];
    var offset = 0;
    while (true) {
      final page = queryGuiLog(buf,
          GuiLogQuery(offset: offset, limit: 2, tail: false, keyword: null));
      seen.addAll(page.items.map((e) => '${e['msg']}'));
      if (!page.hasMore) break;
      offset = page.nextOffset;
    }
    expect(seen, <String>[
      'app start',
      'I/flutter hello',
      'ERROR boom',
      'debugPrint world',
      'error again',
    ]);
  });

  test('keyword 忽略大小写，消息与 tag 都算命中', () {
    final byMsg = queryGuiLog(_buffer(), const GuiLogQuery(keyword: 'error'));
    expect(byMsg.total, 2);
    final byTag = queryGuiLog(_buffer(), const GuiLogQuery(keyword: 'androidruntime'));
    expect(byTag.total, 2);
    expect(byTag.items.first['level'], 'E');
  });

  test('source 精确过滤，sources 列出全部来源', () {
    final page = queryGuiLog(_buffer(), const GuiLogQuery(source: 'flutter'));
    expect(page.total, 2);
    expect(page.items.every((e) => e['source'] == 'flutter'), isTrue);
    expect(page.sources, <String>['flutter', 'logcat']);
  });

  test('sinceMs 只留新行，nextSinceMs 是最后一条 +1ms', () {
    final page = queryGuiLog(_buffer(), const GuiLogQuery(sinceMs: 3000));
    expect(page.items.map((e) => e['msg']),
        <String>['ERROR boom', 'debugPrint world', 'error again']);
    expect(page.nextSinceMs, 5001);
  });

  test('没有新行时 nextSinceMs 原样返回 sinceMs', () {
    final page = queryGuiLog(_buffer(), const GuiLogQuery(sinceMs: 9000));
    expect(page.items, isEmpty);
    expect(page.total, 0);
    expect(page.nextSinceMs, 9000);
  });

  test('maxChars 截断超长消息，默认保留完整', () {
    final long = 'x' * 500;
    final buf = <Map<String, Object?>>[_entry('flutter', long, ms: 1)];
    final clipped = queryGuiLog(buf, const GuiLogQuery(maxChars: 100));
    expect('${clipped.items.single['msg']}'.length, 101); // 100 + 省略号
    final full = queryGuiLog(buf, const GuiLogQuery(maxChars: 4000));
    expect(full.items.single['msg'], long);
  });

  test('offset 超过总数时不越界', () {
    final page =
        queryGuiLog(_buffer(), const GuiLogQuery(offset: 99, tail: false));
    expect(page.items, isEmpty);
    expect(page.total, 5);
    expect(page.nextOffset, 5);
    expect(page.hasMore, isFalse);
  });
}
