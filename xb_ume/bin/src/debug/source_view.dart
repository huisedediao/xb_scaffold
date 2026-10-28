// 调试页「源码下断点」用的只读文件视图：列项目里的 .dart、按行读源码。
//
// 只服务于「点行号下断点」，所以不做语法高亮、不做编辑、不监听文件变化。
// 路径一律相对项目根，读之前解析符号链接并确认仍在项目内（防 `../` 逃逸）。
library;

import 'dart:convert';
import 'dart:io';

import 'debug_client.dart' show DebugException;

/// 命中就整棵跳过的目录：构建产物、依赖缓存、IDE 元数据。
const Set<String> _skipDirs = <String>{
  '.dart_tool',
  'build',
  '.git',
  '.idea',
  '.vscode',
  '.gradle',
  'Pods',
  'node_modules',
  'oh_modules',
  'ephemeral',
  '.symlinks',
};

/// 一个文件的只读视图。
class SourceFileView {
  const SourceFileView({
    required this.abs,
    required this.path,
    required this.rel,
    required this.total,
    required this.lines,
    required this.truncated,
  });

  /// 项目根 + 相对路径拼出的绝对路径（未解析符号链接；断点路径就是这形状）。
  final String abs;

  /// 解析符号链接后的真实路径（只用于确认确实在项目内）。
  final String path;

  /// 相对项目根、`/` 分隔。
  final String rel;

  /// 文件总行数（截断前）。
  final int total;

  /// 截断后的源码行（不含换行符）。
  final List<String> lines;

  /// 是否因为超过 [maxLines] 被截断。
  final bool truncated;

  Map<String, Object?> toJson() => <String, Object?>{
        'abs': abs,
        'rel': rel,
        'total': total,
        'lines': lines,
        'truncated': truncated,
      };
}

/// 列项目根下的 `.dart`（相对路径、`/` 分隔、字典序）。
///
/// 跳过 [_skipDirs] 与隐藏目录，最多 [max] 个：这里是给人挑文件的，
/// 不需要穷举 pub 缓存里的几万个文件。
List<String> listDartFiles(String root, {int max = 2000}) {
  final base = _realDir(root);
  final out = <String>[];
  void walk(Directory dir, int depth) {
    if (out.length >= max || depth > 8) return;
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return; // 单个子目录没权限不影响其余
    }
    for (final e in entries) {
      if (out.length >= max) return;
      final name = _baseName(e.path);
      if (name.isEmpty) continue;
      if (e is Directory) {
        if (name.startsWith('.') || _skipDirs.contains(name)) continue;
        walk(e, depth + 1);
      } else if (e is File && name.toLowerCase().endsWith('.dart')) {
        out.add(_relOf(base, e.path));
      }
    }
  }

  walk(Directory(base), 0);
  out.sort();
  return out;
}

/// 读项目内某个 `.dart` 的源码行；越界、不是 .dart、不存在都抛 [DebugException]。
SourceFileView readSourceFile(
  String root,
  String rel, {
  int maxLines = 4000,
  int maxLineLen = 600,
}) {
  final base = _realDir(root);
  final clean = rel.trim().replaceAll('\\', '/');
  if (clean.isEmpty) throw DebugException('缺少源码路径（相对项目根）');
  if (clean.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(clean)) {
    throw DebugException('源码路径要相对项目根：$rel');
  }
  if (!clean.toLowerCase().endsWith('.dart')) {
    throw DebugException('只支持 .dart 文件：$rel');
  }
  final abs = File('$base${Platform.pathSeparator}'
          '${clean.replaceAll('/', Platform.pathSeparator)}')
      .absolute
      .path;
  // 断点清单里存的是这个「拼接后、未解析链接」的路径：前端靠它跟断点对齐。
  final back = _relOf(base, abs);
  final f = File(abs);
  if (!f.existsSync()) throw DebugException('文件不存在：$rel（换分支后路径可能变了）');
  final real = f.resolveSymbolicLinksSync();
  if (!_inside(base, real)) {
    throw DebugException('只允许读项目目录内的文件：$rel');
  }
  final bytes = f.readAsBytesSync();
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final all = text.split('\n');
  // 尾随换行会多出一个空行：按内容算行数，别让「100 行文件显示 101」。
  var total = all.length;
  if (total > 0 && all.last.isEmpty) total -= 1;
  final take = total > maxLines ? maxLines : total;
  final lines = <String>[
    for (var i = 0; i < take; i++)
      _clip(all[i].replaceAll('\r', ''), maxLineLen),
  ];
  return SourceFileView(
    abs: File(abs).absolute.path,
    path: real,
    rel: back,
    total: total,
    lines: lines,
    truncated: total > maxLines,
  );
}

String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

String _realDir(String root) {
  final dir = Directory(root.trim());
  if (!dir.existsSync()) throw DebugException('目录不存在：${dir.path}');
  try {
    return dir.resolveSymbolicLinksSync();
  } catch (_) {
    return dir.absolute.path;
  }
}

String _baseName(String path) =>
    path.split(Platform.pathSeparator).where((s) => s.isNotEmpty).lastOrNull ??
    '';

String _relOf(String base, String path) {
  final abs = File(path).absolute.path;
  final prefix = '$base${Platform.pathSeparator}';
  var rel = abs;
  if (abs.startsWith(prefix)) {
    rel = abs.substring(prefix.length);
  } else if (abs.startsWith('$base/')) {
    rel = abs.substring(base.length + 1);
  }
  return rel.replaceAll(Platform.pathSeparator, '/');
}

bool _inside(String base, String path) =>
    path == base || path.startsWith('$base${Platform.pathSeparator}');
