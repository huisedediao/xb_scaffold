// 断点落盘：GUI 重启 / 换会话后按项目根恢复。
//
// VM 的行为是「调试客户端断开就把该客户端建的断点一并删掉」，所以 GUI 一
// 重启断点表必然是空的。这里按「项目根 → 断点清单」记住用户设过的断点，
// 下次 start/attach 到同一项目时自动重下（重下失败多半是代码改过行号变了，
// 跳过并提示，不删记录——切回分支往往又能用）。
//
// 文件：$XB_UME_HOME/debug/breakpoints.json，结构：
//   {"version": 1, "projects": {"<绝对项目根>": [
//     {"path": "lib/main.dart", "line": 87, "column": null,
//      "condition": null, "logMessage": null, "enabled": true}]}}
// `path` 优先存相对项目根的路径（项目整体搬走后仍能用），项目外的文件存绝对路径。
library;

import 'dart:convert';
import 'dart:io';

import '../paths.dart';

/// 一条落盘的断点。
class SavedBreakpoint {
  const SavedBreakpoint({
    required this.path,
    required this.line,
    this.column,
    this.condition,
    this.logMessage,
    this.enabled = true,
  });

  /// 相对项目根的路径（项目外为绝对路径）。
  final String path;

  /// 1 基行号（存 VM 解析后的行，不是用户敲的那一行）。
  final int line;
  final int? column;

  /// 条件表达式（VM 不存，恢复时原样带回）。
  final String? condition;

  /// 日志断点表达式（命中求值、输出到调试输出后自动继续；VM 不存）。
  final String? logMessage;

  /// 是否启用；停用的断点恢复后立刻 setBreakpointState(false)。
  final bool enabled;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'line': line,
        if (column != null) 'column': column,
        if (condition != null) 'condition': condition,
        if (logMessage != null) 'logMessage': logMessage,
        'enabled': enabled,
      };

  static SavedBreakpoint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = '${raw['path'] ?? ''}'.trim();
    final line = raw['line'];
    if (path.isEmpty || line is! num || line < 1) return null;
    final column = raw['column'];
    final cond = raw['condition'];
    final log = raw['logMessage'];
    return SavedBreakpoint(
      path: path,
      line: line.toInt(),
      column: column is num ? column.toInt() : null,
      condition: cond is String && cond.trim().isNotEmpty ? cond.trim() : null,
      logMessage: log is String && log.trim().isNotEmpty ? log.trim() : null,
      enabled: raw['enabled'] != false,
    );
  }

  SavedBreakpoint copyWith({bool? enabled}) => SavedBreakpoint(
        path: path,
        line: line,
        column: column,
        condition: condition,
        logMessage: logMessage,
        enabled: enabled ?? this.enabled,
      );

  /// 是否同一位置（同文件同行；列只在两边都给时才参与比较）。
  bool sameLocation(SavedBreakpoint o) =>
      path == o.path &&
      line == o.line &&
      (column == null || o.column == null || column == o.column);

  @override
  String toString() => 'SavedBreakpoint($path:$line${enabled ? '' : ', off'}'
      '${condition == null ? '' : ', if $condition'}'
      '${logMessage == null ? '' : ', log $logMessage'})';
}

/// 断点清单的读写（小文件，同步 IO 够用；写盘走临时文件 + rename）。
class BreakpointStore {
  BreakpointStore({String? filePath})
      : filePath = filePath ?? '${xbUmeHome()}/debug/breakpoints.json';

  final String filePath;

