// 直连 Agent 的文件/存储数据面（P3）：沙盒只读、shared_prefs、SQLite 文件枚举。
//
// 全部只用 AOT 可用的 dart:io / app 内已注册的适配器，不需要 VM service：
//   GET  /v1/sandbox/roots     app 进程可访问的候选根目录（带可用性）
//   GET  /v1/sandbox/list      ?path=（空 = 第一个可用根）
//   GET  /v1/sandbox/stat      ?path=
//   GET  /v1/sandbox/read      ?path=&offset=&max=&b64=
//   GET  /v1/storage/list      shared_prefs 文件列表（Android xml / iOS plist）
//   GET  /v1/storage/read      ?file= 原文（二进制时回 base64）
//   GET  /v1/storage/adapters  已注册 XBUmeStorageAdapter 的 dump
//   POST /v1/storage/set       {adapter,key,value,type}
//   POST /v1/storage/remove    {adapter,key}
//   GET  /v1/db/files          ?dir=&limit= 沙盒里的 SQLite 文件
//
// 写操作只有「经 app 自己注册的适配器写回」这一条路：直连通道不落任意文件、
// 不执行 SQL（SQL 由 IDE 侧把文件拉到本机用 sqlite3 只读跑）。
library;

import 'dart:convert';
import 'dart:io';

import '../core/xb_ume_controller.dart';
import '../core/xb_ume_storage_adapter.dart';

/// 当前平台名（与 VM `Platform.operatingSystem` 一致）。
String agentPlatformName() => Platform.operatingSystem;

/// 从 `/proc/self/cmdline` 首段解析包名 / bundle 名（纯函数，便于单测）。
///
/// Android 是 `com.foo.bar`（子进程带 `:push` 后缀，去掉）；鸿蒙的进程名就是
/// bundle 名（同样可能带 `:xx`）。只接受形如 `a.b.c` 的标识符：桌面端首段是
/// Dart 可执行路径，含 `/` 或空格，一律当「没采到」，不把路径当包名展示。
String parsePackageFromCmdline(String raw) {
  final first = raw.split('\u0000').first.trim();
  if (first.isEmpty) return '';
  final i = first.indexOf(':');
  final name = (i > 0 ? first.substring(0, i) : first).trim();
  if (name.isEmpty || name.contains('/') || name.contains(' ')) return '';
  if (!name.contains('.')) return '';
  return name;
}

/// 读进程名当包名：Android / 鸿蒙的 `/proc/self/cmdline` 首段就是包名。
/// 其他平台（iOS / 桌面）读不到，返回空串（留给 `--dart-define=XBUME_AGENT_APP`）。
String agentDetectPackageName() {
  final os = Platform.operatingSystem;
  if (os != 'android' && os != 'ohos') return '';
  try {
    return parsePackageFromCmdline(
        File('/proc/self/cmdline').readAsStringSync());
  } catch (_) {
    return '';
  }
}

/// app 沙盒 HOME：iOS 真机/模拟器的 HOME 可能为空，退回 systemTemp 的父目录。
String agentHomeDir() {
  final env = Platform.environment['HOME'] ?? '';
  if (env.trim().isNotEmpty) return env.trim();
  try {
    return Directory.systemTemp.parent.path;
  } catch (_) {
    return Directory.systemTemp.path;
  }
}

/// app 进程有机会访问到的沙盒根（按优先级）。是否真的可进由调用方探测。
List<String> agentSandboxRootCandidates({
  required String pkg,
  required String os,
  required String home,
}) {
  final out = <String>[];
  void add(String p) {
    final v = p.trim();
    if (v.isEmpty || out.contains(v)) return;
    out.add(v);
  }

  switch (os) {
    case 'ohos':
      add('/data/storage/el2/base');
      add('/data/storage/el1/base');
    case 'ios':
      add(home);
      add('$home/Documents');
      add('$home/Library/Application Support');
    case 'android':
      if (pkg.isNotEmpty) {
        add('/data/user/0/$pkg');
        add('/data/data/$pkg');
        add('/storage/emulated/0/Android/data/$pkg/files');
      }
    default:
      add(home);
      add(Directory.current.path);
  }
  add(Directory.systemTemp.path);
  return out;
}

/// 端点：`/v1/sandbox/roots`。
Map<String, Object?> agentSandboxRootsJson({
  required String pkg,
  required String os,
  required String home,
}) {
  final roots = <Map<String, Object?>>[];
  for (final c in agentSandboxRootCandidates(pkg: pkg, os: os, home: home)) {
    var ok = false;
    try {
      Directory(c).listSync(followLinks: false);
      ok = true;
    } catch (_) {}
    roots.add(<String, Object?>{'path': c, 'ok': ok});
  }
  final usable = roots.where((e) => e['ok'] == true).toList(growable: false);
  return <String, Object?>{
    'ok': true,
    'os': os,
    'home': home,
    'pkg': pkg,
    'roots': roots,
    'root': usable.isEmpty ? '' : usable.first['path'],
  };
}

