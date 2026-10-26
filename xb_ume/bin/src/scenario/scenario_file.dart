// 场景文件定位与解析（CLI 与单测共用）。
library;

import 'dart:convert';
import 'dart:io';

import '../paths.dart';

export '../paths.dart' show xbUmeHome;

/// 场景解析：已存在的路径优先，否则按名字在数据目录 scenarios 下找。
File? resolveScenarioFile(String arg) {
  final direct = File(arg);
  if (direct.existsSync()) return direct;
  final name = arg.endsWith('.json') ? arg.substring(0, arg.length - 5) : arg;
  final f = File('${xbUmeHome()}/scenarios/$name.json');
  return f.existsSync() ? f : null;
}

/// 读取场景文件：支持纯数组或 {name, steps}；返回（名称, 步骤列表）。
(String, List<Map<String, dynamic>>) loadScenario(File f) {
  final raw = jsonDecode(f.readAsStringSync());
  var name = f.uri.pathSegments.last.replaceAll(RegExp(r'\.json$'), '');
  List<dynamic> steps;
  if (raw is List) {
    steps = raw;
  } else if (raw is Map) {
    if ((raw['name'] ?? '').toString().isNotEmpty) {
      name = raw['name'].toString();
    }
    steps = raw['steps'] as List? ?? <dynamic>[];
  } else {
    throw const FormatException('场景 JSON 必须是步骤数组或 {name, steps} 对象');
  }
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < steps.length; i++) {
    final s = steps[i];
    if (s is! Map) throw FormatException('第 ${i + 1} 步不是 JSON 对象');
    out.add(Map<String, dynamic>.from(s));
  }
  if (out.isEmpty) throw const FormatException('场景没有步骤');
  return (name, out);
}
