import 'dart:convert';
import 'dart:math' as math;

/// `/proc/self/smaps` 中一条 VMA 映射的计量（字节）。
class XBUmeSmapsEntry {
  const XBUmeSmapsEntry({
    required this.name,
    this.pss = 0,
    this.privateClean = 0,
    this.privateDirty = 0,
    this.sharedClean = 0,
    this.sharedDirty = 0,
  });

  /// 映射名（路径 / `[anon:xxx]` / `[stack]` 等），无名为空串。
  final String name;

  /// Pss（共享页按进程数比例分摊后的常驻页）。
  final int pss;

  final int privateClean;
  final int privateDirty;
  final int sharedClean;
  final int sharedDirty;

  /// 私有页合计（Private_Clean + Private_Dirty）。
  int get privateBytes => privateClean + privateDirty;
}

/// 进程 PSS 汇总：`total` 为 Pss 之和，`items` 为按官方分类拆分的字节数。
class XBUmePssBreakdown {
  const XBUmePssBreakdown({required this.total, required this.items});

  final int total;
  final Map<String, int> items;
}

/// 解析 `/proc/self/smaps` 文本；无法解析出任何 Pss 时返回空列表。
///
/// 每个映射块以非空白开头的头行开始：
/// `start-end perms offset dev inode [pathname]`，随后是 `Pss: N kB`、
/// `Private_Clean: N kB` 等字段（单位统一为 kB = 1024 字节）。
List<XBUmeSmapsEntry> parseSmapsEntries(String text) {
  if (text.isEmpty) return const <XBUmeSmapsEntry>[];
  final entries = <XBUmeSmapsEntry>[];
  var name = '';
  var pss = 0;
  var privateClean = 0;
  var privateDirty = 0;
  var sharedClean = 0;
  var sharedDirty = 0;

  void flush() {
    if (pss > 0 ||
        privateClean > 0 ||
        privateDirty > 0 ||
        sharedClean > 0 ||
        sharedDirty > 0) {
      entries.add(XBUmeSmapsEntry(
        name: name,
        pss: pss,
        privateClean: privateClean,
        privateDirty: privateDirty,
        sharedClean: sharedClean,
        sharedDirty: sharedDirty,
      ));
    }
  }

  for (final line in const LineSplitter().convert(text)) {
    if (line.isEmpty) continue;
    final first = line.codeUnitAt(0);
    if (first != 0x20 && first != 0x09) {
      // 头行：先结算上一条映射，再记录新映射名。
      flush();
      name = _mappingName(line);
      pss = 0;
      privateClean = 0;
      privateDirty = 0;
      sharedClean = 0;
      sharedDirty = 0;
      continue;
    }
    // 字段行在 smaps 中统一缩进，去掉缩进后再比较字段名。
    final field = line.trimLeft();
    if (field.startsWith('Pss:')) {
      pss = _kb(field);
    } else if (field.startsWith('Private_Clean:')) {
      privateClean = _kb(field);
    } else if (field.startsWith('Private_Dirty:')) {
      privateDirty = _kb(field);
    } else if (field.startsWith('Shared_Clean:')) {
      sharedClean = _kb(field);
    } else if (field.startsWith('Shared_Dirty:')) {
      sharedDirty = _kb(field);
    }
  }
  flush();
  return entries;
}

/// Android：按 `dumpsys meminfo` App Summary / Android Studio Memory Profiler
/// 的分类口径汇总：
/// - Java Heap = Dalvik 映射的 Private_Dirty + `.art` 映射的私有页；
/// - Native Heap = Native 堆映射的 Private_Dirty；
/// - Code = `.so/.dex/.odex/.oat/.apk/.jar/.ttf` 等映射的私有页；
/// - Stack = `[stack]` 的 Private_Dirty；
/// - Graphics = GPU 映射的 Pss（memtrack 部分 app 内不可读，为近似值）；
/// - Private Other / System 分别为私有页、PSS 的剩余部分，且各行之和恒等于
///   TOTAL PSS，便于与 dumpsys 的 TOTAL 对照。
XBUmePssBreakdown? androidPssBreakdown(List<XBUmeSmapsEntry> entries) {
  var total = 0;
  var totalPrivate = 0;
  var java = 0;
  var native = 0;
  var code = 0;
  var stack = 0;
  var graphics = 0;
  for (final e in entries) {
    total += e.pss;
    totalPrivate += e.privateBytes;
    if (e.pss <= 0) continue;
    final n = e.name.toLowerCase();
    if (n.contains('dalvik')) {
      java += e.privateDirty;
    } else if (_isArtMapping(n)) {
      java += e.privateBytes;
    } else if (_isStackMapping(n)) {
      stack += e.privateDirty;
    } else if (_isGpuMapping(n)) {
      graphics += e.pss;
    } else if (_isCodeMapping(n)) {
      code += e.privateBytes;
    } else if (_isNativeHeapMapping(n)) {
      native += e.privateDirty;
    }
  }
  if (total <= 0) return null;
  final system = math.max(0, total - totalPrivate);
  final other =
      math.max(0, total - system - java - native - code - stack - graphics);
  final items = <String, int>{
    'Java': java,
    'Native': native,
    'Code': code,
    'Stack': stack,
    'Graphics': graphics,
    'Private Other': other,
    'System': system,
  }..removeWhere((_, v) => v <= 0);
  return XBUmePssBreakdown(total: total, items: items);
}

