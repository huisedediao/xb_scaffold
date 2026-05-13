enum XBUmeLogLevel {
  debug,
  info,
  warn,
  error,
  fatal,
}

class XBUmeLogItem {
  XBUmeLogItem({
    required this.id,
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    this.stack,
  });

  final String id;
  final DateTime time;
  final XBUmeLogLevel level;
  final String tag;
  final String message;
  final String? stack;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'time': time.toIso8601String(),
      'level': level.name,
      'tag': tag,
      'message': message,
      'stack': stack,
    };
  }

  factory XBUmeLogItem.fromJson(Map<String, dynamic> json) {
    return XBUmeLogItem(
      id: json['id'] as String? ?? '',
      time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
      level: XBUmeLogLevel.values.firstWhere(
        (e) => e.name == json['level'],
        orElse: () => XBUmeLogLevel.info,
      ),
      tag: json['tag'] as String? ?? '',
      message: json['message'] as String? ?? '',
      stack: json['stack'] as String?,
    );
  }
}
