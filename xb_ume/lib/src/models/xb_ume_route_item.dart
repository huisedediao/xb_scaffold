enum XBUmeRouteAction {
  push,
  pop,
  replace,
  remove,
}

class XBUmeRouteItem {
  XBUmeRouteItem({
    required this.id,
    required this.time,
    required this.action,
    required this.routeName,
    this.previousRouteName,
  });

  final String id;
  final DateTime time;
  final XBUmeRouteAction action;
  final String routeName;
  final String? previousRouteName;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'time': time.toIso8601String(),
      'action': action.name,
      'routeName': routeName,
      'previousRouteName': previousRouteName,
    };
  }

  factory XBUmeRouteItem.fromJson(Map<String, dynamic> json) {
    return XBUmeRouteItem(
      id: json['id'] as String? ?? '',
      time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
      action: XBUmeRouteAction.values.firstWhere(
        (e) => e.name == json['action'],
        orElse: () => XBUmeRouteAction.push,
      ),
      routeName: json['routeName'] as String? ?? '',
      previousRouteName: json['previousRouteName'] as String?,
    );
  }
}
