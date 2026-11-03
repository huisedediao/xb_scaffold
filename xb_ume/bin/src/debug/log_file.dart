// flutter run 日志文件的分页 / 正则读取。
//
// DebugHub 内存里的 `_tail` 只有 300 行（GUI 面板够用，AI 验收不够）；
// 真正全量的是 logPath 指向的磁盘文件。这里按「行号游标 + 关键字/正则」
// 做增量扫描：一次最多扫 scanLines 行、返回 maxHits 条，游标 nextLine
// 交回调用方继续往下翻，直到 hasMore=false —— AI 用它就能读完整个文件，
// 而不必把几万行一次性塞进上下文。
library;

import 'dart:convert';
import 'dart:io';

/// 一次分页读取的结果。
class LogFilePage {
  const LogFilePage({
    required this.lines,
    required this.nextLine,
    required this.hasMore,
    required this.scanned,
    required this.matched,
    this.totalLines,
  });

  /// 已截断（maxChars）并按需加行号前缀的行。
  final List<String> lines;

  /// 下一页的起始行号（1-based）；与 hasMore 一起构成游标。
  final int nextLine;

  /// true 表示还有没扫到的行（因为命中数 / 扫描上限提前停下）。
  final bool hasMore;

  /// 本次实际扫描的行数。
  final int scanned;

  /// 本次命中的条数（无过滤时等于 lines.length）。
  final int matched;

  /// 文件总行数；只在扫到文件末尾时能确定，否则为 null。
  final int? totalLines;
}

/// 读取日志文件的一页。
///
/// - [offsetLine] 1-based 起始行；`<= 0` 且无过滤时表示「取末尾 maxHits 行」
///   （tail 语义，符合人的直觉）。
/// - [keyword] 子串匹配（忽略大小写）；[regex] 与之二选一，正则优先。
/// - 过滤是**从 offsetLine 起连续扫描**，命中收集满 maxHits 就停，因此
///   游标式多次调用即可覆盖全文件（边过滤边翻页）。
/// - [maxChars] 单行截断，避免某行几万字符撑爆上下文。
Future<LogFilePage> readLogPage(
  String path, {
  int offsetLine = 0,
  int maxHits = 200,
  int scanLines = 20000,
  String? keyword,
  String? regex,
  int maxChars = 400,
  bool withLineNo = true,
}) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('日志文件不存在', path);
  }
  final kw = (keyword == null || keyword.trim().isEmpty)
      ? null
      : keyword.trim().toLowerCase();
  final re = (regex == null || regex.isEmpty) ? null : RegExp(regex);
  final fromEnd = offsetLine <= 0 && kw == null && re == null;

  final ring = <(int, String)>[]; // fromEnd：保留最后 maxHits 行
  final hits = <(int, String)>[];
  var lineNo = 0;
  var scanned = 0;
  var next = offsetLine <= 0 ? 1 : offsetLine;
  var stopped = false;

  final stream = file
      .openRead()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());
  await for (final raw in stream) {
    lineNo++;
    if (lineNo < next) continue; // 游标之前的行直接跳过
    if (!fromEnd && scanned >= scanLines) {
      stopped = true;
      break;
    }
    scanned++;
    final shown =
        raw.length > maxChars ? '${raw.substring(0, maxChars)}…' : raw;
    if (fromEnd) {
      ring.add((lineNo, shown));
      if (ring.length > maxHits) ring.removeAt(0);
      next = lineNo + 1;
      continue;
    }
    final hit = re != null
        ? re.hasMatch(raw)
        : (kw == null || raw.toLowerCase().contains(kw));
    if (hit) {
      hits.add((lineNo, shown));
      if (hits.length >= maxHits) {
        stopped = true;
        next = lineNo + 1;
        break;
      }
    }
    next = lineNo + 1;
  }

  final picked = fromEnd ? ring : hits;
  return LogFilePage(
    lines: <String>[
      for (final (no, text) in picked) withLineNo ? '[$no] $text' : text,
    ],
    nextLine: next,
    hasMore: stopped,
    scanned: scanned,
    matched: picked.length,
    totalLines: stopped ? null : lineNo,
  );
}
