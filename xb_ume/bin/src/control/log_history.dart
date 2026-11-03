// GUI 日志历史的查询与分页（设备日志 + flutter 输出混在同一份缓冲里）。
//
// GUI 把每条日志塞进 GuiState.buffer（每来源 1000 条、总量 5000 条），但对外
// 只有「全量导出 /api/logs.txt」——AI 想读某一段、只要 error、只要某台设备，
// 就得先把整份文件下下来再自己 grep。这里补一个纯函数分页器：
// `/api/logs` 与 MCP 的 `xbume_log_history` 共用同一份实现，也因此可单测
// （不依赖 GUI 进程与真实设备）。
//
// 两个游标（都返回给调用方）：
// - nextOffset：逻辑下标，适合「一次读完」的翻页；缓冲被裁剪后下标会前移，
//   所以长时间跟日志不要只靠它；
// - nextSinceMs：最后一条的收到时间 +1ms，适合增量轮询（不会因裁剪丢行，
//   也不会重复）。
library;

/// 一次查询的参数。字段与 `/api/logs` 的 query 参数一一对应。
class GuiLogQuery {
  const GuiLogQuery({
    this.keyword,
    this.source,
    this.sinceMs,
    this.offset = 0,
    this.limit = 200,
    this.tail = true,
    this.maxChars = 400,
  });

  /// 消息或 tag 包含该关键字（忽略大小写）。
  final String? keyword;

  /// 来源精确匹配：flutter / logcat / hilog / ios / adb …（见返回的 sources）。
  final String? source;

  /// 只看收到时间 >= 该毫秒时间戳的行。
  final int? sinceMs;

  /// 逻辑起始下标（配合 tail=false 翻页）。
  final int offset;

  /// 本次最多返回多少条（1..2000）。
  final int limit;

  /// 默认 true：offset<=0 时直接取末尾 limit 条（想看最新日志的常见用法）。
  final bool tail;

  /// 单条消息最多保留多少字符（超长日志不把上下文撑爆）。
  final int maxChars;
}

/// 分页结果。
class GuiLogPage {
  const GuiLogPage({
    required this.items,
    required this.total,
    required this.nextOffset,
    required this.hasMore,
    required this.nextSinceMs,
    required this.sources,
  });

  final List<Map<String, Object?>> items;

  /// 过滤后的总条数（不是本次返回条数）。
  final int total;

  /// 下一次 tail=false 的 offset。
  final int nextOffset;

  /// 还有没有更后面的行（按 nextOffset 判断）。
  final bool hasMore;

  /// 下一次 sinceMs 的取值（最后一条收到时间 +1ms；没有行时原样返回）。
  final int nextSinceMs;

  /// 缓冲里出现过的全部来源，供调用方决定 source 传什么。
  final List<String> sources;
}

/// 在 GUI 日志缓冲上做「过滤 + 分页」。
GuiLogPage queryGuiLog(
  List<Map<String, Object?>> buffer, [
  GuiLogQuery query = const GuiLogQuery(),
]) {
  final kw = query.keyword?.trim().toLowerCase();
  final wantSource = query.source?.trim();
  final since = query.sinceMs;

  final matched = <Map<String, Object?>>[];
  for (final e in buffer) {
    final source = '${e['source'] ?? ''}';
    if (wantSource != null &&
        wantSource.isNotEmpty &&
        source != wantSource) {
      continue;
    }
    if (since != null) {
      final ms = _rcvMs(e);
      if (ms == null || ms < since) continue;
    }
    if (kw != null && kw.isNotEmpty) {
      final hay = '${e['msg'] ?? ''}\u0001${e['tag'] ?? ''}'.toLowerCase();
      if (!hay.contains(kw)) continue;
    }
    matched.add(e);
  }

  final total = matched.length;
  final limit = query.limit.clamp(1, 2000);
  var start = query.offset < 0 ? 0 : query.offset;
  // tail：offset<=0 时取末尾 limit 条（默认用法），否则从 offset 往后。
  if (query.tail && query.offset <= 0 && total > limit) start = total - limit;
  if (start > total) start = total;
  final end = (start + limit) > total ? total : start + limit;

  final items = <Map<String, Object?>>[];
  var nextSinceMs = query.sinceMs ?? 0;
  for (var i = start; i < end; i++) {
    final e = matched[i];
    final ms = _rcvMs(e);
    if (ms != null && ms + 1 > nextSinceMs) nextSinceMs = ms + 1;
    items.add(<String, Object?>{
      'ts': e['ts'],
      'level': e['level'],
      'tag': e['tag'],
      'msg': _clip('${e['msg'] ?? ''}', query.maxChars),
      'source': e['source'],
      'rcvMs': ms,
      if (e['device'] != null) 'device': e['device'],
      if (e['app'] != null) 'app': e['app'],
    });
  }

  final sources = buffer
      .map((e) => '${e['source'] ?? ''}')
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList()
    ..sort();

  return GuiLogPage(
    items: items,
    total: total,
    nextOffset: end,
    hasMore: end < total,
    nextSinceMs: nextSinceMs,
    sources: sources,
  );
}

int? _rcvMs(Map<String, Object?> entry) {
  final raw = entry['rcvMs'];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse('${raw ?? ''}');
}

String _clip(String text, int maxChars) {
  final limit = maxChars.clamp(40, 4000);
  if (text.length <= limit) return text;
  return '${text.substring(0, limit)}…';
}
