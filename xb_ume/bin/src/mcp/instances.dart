// MCP 实例登记：一 AI 一个 MCP 进程时，用一份可读清单回答
// 「现在有哪些实例、各自跑在哪、谁带 eval」。
//
// 落盘 $XB_UME_HOME/mcp/instances/<实例名>.json，进程退出即删；读清单时按 pid
// 存活自动清掉残留。GUI 是单文件部署、不 import bin/src，所以它在 ide_gui.dart
// 里读同一份目录（字段名必须一致）。
library;

import 'dart:convert';
import 'dart:io';

import '../device/live_store.dart' show pidAlive;
import '../paths.dart';

/// 实例名允许的字符（不含空格与路径分隔符，文件名直接用）。
String sanitizeInstanceName(String raw) {
  final s = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.\-\u4e00-\u9fa5]'), '-');
  if (s.isEmpty) return '';
  return s.length > 40 ? s.substring(0, 40) : s;
}

/// 默认实例名：HTTP 按端口（人读方便），stdio 按 pid（一个客户端一个进程）。
String defaultInstanceName({required bool http, required int port}) =>
    http ? 'mcp-$port' : 'mcp-$pid';

Directory instancesDir({String? home}) {
  final d = Directory('${home ?? xbUmeHome()}/mcp/instances');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

File instanceFile(String name, {String? home}) {
  final safe = sanitizeInstanceName(name);
  return File('${instancesDir(home: home).path}/$safe.json');
}

/// 读一个实例的登记（不管死活）。
Map<String, Object?>? readInstance(String name, {String? home}) {
  final f = instanceFile(name, home: home);
  try {
    if (!f.existsSync()) return null;
    final j = jsonDecode(f.readAsStringSync());
    return j is Map ? j.map((k, v) => MapEntry(k.toString(), v)) : null;
  } catch (_) {
    return null;
  }
}

/// 列出登记过的实例；[prune] 时把 pid 已不在的残留文件删掉。
List<Map<String, Object?>> listInstances({String? home, bool prune = true}) {
  final out = <Map<String, Object?>>[];
  try {
    for (final e in instancesDir(home: home).listSync()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      Map<String, Object?>? rec;
      try {
        final j = jsonDecode(e.readAsStringSync());
        if (j is Map) rec = j.map((k, v) => MapEntry(k.toString(), v));
      } catch (_) {
        rec = null;
      }
      final pid = int.tryParse('${rec?['pid'] ?? ''}') ?? 0;
      final alive = pid > 0 && pidAlive(pid);
      if (!alive && prune) {
        try {
          e.deleteSync();
        } catch (_) {}
        continue;
      }
      final name = '${rec?['name'] ?? e.uri.pathSegments.last.replaceAll('.json', '')}';
      out.add(<String, Object?>{
        ...?rec,
        'name': name,
        'pid': pid,
        'alive': alive,
      });
    }
  } catch (_) {
    // 目录读不了就当没有实例。
  }
  out.sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
  return out;
}

/// 写入（覆盖）一份实例登记；原子写避免 GUI 读到半截。
void writeInstance(Map<String, Object?> rec, {String? home}) {
  final name = sanitizeInstanceName('${rec['name'] ?? ''}');
  if (name.isEmpty) return;
  try {
    final f = instanceFile(name, home: home);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(<String, Object?>{...rec, 'name': name}));
    tmp.renameSync(f.path);
  } catch (_) {
    // 登记失败只影响「列出实例」，不影响服务本身。
  }
}

/// 删除登记；给了 [onlyPid] 时只在 pid 对得上时删（避免删掉同名新实例）。
void removeInstance(String name, {String? home, int? onlyPid}) {
  try {
    final f = instanceFile(name, home: home);
    if (!f.existsSync()) return;
    if (onlyPid != null) {
      final pid = int.tryParse('${readInstance(name, home: home)?['pid'] ?? ''}');
      if (pid != null && pid != onlyPid) return;
    }
    f.deleteSync();
  } catch (_) {}
}

/// 启动前查重：同名实例还活着、且不是自己 → 返回冲突记录。
Map<String, Object?>? instanceNameConflict(String name, {String? home}) {
  final rec = readInstance(name, home: home);
  if (rec == null) return null;
  final ownerPid = int.tryParse('${rec['pid'] ?? ''}') ?? 0;
  if (ownerPid <= 0 || ownerPid == pid || !pidAlive(ownerPid)) return null;
  return rec;
}
