// 直连会话的 Watch 辅助（无 eval）。
//
// VM 会话的监听是「按间隔 eval 字段/表达式」；AOT 没有 eval，直连只能轮询
// app 已经能给出的数据：`/v1/inspect` 的 inspectable 字段树、`/v1/sandbox/stat`
// 的文件元信息。这里放不依赖 io / flutter 的纯逻辑（路径取值、展示串、
// 条件比较），便于单测；轮询本身在 ide_gui.dart。
library;

/// 直连条件：`value <op> 字面量`（op ∈ `== != > >= < <=`）或
/// `value contains 字面量`；前后缀 `value` / `v` 可省略。两边都能解析成
/// 数字时按数字比，否则按字符串比。返回 null 表示语法不支持（添加时拒绝）。
bool? watchCondLite(String cond, String value) {
  final c = cond.trim();
  if (c.isEmpty) return null;
  final contains =
      RegExp(r'^(?:value|v|当前值)?\s*contains\s+(.+)$', caseSensitive: false)
          .firstMatch(c);
  if (contains != null) {
    return value.contains(_unquote(contains.group(1)!.trim()));
  }
  final m = RegExp(r'^(?:value|v|当前值)?\s*(==|!=|>=|<=|>|<)\s*(.+)$')
      .firstMatch(c);
  if (m == null) return null;
  final op = m.group(1)!;
  final rhs = _unquote(m.group(2)!.trim());
  final l = num.tryParse(value.trim());
  final r = num.tryParse(rhs);
  if (l != null && r != null) {
    return switch (op) {
      '==' => l == r,
      '!=' => l != r,
      '>' => l > r,
      '>=' => l >= r,
      '<' => l < r,
      _ => l <= r,
    };
  }
  final cmp = value.compareTo(rhs);
  return switch (op) {
    '==' => cmp == 0,
    '!=' => cmp != 0,
    '>' => cmp > 0,
    '>=' => cmp >= 0,
    '<' => cmp < 0,
    _ => cmp <= 0,
  };
}

/// 直连条件的报错文案（添加监听时用，避免让用户猜语法）。
String watchCondLiteHint() =>
    '直连会话条件只支持 value <op> 字面量（== != > >= < <=）或 value contains 文本';

String _unquote(String s) {
  if (s.length >= 2) {
    final q = s[0];
    if ((q == '"' || q == "'") && s.endsWith(q)) {
      return s.substring(1, s.length - 1);
    }
  }
  return s;
}

/// 从 `/v1/inspect` 的字段树里按路径取值（`count`、`items[0].name`；
/// 空路径 = 取整棵树）。路径不存在 / 超出已展开深度时抛 [FormatException]，
/// 由轮询层转成监听错误，不会静默返回旧值。
String agentWatchPick(Map<String, Object?> node, String path) {
  final p = path.trim();
  if (p.isEmpty) return agentWatchNodeText(node);
  var cur = node;
  final segs = p.split('.');
  for (final seg in segs) {
    if (seg.isEmpty) throw FormatException('字段路径有空段：$p');
    final m = RegExp(r'^([^\[\]]*)((?:\[\d+\])*)$').firstMatch(seg);
    if (m == null) throw FormatException('字段路径不合法：$p（在「$seg」处）');
    final name = m.group(1)!;
    if (name.isNotEmpty) {
      cur = _childNamed(cur, name, p);
    }
    for (final im in RegExp(r'\[(\d+)\]').allMatches(m.group(2)!)) {
      final idx = int.parse(im.group(1)!);
      cur = _childAt(cur, idx, p);
    }
  }
  return agentWatchNodeText(cur);
}

Map<String, Object?> _childNamed(
    Map<String, Object?> n, String name, String path) {
  for (final k in (n['children'] as List? ?? const <Object?>[])
      .whereType<Map>()) {
    if ('${k['name']}' == name) return k.cast<String, Object?>();
  }
  if (!n.containsKey('children')) {
    throw FormatException('「$path」超出已展开深度（看不到 $name）');
  }
  throw FormatException('字段路径不存在：$path（没有 $name）');
}

Map<String, Object?> _childAt(Map<String, Object?> n, int idx, String path) {
  final kids = (n['children'] as List? ?? const <Object?>[])
      .whereType<Map>()
      .toList();
  if (idx < 0 || idx >= kids.length) {
    if (!n.containsKey('children')) {
      throw FormatException('「$path」超出已展开深度');
    }
    throw FormatException('字段路径越界：$path（共 ${kids.length} 项）');
  }
  return kids[idx].cast<String, Object?>();
}

/// 字段树节点 → 单行展示文本。map / list 只展开一层子节点（子节点仅给
/// 标量值或 `map(n)` / `list(n)` 摘要），既能让变化对比稳定，又不会把整棵
/// 树灌进时间轴。
String agentWatchNodeText(Map<String, Object?> n) {
  final kind = '${n['kind'] ?? ''}';
  if (kind == 'value') return n['value'] == null ? 'null' : '${n['value']}';
  if (kind == 'opaque') return '<${n['cls'] ?? '?'}…>';
  final kids =
      (n['children'] as List? ?? const <Object?>[]).whereType<Map>().toList();
  final len = (n['length'] as num?)?.toInt() ?? kids.length;
  if (!n.containsKey('children')) {
    // 展开层数用尽：只报条目数（再深的变化这个监听看不到，需要缩短路径）。
    return '$kind($len)';
  }
  if (kind == 'list') {
    return 'list($len)[${kids.map(_scalarOrTag).join(', ')}]';
  }
  if (kind == 'map') {
    final body = kids.map((k) => '${k['name']}: ${_scalarOrTag(k)}').join(', ');
    return 'map($len){$body}';
  }
  return '${kind.isEmpty ? 'node' : kind}($len)';
}

String _scalarOrTag(Map k) {
  final kind = '${k['kind'] ?? ''}';
  if (kind == 'value') return k['value'] == null ? 'null' : '${k['value']}';
  if (kind == 'opaque') return '<${k['cls'] ?? '?'}…>';
  final kids = (k['children'] as List? ?? const <Object?>[]).whereType<Map>();
  final len = (k['length'] as num?)?.toInt() ?? kids.length;
  return kind == 'list' ? 'list($len)' : 'map($len)';
}