  /// 项目根归一化：绝对路径、去掉尾部分隔符（Windows 的 `C:\` 需保留盘符）。
  static String normalizeRoot(String root) {
    var p = Directory(root).absolute.path;
    while (p.length > 1 && (p.endsWith('/') || p.endsWith(r'\'))) {
      final keep = p.endsWith(':${Platform.pathSeparator}');
      if (keep) break;
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  /// 项目内文件存相对路径，项目外存绝对路径。
  static String relativePathOf(String projectRoot, String path) {
    final root = normalizeRoot(projectRoot);
    final abs = File(path).absolute.path;
    final prefix = '$root${Platform.pathSeparator}';
    if (abs.startsWith(prefix)) return abs.substring(prefix.length);
    final alt = '$root/';
    if (abs.startsWith(alt)) return abs.substring(alt.length);
    return abs;
  }

  /// 相对路径还原成本机绝对路径（绝对路径原样返回）。
  static String absolutePathOf(String projectRoot, String path) {
    if (File(path).isAbsolute) return path;
    final root = normalizeRoot(projectRoot);
    final sep = root.endsWith('/') || root.endsWith(r'\') ? '' : Platform.pathSeparator;
    return File('$root$sep$path').absolute.path;
  }

  /// 读所有项目的清单（「已记住」总览用；坏文件 / 不存在都回空表）。
  Map<String, List<SavedBreakpoint>> loadAll() {
    final all = _readAll();
    return <String, List<SavedBreakpoint>>{
      for (final e in all.entries)
        if (e.value.isNotEmpty)
          e.key: List<SavedBreakpoint>.unmodifiable(e.value),
    };
  }

  /// 读某个项目的断点（坏文件 / 不存在都回空表，不抛）。
  List<SavedBreakpoint> load(String projectRoot) {
    final root = normalizeRoot(projectRoot);
    final all = _readAll();
    final list = all[root];
    if (list == null) return const <SavedBreakpoint>[];
    return List<SavedBreakpoint>.unmodifiable(list);
  }

  /// 覆盖某个项目的断点清单。
  void save(String projectRoot, List<SavedBreakpoint> items) {
    final root = normalizeRoot(projectRoot);
    final all = _readAll();
    if (items.isEmpty) {
      all.remove(root);
    } else {
      all[root] = List<SavedBreakpoint>.of(items);
    }
    _writeAll(all);
  }

  /// 记录一条（同位置覆盖，保留用户的 enabled）。返回是否新增。
  bool add(String projectRoot, SavedBreakpoint bp) {
    final root = normalizeRoot(projectRoot);
    final all = _readAll();
    final list = all[root] ?? <SavedBreakpoint>[];
    final i = list.indexWhere((x) => x.sameLocation(bp));
    if (i >= 0) {
      list[i] = bp;
      all[root] = list;
      _writeAll(all);
      return false;
    }
    list.add(bp);
    all[root] = list;
    _writeAll(all);
    return true;
  }

  /// 按位置删除。
  bool remove(String projectRoot, String path, int line, {int? column}) {
    final root = normalizeRoot(projectRoot);
    final all = _readAll();
    final list = all[root];
    if (list == null) return false;
    final probe = SavedBreakpoint(path: path, line: line, column: column);
    final before = list.length;
    list.removeWhere((x) => x.sameLocation(probe));
    if (list.length == before) return false;
    if (list.isEmpty) {
      all.remove(root);
    } else {
      all[root] = list;
    }
    _writeAll(all);
    return true;
  }

  /// 改启用状态。
  bool setEnabled(String projectRoot, String path, int line, bool enabled,
      {int? column}) {
    final root = normalizeRoot(projectRoot);
    final all = _readAll();
    final list = all[root];
    if (list == null) return false;
    final probe = SavedBreakpoint(path: path, line: line, column: column);
    var hit = false;
    for (var i = 0; i < list.length; i++) {
      if (!list[i].sameLocation(probe)) continue;
      list[i] = list[i].copyWith(enabled: enabled);
      hit = true;
    }
    if (!hit) return false;
    all[root] = list;
    _writeAll(all);
    return true;
  }

  /// 忘掉某个项目的全部断点。返回删除条数。
  int clear(String projectRoot) {
    final root = normalizeRoot(projectRoot);
    final all = _readAll();
    final removed = all.remove(root)?.length ?? 0;
    if (removed > 0) _writeAll(all);
    return removed;
  }

  Map<String, List<SavedBreakpoint>> _readAll() {
    final f = File(filePath);
    if (!f.existsSync()) return <String, List<SavedBreakpoint>>{};
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is! Map) return <String, List<SavedBreakpoint>>{};
      final projects = decoded['projects'];
      if (projects is! Map) return <String, List<SavedBreakpoint>>{};
      final out = <String, List<SavedBreakpoint>>{};
      projects.forEach((k, v) {
        final key = '${k ?? ''}'.trim();
        if (key.isEmpty || v is! List) return;
        final list = <SavedBreakpoint>[];
        for (final item in v) {
          final bp = SavedBreakpoint.fromJson(item);
          if (bp != null) list.add(bp);
        }
        if (list.isNotEmpty) out[normalizeRoot(key)] = list;
      });
      return out;
    } catch (_) {
      // 半写入 / 手改坏了：当空表，下次写回时覆盖。
      return <String, List<SavedBreakpoint>>{};
    }
  }

  void _writeAll(Map<String, List<SavedBreakpoint>> all) {
    final f = File(filePath);
    final dir = f.parent;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final data = <String, Object?>{
      'version': 1,
      'projects': <String, Object?>{
        for (final e in all.entries)
          e.key: <Object?>[for (final bp in e.value) bp.toJson()],
      },
    };
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
    // Windows 上 rename 到已存在的文件会失败，先删再换（单进程写，够用）。
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    tmp.renameSync(f.path);
  }
}
