// 直连会话的启发式源码定位（无 VM）。
//
// VM 会话说「路由子树里第一个业务 widget 的类 → 库 uri → 本机文件」；AOT 没有
// 这条路：只能拿 app 上报的路由名，推几个常见类名候选，再到项目源码里找声明。
// 结果是**候选**而不是精确位置（`srclocate:heuristic`），命中多个同名类时
// 取候选优先级最高的那个。
//
// 纯 dart:io，不依赖 flutter，便于单测与 `dart run xb_ume:ide` 直接调用。
library;

import 'dart:io';

/// 路由名 → 候选 Widget 类名。
///
/// 覆盖常见命名：`/user/detail` → `UserDetailPage` / `UserDetailScreen` /
/// `UserDetail` / `UserDetailWidget`；`UserDetailPage` 原样保留。返回去重后的
/// 候选（类名在前，PascalCase 兜底在后）。
List<String> routeClassCandidates(String routeName) {
  final raw = routeName.trim();
  if (raw.isEmpty) return const <String>[];
  final out = <String>[];
  void add(String v) {
    if (v.isEmpty || out.contains(v)) return;
    out.add(v);
  }

  // 已经是类名（PascalCase、不含分隔符）时优先原样试。
  if (RegExp(r'^[A-Z][A-Za-z0-9_$]*$').hasMatch(raw)) add(raw);

  // `/user/detail`、`user_detail`、`user-detail` → UserDetail。
  final words = raw
      .split(RegExp(r'[^A-Za-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return out;
  final pascal = words
      .map((w) => w[0].toUpperCase() + (w.length > 1 ? w.substring(1) : ''))
      .join();
  for (final suffix in const <String>['Page', 'Screen', 'View', 'Widget']) {
    add('$pascal$suffix');
  }
  add(pascal);
  return out;
}

/// 启发式定位结果。
class RouteLocateHit {
  const RouteLocateHit({
    required this.file,
    required this.line,
    required this.className,
    required this.candidates,
    required this.scannedFiles,
  });

  final String file;
  final int line;
  final String className;

  /// 试过的候选类名（按优先级），便于调用方解释为什么是这个结果。
  final List<String> candidates;

  final int scannedFiles;

  Map<String, Object?> toJson() => <String, Object?>{
        'file': file,
        'line': line,
        'className': className,
        'candidates': candidates,
        'scanned': scannedFiles,
        'heuristic': true,
      };
}

/// 在 [projectRoot] 下按 [candidates] 找类声明。
///
/// 优先扫 `<root>/lib`（没有则扫 root 本身），跳过隐藏目录 / build / 生成文件；
/// 文件数与目录深度都有上限，避免在大仓库里扫到天荒地老。候选优先级高于
/// 文件顺序：`A` 命中就不会再去用 `B` 的结果。
RouteLocateHit? findClassInProject(
  String projectRoot,
  List<String> candidates, {
  int maxFiles = 4000,
}) {
  if (projectRoot.isEmpty || candidates.isEmpty) return null;
  final rootDir = Directory('$projectRoot/lib');
  final root = rootDir.existsSync() ? rootDir.path : projectRoot;
  if (!Directory(root).existsSync()) return null;

  final hits = <String, ({String file, int line})>{};
  final pending = <String>[root];
  var scanned = 0;
  while (pending.isNotEmpty && scanned < maxFiles) {
    final dir = pending.removeLast();
    List<FileSystemEntity> entries;
    try {
      entries = Directory(dir).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final e in entries) {
      if (scanned >= maxFiles) break;
      if (e is Directory) {
        final name = e.path.split(RegExp(r'[/\\]')).last;
        if (name.startsWith('.') || name == 'build') continue;
        pending.add(e.path);
        continue;
      }
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path.endsWith('.g.dart') ||
          e.path.endsWith('.freezed.dart') ||
          e.path.endsWith('.mocks.dart')) {
        continue;
      }
      scanned += 1;
      String src;
      try {
        src = e.readAsStringSync();
      } catch (_) {
        continue;
      }
      for (final c in candidates) {
        if (hits.containsKey(c)) continue;
        final line = classDeclLineInSource(src, c);
        if (line > 0) hits[c] = (file: e.path, line: line);
      }
    }
  }

  for (final c in candidates) {
    final hit = hits[c];
    if (hit == null) continue;
    return RouteLocateHit(
      file: hit.file,
      line: hit.line,
      className: c,
      candidates: candidates,
      scannedFiles: scanned,
    );
  }
  return null;
}

/// 在源码里找类声明所在行（1 起）；没找到返回 0。
int classDeclLineInSource(String source, String className) {
  final pattern = RegExp(
    '^(?:abstract\\s+|final\\s+|sealed\\s+|base\\s+|interface\\s+|mixin\\s+)*'
    '(?:class|enum|mixin|extension)\\s+${RegExp.escape(className)}\\b',
    multiLine: true,
  );
  final m = pattern.firstMatch(source);
  if (m == null) return 0;
  return '\n'.allMatches(source.substring(0, m.start)).length + 1;
}