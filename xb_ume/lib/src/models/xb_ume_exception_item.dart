/// 异常来源：框架错误（FlutterError.onError）/ 平台未捕获 / 应用主动上报。
enum XBUmeExceptionKind {
  flutter,
  platform,
  app,
}

/// 结构化异常记录。
///
/// 与日志里的 error/fatal 行不同：这里保留异常类型、库/上下文、完整栈与重复
/// 次数，供 GUI 异常面板与 MCP `xbume_exceptions` 直接读取，不必再从一行文本
/// 里正则反解析。
class XBUmeExceptionItem {
  XBUmeExceptionItem({
    required this.id,
    required this.time,
    required this.kind,
    required this.type,
    required this.message,
    required this.signature,
    this.stack,
    this.library,
    this.context,
    this.count = 1,
  });

  final String id;

  /// 最近一次发生时间（重复异常合并时刷新）。
  final DateTime time;

  final XBUmeExceptionKind kind;

  /// 异常 runtimeType，如 `_TypeError`、`Exception`。
  final String type;

  /// 异常摘要（FlutterError 用 exceptionAsString()），已裁剪。
  final String message;

  /// 去重签名：type + message + 栈首帧。
  final String signature;

  /// 栈原文（已裁剪），可能为空。
  final String? stack;

  /// 抛出位置所属库，如 `widgets library`。
  final String? library;

  /// 框架给的上下文，如 `While building ListView`。
  final String? context;

  /// 相同签名的合并次数。
  final int count;

  XBUmeExceptionItem copyWith({
    DateTime? time,
    int? count,
  }) {
    return XBUmeExceptionItem(
      id: id,
      time: time ?? this.time,
      kind: kind,
      type: type,
      message: message,
      signature: signature,
      stack: stack,
      library: library,
      context: context,
      count: count ?? this.count,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'time': time.toIso8601String(),
      'kind': kind.name,
      'type': type,
      'message': message,
      'signature': signature,
      'stack': stack,
      'library': library,
      'context': context,
      'count': count,
    };
  }

  factory XBUmeExceptionItem.fromJson(Map<String, dynamic> json) {
    return XBUmeExceptionItem(
      id: json['id'] as String? ?? '',
      time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
      kind: XBUmeExceptionKind.values.firstWhere(
        (e) => e.name == json['kind'],
        orElse: () => XBUmeExceptionKind.app,
      ),
      type: json['type'] as String? ?? '',
      message: json['message'] as String? ?? '',
      signature: json['signature'] as String? ?? '',
      stack: json['stack'] as String?,
      library: json['library'] as String?,
      context: json['context'] as String?,
      count: (json['count'] as num?)?.toInt() ?? 1,
    );
  }
}