/// 端点：`/v1/sandbox/list`（形状与 GUI `/api/sandbox/list` 一致）。
Map<String, Object?> agentSandboxListJson({
  required String path,
  required String pkg,
  required String os,
  required String home,
}) {
  final rootsJson = agentSandboxRootsJson(pkg: pkg, os: os, home: home);
  final roots = (rootsJson['roots'] as List)
      .whereType<Map>()
      .where((e) => e['ok'] == true)
      .map((e) => e['path'].toString())
      .toList(growable: false);
  final target = path.trim().isNotEmpty
      ? path.trim()
      : (roots.isEmpty ? '' : roots.first);
  if (target.isEmpty) {
    return <String, Object?>{
      'ok': false,
      'os': os,
      'home': home,
      'roots': const <String>[],
      'root': '',
      'entries': const <Object?>[],
      'error': 'app 进程读不到任何可访问目录（HOME=$home）',
    };
  }
  final entries = <Map<String, Object?>>[];
  String? error;
  try {
    for (final e in Directory(target).listSync(followLinks: false)) {
      var size = -1;
      var mtime = 0;
      try {
        final st = e.statSync();
        size = e is File ? st.size : -1;
        mtime = st.modified.millisecondsSinceEpoch;
      } catch (_) {}
      entries.add(<String, Object?>{
        'name': _baseName(e.path),
        'path': e.path,
        'dir': e is Directory,
        'link': e is Link,
        'size': size,
        'mtime': mtime,
      });
    }
  } catch (e) {
    error = e.toString();
  }
  entries.sort((a, b) {
    if ((a['dir'] as bool) != (b['dir'] as bool)) {
      return (a['dir'] as bool) ? -1 : 1;
    }
    return (a['name'] as String).toLowerCase().compareTo(
          (b['name'] as String).toLowerCase(),
        );
  });
  return <String, Object?>{
    'ok': error == null,
    'os': os,
    'home': home,
    'roots': roots,
    'root': target,
    'path': target,
    'entries': entries,
    if (error != null) 'error': error,
  };
}

/// 端点：`/v1/sandbox/stat`。
Map<String, Object?> agentSandboxStatJson(String path) {
  if (path.trim().isEmpty) {
    return <String, Object?>{'ok': false, 'error': 'missing path'};
  }
  try {
    final st = FileStat.statSync(path);
    if (st.type == FileSystemEntityType.notFound) {
      return <String, Object?>{'ok': false, 'path': path, 'error': 'missing'};
    }
    final isDir = st.type == FileSystemEntityType.directory;
    return <String, Object?>{
      'ok': true,
      'path': path,
      'dir': isDir,
      'link': st.type == FileSystemEntityType.link,
      'size': isDir ? -1 : st.size,
      'mtime': st.modified.millisecondsSinceEpoch,
    };
  } catch (e) {
    return <String, Object?>{'ok': false, 'path': path, 'error': e.toString()};
  }
}

