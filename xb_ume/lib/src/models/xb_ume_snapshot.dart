class XBUmeSnapshot {
  XBUmeSnapshot({
    required this.createdAt,
    required this.logs,
    required this.routes,
    required this.frames,
    required this.network,
  });

  final DateTime createdAt;
  final List<Map<String, dynamic>> logs;
  final List<Map<String, dynamic>> routes;
  final List<Map<String, dynamic>> frames;
  final List<Map<String, dynamic>> network;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'createdAt': createdAt.toIso8601String(),
      'logs': logs,
      'routes': routes,
      'frames': frames,
      'network': network,
    };
  }

  factory XBUmeSnapshot.fromJson(Map<String, dynamic> json) {
    return XBUmeSnapshot(
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      logs: ((json['logs'] as List?) ?? const <dynamic>[])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false),
      routes: ((json['routes'] as List?) ?? const <dynamic>[])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false),
      frames: ((json['frames'] as List?) ?? const <dynamic>[])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false),
      network: ((json['network'] as List?) ?? const <dynamic>[])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false),
    );
  }
}
