/// 一次自动采集点击的语义指纹。
///
/// 由 [XBChainFingerprinter] 从命中 Element 向上遍历构建：
/// 不依赖任何调试服务，debug 与 release 均可产出。
class XBAutoTrackFingerprint {
  /// 命中组件向上到路由容器（或链深上限）的 Widget 类型链，根在前。
  final List<String> typeChain;

  /// 链长度（采集到的节点数）。
  final int depth;

  /// 命中时所在路由名（未命名路由为 null）。
  final String? routeName;

  /// 命中链上首个可读文本（Text/RichText/EditableText），已按上限截断。
  final String? text;

  /// 命中组件的构造点源码位置（`--track-widget-creation` 注入，
  /// 仅 debug/profile 可得，release 为 null）。file 为相对工程根路径。
  final String? file;

  /// 源码行号（1 起）。
  final int? line;

  /// 源码列号（1 起）。
  final int? column;

  const XBAutoTrackFingerprint({
    required this.typeChain,
    required this.depth,
    this.routeName,
    this.text,
    this.file,
    this.line,
    this.column,
  });

  Map<String, dynamic> toParams() {
    return <String, dynamic>{
      'typeChain': typeChain.join('>'),
      'depth': depth,
      if (routeName != null) 'routeName': routeName,
      if (text != null) 'text': text,
      if (file != null) 'file': file,
      if (line != null) 'line': line,
      if (column != null) 'column': column,
    };
  }

  /// 人可读描述，如 `HomePage>ItemCard>ElevatedButton("购买")`。
  String describe() {
    final label = text == null ? '' : '("$text")';
    return '${typeChain.join('>')}$label';
  }

  /// 带源码位置的人可读描述，如
  /// `ItemCard("购买") @ lib/pages/detail.dart:42:11`。
  String describeWithLocation() {
    final base = describe();
    if (file == null || line == null) return base;
    return '$base @ $file:$line${column == null ? '' : ':$column'}';
  }

  @override
  String toString() => 'XBAutoTrackFingerprint(${toParams()})';
}
