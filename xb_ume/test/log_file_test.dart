// 日志文件分页读取单测：用临时文件锁定「游标翻页不重不漏 + 过滤 + 截断」。
//
// 这条链路是 AI 验收的基础：它靠 nextLine/hasMore 反复调用把整个
// flutter run 日志读完，一旦漏行或重复，问题会以「AI 说没看到报错」的
// 形式暴露出来，所以这里按行为逐条钉死。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/debug/log_file.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xbume_logpage_');
    path = '${dir.path}/run.log';
    File(path).writeAsStringSync(
      List<String>.generate(100, (i) => 'line ${i + 1}').join('\n'),
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('无游标无过滤：取文件末尾 maxHits 行（tail 语义）', () async {
    final p = await readLogPage(path, maxHits: 5);
    expect(p.lines, hasLength(5));
    expect(p.lines.first, '[96] line 96');
    expect(p.lines.last, '[100] line 100');
    expect(p.hasMore, isFalse);
    expect(p.totalLines, 100);
    expect(p.nextLine, 101);
  });

  test('游标翻页：覆盖全文件且不重不漏', () async {
    final seen = <String>[];
    var cursor = 1;
    var rounds = 0;
    while (true) {
      final p = await readLogPage(path, offsetLine: cursor, maxHits: 30);
      seen.addAll(p.lines);
      rounds++;
      if (!p.hasMore) break;
      cursor = p.nextLine;
      expect(rounds, lessThan(10), reason: '游标没有前进会死循环');
    }
    expect(rounds, 4);
    expect(seen, hasLength(100));
    expect(seen.first, '[1] line 1');
    expect(seen.last, '[100] line 100');
  });

  test('keyword 过滤 + 游标：只回命中行，仍能扫完', () async {
    final first = await readLogPage(path, offsetLine: 1, maxHits: 3, keyword: 'line 5');
    // line 5 / 50~59 都命中，够 3 条就停
    expect(first.lines, <String>[
      '[5] line 5',
      '[50] line 50',
      '[51] line 51',
    ]);
    expect(first.hasMore, isTrue);
    final next = await readLogPage(path, offsetLine: first.nextLine, maxHits: 3,
        keyword: 'line 5');
    expect(next.lines.first, '[52] line 52');
  });

  test('regex 优先于 keyword，且非法正则抛 FormatException', () async {
    final p = await readLogPage(path, offsetLine: 1, maxHits: 2,
        regex: r'^line 9\d$', keyword: '不存在的关键字');
    expect(p.lines, <String>['[90] line 90', '[91] line 91']);
    expect(
      () => readLogPage(path, offsetLine: 1, regex: '('),
      throwsA(isA<FormatException>()),
    );
  });

  test('maxChars 截断超长行', () async {
    File('${dir.path}/long.log').writeAsStringSync('x' * 500);
    final p = await readLogPage('${dir.path}/long.log', maxHits: 1, maxChars: 10);
    expect(p.lines.single, '[1] xxxxxxxxxx…');
  });

  test('scanLines 限制单次扫描量，hasMore 保持 true', () async {
    final p = await readLogPage(path, offsetLine: 1, maxHits: 100, scanLines: 10);
    expect(p.scanned, 10);
    expect(p.lines, hasLength(10));
    expect(p.nextLine, 11);
    expect(p.hasMore, isTrue);
    expect(p.totalLines, isNull);
  });

  test('withLineNo=false 时只回原文', () async {
    final p = await readLogPage(path, maxHits: 1, withLineNo: false);
    expect(p.lines.single, 'line 100');
  });

  test('文件不存在抛 FileSystemException', () async {
    expect(
      () => readLogPage('${dir.path}/missing.log'),
      throwsA(isA<FileSystemException>()),
    );
  });
}
