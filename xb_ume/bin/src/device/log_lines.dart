// 设备日志行的统一过滤 / 裁剪。
//
// 四个平台的 dump 行格式各不相同（logcat `MM-DD HH:MM:SS.mmm D/Tag( pid): msg`、
// hilog `... pid tid I C01800/Tag: msg`、iOS syslog `... <Notice>: msg`、
// simctl compact `... [Notice] msg`），但"按级别 / tag / 关键字筛，取最后 N 条"
// 的需求是一致的。这里只做宽松识别：认不出级别的行一律保留（宁可多回，
// 也不要把真正的错误行误杀），单测锁定几条真实样本。
library;

/// 过滤结果。
class DeviceLogFiltered {
  const DeviceLogFiltered({
    required this.lines,
    required this.total,
    required this.matched,
  });

  /// 过滤后保留的最后 [limit] 条。
  final List<String> lines;

  /// dump 的原始行数。
  final int total;

  /// 过滤后（截断前）的命中行数。
  final int matched;
}

const Map<String, int> _levelRank = <String, int>{
  'V': 0,
  'D': 1,
  'I': 2,
  'W': 3,
  'E': 4,
  'F': 5,
};

/// iOS 日志级别名 → 单字母级别（与 logcat 对齐后再比较）。
const Map<String, String> _iosLevel = <String, String>{
  'trace': 'V',
  'debug': 'D',
  'info': 'I',
  'notice': 'I',
  'default': 'I',
  'warning': 'W',
  'error': 'E',
  'fault': 'F',
  'critical': 'F',
};

/// 识别一行的级别；认不出返回 null（调用方按"保留"处理）。
String? lineLevel(String line) {
  // 时间戳开头才能当"日志头"解析，避免正文里出现 E/xxx 被误认：
  //   logcat -v time     `10-26 17:00:00.001 D/Tag( 1234): msg`
  //   logcat threadtime  `10-26 17:00:00.001  4321  4321 E AndroidRuntime: msg`
  //   hilog              `01-01 08:00:00.000  1234  5678 I C01800/MyTag: msg`
  final head = RegExp(
    r'^\d{2}-\d{2}\s+[\d:.]+\s+(?:\d+\s+\d+\s+)?([VDIWEF])(?:/|\s)',
  ).firstMatch(line);
  if (head != null) return head.group(1);
  // iOS：`... <Notice>: msg` / `... [Error] msg`
  final named = RegExp(
    r'[<\[(](trace|debug|info|notice|default|warning|error|fault|critical)[>\])]',
    caseSensitive: false,
  ).firstMatch(line);
  if (named != null) return _iosLevel[named.group(1)!.toLowerCase()];
  return null;
}

/// 一项过滤条件（供单测与工具层复用）。
class DeviceLogQuery {
  const DeviceLogQuery({this.keyword, this.tag, this.level, this.limit = 1000});

  final String? keyword;
  final String? tag;

  /// 最低级别 V/D/I/W/E/F；空表示不筛。
  final String? level;
  final int limit;
}

/// 过滤一份 dump 文本。
DeviceLogFiltered filterDeviceLog(String raw, {DeviceLogQuery query = const DeviceLogQuery()}) {
  final all = <String>[
    for (final line in raw.split('\n'))
      if (line.replaceAll('\r', '').trim().isNotEmpty) line.replaceAll('\r', ''),
  ];
  final kw = query.keyword?.trim().toLowerCase();
  final tag = query.tag?.trim();
  final want = query.level?.trim().toUpperCase();
  final minRank = (want == null || want.isEmpty)
      ? null
      : _levelRank[want[0]];
  final hits = <String>[];
  for (final line in all) {
    if (kw != null && kw.isNotEmpty && !line.toLowerCase().contains(kw)) continue;
    if (tag != null && tag.isNotEmpty && !line.contains(tag)) continue;
    if (minRank != null) {
      final lv = lineLevel(line);
      final rank = lv == null ? null : _levelRank[lv];
      // 认不出级别的行照旧保留：严格过滤会把多行异常栈整段丢掉。
      if (rank != null && rank < minRank) continue;
    }
    hits.add(line);
  }
  final limit = query.limit <= 0 ? hits.length : query.limit;
  final kept = hits.length > limit ? hits.sublist(hits.length - limit) : hits;
  return DeviceLogFiltered(lines: kept, total: all.length, matched: hits.length);
}
