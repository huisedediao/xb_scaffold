class XBUmeFrameItem {
  XBUmeFrameItem({
    required this.id,
    required this.time,
    required this.buildMs,
    required this.rasterMs,
    required this.totalMs,
    required this.isJank,
  });

  final String id;
  final DateTime time;
  final double buildMs;
  final double rasterMs;
  final double totalMs;
  final bool isJank;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'time': time.toIso8601String(),
      'buildMs': buildMs,
      'rasterMs': rasterMs,
      'totalMs': totalMs,
      'isJank': isJank,
    };
  }

  factory XBUmeFrameItem.fromJson(Map<String, dynamic> json) {
    return XBUmeFrameItem(
      id: json['id'] as String? ?? '',
      time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
      buildMs: (json['buildMs'] as num?)?.toDouble() ?? 0,
      rasterMs: (json['rasterMs'] as num?)?.toDouble() ?? 0,
      totalMs: (json['totalMs'] as num?)?.toDouble() ?? 0,
      isJank: json['isJank'] as bool? ?? false,
    );
  }
}
