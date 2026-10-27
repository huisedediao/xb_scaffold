/// 从 Flutter 错误输出里提取「错误相关 widget」的源码位置。
///
/// Flutter 在 build / layout / paint 出错时，会把定位信息放进
/// `FlutterErrorDetails.informationCollector`，渲染成：
///
/// ```text
/// The relevant error-causing widget was:
///   Row Row:file:///Users/me/My%20App/lib/pages/order_row.dart:42:12
/// ```
///
/// 这段文本是框架 debug 期唯一的「运行时对象 → 源码」通道，但只在 debug
/// 下存在。这里只做**纯字符串解析**，不依赖 Flutter，便于在普通 Dart 环境单测；
/// 采集侧只管把 collector 的文本喂进来。
class XBUmeErrorSource {
  const XBUmeErrorSource({
    required this.widgetType,
    required this.file,
    required this.line,
    required this.column,
    required this.raw,
  });

  /// 错误相关 widget 的类型名，如 `Row`、`_OrderItemTile`。取不到时为空串。
  final String widgetType;

  /// 本地绝对路径（已把 `file:///` 与百分号编码还原）。
  final String file;

  /// 1 基行号。
  final int line;

  /// 1 基列号。
  final int column;

  /// 命中的原始行（已 trim），供排查解析偏差。
  final String raw;

  /// 位置片段：`file:///...dart:42:12`。路径可能含空格，用非贪婪 + 行尾/右括号边界。
  static final RegExp _location =
      RegExp(r'(file:\/\/\/[^\n]*?\.dart):(\d+):(\d+)(?=[\s)]|$)');

  static final RegExp _hint =
      RegExp(r'relevant error-causing widget', caseSensitive: false);

  /// 解析一段错误文本；没有可用位置时返回 null。
  ///
  /// 优先读「The relevant error-causing widget was:」之后的三行——同一个
  /// 错误文本里通常还夹着 stack trace 的 `package:` 行和引擎的 `file:///`
  /// 帧，直接全文取第一处容易抓到 framework 自身。
  static XBUmeErrorSource? parse(String? text) {
    if (text == null || text.isEmpty) return null;
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    var hintAt = -1;
    for (var i = 0; i < lines.length; i++) {
      if (_hint.hasMatch(lines[i])) {
        hintAt = i;
        break;
      }
    }
    if (hintAt >= 0) {
      final end = hintAt + 4 < lines.length ? hintAt + 4 : lines.length;
      for (var i = hintAt; i < end; i++) {
        final hit = _parseLine(lines[i]);
        if (hit != null) return hit;
      }
    }
    for (final line in lines) {
      final hit = _parseLine(line);
      if (hit != null) return hit;
    }
    return null;
  }

  static XBUmeErrorSource? _parseLine(String line) {
    final m = _location.firstMatch(line);
    if (m == null) return null;
    final uri = m.group(1)!;
    final lineNo = int.tryParse(m.group(2)!);
    final columnNo = int.tryParse(m.group(3)!);
    if (lineNo == null || columnNo == null || lineNo <= 0) return null;
    final path = _toFilePath(uri);
    if (path == null || path.isEmpty) return null;
    return XBUmeErrorSource(
      widgetType: _widgetTypeOf(line.substring(0, m.start)),
      file: path,
      line: lineNo,
      column: columnNo,
      raw: line.trim(),
    );
  }

  /// `Row Row:` / `KeyedSubtree:` / 空 → 取首个 token 并去掉尾部冒号。
  static String _widgetTypeOf(String head) {
    var text = head.trim();
    if (text.endsWith(':')) text = text.substring(0, text.length - 1);
    final tokens = text
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) return '';
    var first = tokens.first;
    if (first.endsWith(':')) first = first.substring(0, first.length - 1);
    return first;
  }

  static String? _toFilePath(String uri) {
    try {
      final parsed = Uri.parse(uri);
      if (parsed.scheme != 'file') return null;
      return parsed.toFilePath();
    } catch (_) {
      return null;
    }
  }
}