/// 端点：`/v1/sandbox/read`。
///
/// 默认按 UTF-8 解码回 `text`（`nextOffset` 落在字符边界上，可续读）；二进制
/// 或 `b64=1` 时回 `b64`，调用方按块拼字节（db 下载走这条）。
Map<String, Object?> agentSandboxReadJson(
  String path, {
  int offset = 0,
  int max = 65536,
  bool forceB64 = false,
}) {
  if (path.trim().isEmpty) {
    return <String, Object?>{'ok': false, 'error': 'missing path'};
  }
  final f = File(path);
  int size;
  try {
    size = f.lengthSync();
  } catch (_) {
    return <String, Object?>{'ok': false, 'path': path, 'error': 'missing'};
  }
  final start = offset < 0 ? 0 : (offset > size ? size : offset);
  final want = max.clamp(1, 2 * 1024 * 1024);
  List<int> bytes = const <int>[];
  if (start < size) {
    final n = (size - start) < want ? (size - start) : want;
    try {
      final raf = f.openSync();
      try {
        raf.setPositionSync(start);
        bytes = raf.readSync(n);
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      return <String, Object?>{'ok': false, 'path': path, 'error': e.toString()};
    }
  }
  if (forceB64) {
    return <String, Object?>{
      'ok': true,
      'path': path,
      'fileSize': size,
      'offset': start,
      'nextOffset': start + bytes.length,
      'truncated': start + bytes.length < size,
      'b64': base64Encode(bytes),
    };
  }
  // 截到 UTF-8 序列边界再解码：分块切断多字节字符不算二进制，只是本次少给
  // 几个字节（nextOffset 指向未消费的部分）。只有前缀也解不了才当二进制。
  final cut = _utf8Boundary(bytes);
  String? text;
  try {
    text = utf8.decode(bytes.sublist(0, cut));
  } catch (_) {
    text = null;
  }
  if (text == null) {
    // 二进制：不猜编码，原样回 base64；调用方拿 fileSize 自己续读。
    return <String, Object?>{
      'ok': true,
      'path': path,
      'fileSize': size,
      'offset': start,
      'nextOffset': start + bytes.length,
      'truncated': start + bytes.length < size,
      'binary': true,
      'b64': base64Encode(bytes),
    };
  }
  return <String, Object?>{
    'ok': true,
    'path': path,
    'fileSize': size,
    'offset': start,
    'nextOffset': start + cut,
    'truncated': start + cut < size,
    'text': text,
  };
}

/// 端点：`/v1/storage/list`（shared_prefs 文件，形状与 GUI 同）。
Map<String, Object?> agentStorageListJson({
  required String pkg,
  required String os,
  required String home,
}) {
  final dirs = <String>[];
  final ext = <String>['.xml'];
  switch (os) {
    case 'ohos':
      dirs.addAll(const <String>[
        '/data/storage/el2/base/preferences',
        '/data/storage/el1/base/preferences',
      ]);
      ext
        ..clear()
        ..add('');
    case 'ios':
      dirs.add('$home/Library/Preferences');
      ext
        ..clear()
        ..add('.plist');
    case 'android':
      if (pkg.isNotEmpty) {
        dirs.add('/data/data/$pkg/shared_prefs');
        dirs.add('/data/user/0/$pkg/shared_prefs');
      }
    default:
      // 桌面端：macOS 的 prefs 在 ~/Library/Preferences，其余给 ~/.config。
      dirs.add(Platform.isMacOS
          ? '$home/Library/Preferences'
          : '$home/.config');
      ext
        ..clear()
        ..addAll(const <String>['.plist', '.xml', '.json']);
  }
  final files = <String>[];
  for (final d in dirs) {
    try {
      for (final e in Directory(d).listSync()) {
        if (e is! File) continue;
        if (ext.any((x) => e.path.endsWith(x))) files.add(e.path);
      }
    } catch (_) {}
  }
  if (os == 'ohos') {
    files.removeWhere((f) => f.endsWith('.lock'));
  }
  files.sort();
  return <String, Object?>{
    'ok': true,
    'pkg': pkg,
    'os': os,
    'prefsDir': dirs.isEmpty ? '' : dirs.first,
    'files': files,
  };
}

/// 端点：`/v1/storage/read`。文本（Android XML）直接给 `text`；二进制 plist
/// 给 `b64`，由 IDE 侧用本机 plutil 转成 XML（与 debug 通道的展示一致）。
Map<String, Object?> agentStorageReadJson(String file) {
  if (file.trim().isEmpty) {
    return <String, Object?>{'ok': false, 'error': 'missing file'};
  }
  try {
    final bytes = File(file).readAsBytesSync();
    try {
      return <String, Object?>{
        'ok': true,
        'file': file,
        'text': utf8.decode(bytes),
      };
    } catch (_) {
      return <String, Object?>{
        'ok': true,
        'file': file,
        'binary': true,
        'b64': base64Encode(bytes),
      };
    }
  } catch (e) {
    return <String, Object?>{'ok': false, 'file': file, 'error': e.toString()};
  }
}

/// 端点：`/v1/storage/adapters`——app 用 `XBUme.registerStorageAdapter`
/// 注册过的存储（可在 app 侧决定是否允许写）。
Future<Map<String, Object?>> agentStorageAdaptersJson(
  XBUmeController controller,
) async {
  final items = <Map<String, Object?>>[];
  for (final a in controller.storageAdapters) {
    Object? data;
    Object? error;
    try {
      data = await a.dump();
    } catch (e) {
      error = e.toString();
    }
    items.add(<String, Object?>{
      'id': a.id,
      'writable': a.writable,
      if (data != null) 'data': data,
      if (error != null) 'error': error,
    });
  }
  return <String, Object?>{'ok': true, 'items': items};
}

/// 端点：`POST /v1/storage/set`。
Future<Map<String, Object?>> agentStorageSetJson(
  XBUmeController controller, {
  required String adapter,
  required String key,
  required String type,
  required String value,
}) async {
  final target = _adapterOf(controller, adapter);
  if (target == null) {
    return <String, Object?>{'ok': false, 'error': '没有 id=$adapter 的存储适配器'};
  }
  if (!target.writable) {
    return <String, Object?>{
      'ok': false,
      'error': '适配器 ${target.id} 不允许写（writable=false）',
    };
  }
  try {
    await target.setValue(key, _parseValue(type, value));
    return <String, Object?>{'ok': true, 'id': target.id, 'key': key};
  } catch (e) {
    return <String, Object?>{'ok': false, 'error': e.toString()};
  }
}

/// 端点：`POST /v1/storage/remove`。
Future<Map<String, Object?>> agentStorageRemoveJson(
  XBUmeController controller, {
  required String adapter,
  required String key,
}) async {
  final target = _adapterOf(controller, adapter);
  if (target == null) {
    return <String, Object?>{'ok': false, 'error': '没有 id=$adapter 的存储适配器'};
  }
  if (!target.writable) {
    return <String, Object?>{
      'ok': false,
      'error': '适配器 ${target.id} 不允许写（writable=false）',
    };
  }
  try {
    await target.removeValue(key);
    return <String, Object?>{'ok': true, 'id': target.id, 'key': key};
  } catch (e) {
    return <String, Object?>{'ok': false, 'error': e.toString()};
  }
}

/// 端点：`/v1/db/files`——枚举沙盒里的 SQLite 文件（只列不读，SQL 由 IDE 侧
/// 拉走文件后用本机 sqlite3 只读执行）。
Map<String, Object?> agentDbFilesJson({
  required String pkg,
  required String os,
  required String home,
  String dir = '',
  int limit = 200,
}) {
  const exts = <String>['.db', '.sqlite', '.sqlite3', '.db3'];
  const skipDirs = <String>{
    'Caches',
    'cache',
    'tmp',
    '.git',
    'node_modules',
  };
  final roots = dir.trim().isNotEmpty
      ? <String>[dir.trim()]
      : agentSandboxRootCandidates(pkg: pkg, os: os, home: home);
  final items = <Map<String, Object?>>[];
  var scanned = 0;
  for (final r in roots) {
    if (items.length >= limit) break;
    final rootDir = Directory(r);
    if (!rootDir.existsSync()) continue;
    scanned++;
    try {
      for (final e in rootDir.listSync(recursive: true, followLinks: false)) {
        if (items.length >= limit) break;
        if (e is! File) continue;
        if (!exts.any((x) => e.path.toLowerCase().endsWith(x))) continue;
        final rel = e.path.startsWith(r) ? e.path.substring(r.length) : e.path;
        if (rel
            .split(Platform.pathSeparator)
            .any((seg) => skipDirs.contains(seg))) {
          continue;
        }
        var size = 0;
        var mtime = 0;
        try {
          final st = e.statSync();
          size = st.size;
          mtime = st.modified.millisecondsSinceEpoch;
        } catch (_) {}
        items.add(<String, Object?>{
          'path': e.path,
          'name': _baseName(e.path),
          'size': size,
          'mtime': mtime,
          'root': r,
        });
      }
    } catch (_) {}
  }
  items.sort((a, b) => (b['mtime'] as int).compareTo(a['mtime'] as int));
  return <String, Object?>{
    'ok': true,
    'items': items,
    'scanned': scanned,
    'truncated': items.length >= limit,
  };
}

/// 适配器查找（XBUmeController 未暴露按 id 取的方法时按列表过滤）。
XBUmeStorageAdapter? _adapterOf(XBUmeController controller, String id) {
  for (final a in controller.storageAdapters) {
    if (a.id == id) return a;
  }
  return null;
}

/// 按 `type` 解析写回值：string（默认）/ int / double / bool / null / json。
Object? _parseValue(String type, String raw) {
  switch (type.trim().toLowerCase()) {
    case 'int':
      return int.tryParse(raw);
    case 'double':
      return double.tryParse(raw);
    case 'bool':
      return raw.trim() == 'true' || raw.trim() == '1';
    case 'null':
      return null;
    case 'json':
      try {
        return jsonDecode(raw);
      } catch (_) {
        return raw;
      }
    default:
      return raw;
  }
}

String _baseName(String path) {
  final unified = path.replaceAll('\\', '/');
  final i = unified.lastIndexOf('/');
  return i < 0 ? unified : unified.substring(i + 1);
}

/// 按 UTF-8 序列边界截尾（避免多字节字符被分块切断产生替换符）。
int _utf8Boundary(List<int> bytes) {
  final n = bytes.length;
  if (n == 0) return 0;
  var i = n - 1;
  var continuation = 0;
  while (i >= 0 && (bytes[i] & 0xC0) == 0x80 && continuation < 4) {
    i--;
    continuation++;
  }
  if (i < 0) return n;
  final lead = bytes[i];
  final need = lead >= 0xF0
      ? 4
      : lead >= 0xE0
          ? 3
          : lead >= 0xC0
              ? 2
              : 1;
  final have = n - i;
  return have < need ? i : n;
}