/// HarmonyOS：按 DevEco Profiler Memory 泳道的子分类（均为 PSS 口径）汇总。
XBUmePssBreakdown? ohosPssBreakdown(List<XBUmeSmapsEntry> entries) {
  var total = 0;
  final items = <String, int>{};
  for (final e in entries) {
    if (e.pss <= 0) continue;
    total += e.pss;
    final cat = _ohosCategory(e.name.toLowerCase());
    items[cat] = (items[cat] ?? 0) + e.pss;
  }
  if (total <= 0) return null;
  return XBUmePssBreakdown(total: total, items: items);
}

String _ohosCategory(String n) {
  if (_isArkHeapMapping(n)) return 'ArkTS Heap';
  if (_isNativeHeapMapping(n)) return 'Native Heap';
  if (_isStackMapping(n)) return 'Stack';
  if (_isGpuMapping(n)) return 'GL/Graph';
  if (_isSoMapping(n)) return '.so';
  if (n.contains('.ttf')) return '.ttf';
  if (n.contains('.hap')) return '.hap';
  if (n.startsWith('/dev/')) return 'Dev';
  if (n.isEmpty || n.contains('[anon') || n.startsWith('[')) {
    return 'AnonPage Other';
  }
  return 'FilePage Other';
}

String _mappingName(String header) {
  // `start-end perms offset dev inode pathname`，pathname 可含空格且可缺省。
  final parts = header.split(RegExp(r'\s+'));
  if (parts.length <= 5) return '';
  return parts.sublist(5).join(' ');
}

int _kb(String line) {
  final colon = line.indexOf(':');
  if (colon < 0) return 0;
  final value = line
      .substring(colon + 1)
      .trim()
      .split(RegExp(r'\s+'))
      .first;
  final kb = int.tryParse(value) ?? 0;
  return kb > 0 ? kb * 1024 : 0;
}

bool _isArtMapping(String n) =>
    n.endsWith('.art') || n.contains('.art ') || n.contains('.art!');

bool _isStackMapping(String n) =>
    n.contains('[stack') || n.contains('stack_and_tls');

bool _isGpuMapping(String n) =>
    n.contains('kgsl') ||
    n.contains('mali') ||
    n.contains('gralloc') ||
    n.contains('dmabuf') ||
    n.contains('/dev/ion') ||
    n.contains('dma_heap') ||
    n.contains('/dev/dri') ||
    n.contains('vulkan') ||
    n.contains('graphics') ||
    n.contains('gpu');

bool _isCodeMapping(String n) =>
    _isSoMapping(n) ||
    _codeExt.hasMatch(n) ||
    n.contains('.ttf');

final RegExp _codeExt =
    RegExp(r'\.(dex|odex|oat|vdex|apk|jar)($|[.\s(!])');

bool _isSoMapping(String n) =>
    n.endsWith('.so') || n.contains('.so.') || n.contains('.so ');

bool _isNativeHeapMapping(String n) =>
    n.contains('[heap]') ||
    n.contains('libc_malloc') ||
    n.contains('scudo') ||
    n.contains('jemalloc') ||
    n.contains('gwp_asan') ||
    n.contains('malloc');

bool _isArkHeapMapping(String n) =>
    n.contains('arkts') ||
    n.contains('ark-ts') ||
    n.contains('ark_heap') ||
    n.contains('[anon:ark');
