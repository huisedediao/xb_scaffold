import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';

import 'xb_process_stats_smaps.dart';
import 'xb_process_stats_types.dart';

typedef _GetRusageNative = Int32 Function(Int32, Pointer<Void>);
typedef _GetRusageDart = int Function(int, Pointer<Void>);
typedef _ProcPidRusageNative = Int32 Function(Int32, Int32, Pointer<Void>);
typedef _ProcPidRusageDart = int Function(int, int, Pointer<Void>);
typedef _GetPidNative = Int32 Function();
typedef _GetPidDart = int Function();
typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);

_GetRusageDart? _getrusage;
_ProcPidRusageDart? _procPidRusage;
_GetPidDart? _getpid;
Pointer<Uint8>? _rusageBuf;
Pointer<Uint8>? _procBuf;
bool _appleReady = false;
bool _extensionInstalled = false;

/// 注册 `ext.xbume.processStats`：GUI 每次轮询调用一次，返回 JSON 字符串。
void installProcessStatsExtension(Map<String, Object?> Function() sample) {
  if (_extensionInstalled) return;
  _extensionInstalled = true;
  try {
    developer.registerExtension('ext.xbume.processStats',
        (method, params) async {
      try {
        return developer.ServiceExtensionResponse.result(jsonEncode(sample()));
      } catch (e) {
        return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError, '$e');
      }
    });
  } catch (_) {
    // 重复注册或 VM service 未开启：忽略，GUI 回退到 isolate 采样。
  }
}

XBUmeProcessUsage? readProcessUsage() {
  if (Platform.isIOS || Platform.isMacOS) return _appleUsage();
  final os = Platform.operatingSystem;
  if (Platform.isAndroid || Platform.isLinux || os == 'ohos') {
    return _procUsage();
  }
  return null;
}

/// iOS/macOS：`getrusage(RUSAGE_SELF)` 取 user+sys（timeval，微秒精度，无时间基
/// 歧义）；`proc_pid_rusage` 取 resident 与 phys_footprint（与 Xcode 内存 gauge
/// 同口径）。任一符号缺失都只降级，不影响另一项。
XBUmeProcessUsage? _appleUsage() {
  _initApple();
  int? cpuNs;
  final rusage = _getrusage;
  final rbuf = _rusageBuf;
  if (rusage != null && rbuf != null && rusage(0, rbuf.cast()) == 0) {
    // struct rusage { timeval ru_utime; timeval ru_stime; ... }，64 位下
    // timeval 为 16 字节（tv_sec 8 + tv_usec 4 + 4 填充）。
    final w = rbuf.cast<Uint32>();
    final userSec = w[0] + (w[1] << 32);
    final userUsec = w[2];
    final sysSec = w[4] + (w[5] << 32);
    final sysUsec = w[6];
    cpuNs = (userSec + sysSec) * 1000000000 + (userUsec + sysUsec) * 1000;
  }
  int? rss;
  int? footprint;
  final procFn = _procPidRusage;
  final pbuf = _procBuf;
  final pidFn = _getpid;
  if (procFn != null && pbuf != null && pidFn != null) {
    // RUSAGE_INFO_V4：ri_resident_size 在偏移 64、ri_phys_footprint 在 72。
    if (procFn(pidFn(), 4, pbuf.cast()) == 0) {
      final q = pbuf.cast<Uint64>();
      final resident = q[8];
      final phys = q[9];
      if (resident > 0) rss = resident;
      if (phys > 0) footprint = phys;
    }
  }
  rss ??= _currentRss();
  if (cpuNs == null && rss == null) return null;
  return XBUmeProcessUsage(
    cpuNs: cpuNs,
    rss: rss,
    footprint: footprint,
    cpuCores: Platform.numberOfProcessors,
    cpuScope: 'core',
    platform: Platform.operatingSystem,
  );
}

void _initApple() {
  if (_appleReady) return;
  _appleReady = true;
  final libc = DynamicLibrary.process();
  _MallocDart? malloc;
  try {
    malloc = libc.lookupFunction<_MallocNative, _MallocDart>('malloc');
    _getrusage =
        libc.lookupFunction<_GetRusageNative, _GetRusageDart>('getrusage');
    _getpid = libc.lookupFunction<_GetPidNative, _GetPidDart>('getpid');
    _rusageBuf = malloc(512);
  } catch (_) {}
  try {
    // macOS 上 libproc 是独立动态库；iOS 上通常已在进程内，先试进程符号。
    DynamicLibrary lib;
    try {
      lib = Platform.isMacOS
          ? DynamicLibrary.open('/usr/lib/libproc.dylib')
          : DynamicLibrary.process();
      _procPidRusage = lib.lookupFunction<_ProcPidRusageNative,
          _ProcPidRusageDart>('proc_pid_rusage');
    } catch (_) {
      _procPidRusage =
          DynamicLibrary.open('/usr/lib/libproc.dylib').lookupFunction<
              _ProcPidRusageNative, _ProcPidRusageDart>('proc_pid_rusage');
    }
    if (malloc != null && _getpid != null) _procBuf = malloc(2048);
  } catch (_) {}
}

/// Android / OHOS / Linux：/proc/self/stat 的 utime+stime（USER_HZ 固定 100），
/// /proc/self/statm 的常驻页数换算 RSS，/proc/self/smaps 汇总 PSS 及其分类。
/// CPU 口径按官方工具区分：Android Studio / DevEco Profiler 用「占全部核心
/// 容量」的百分比，Linux 桌面（top）用「单核 100%」。
XBUmeProcessUsage? _procUsage() {
  final os = Platform.operatingSystem;
  int? cpuNs;
  try {
    final stat = File('/proc/self/stat').readAsStringSync();
    // comm 字段可能含空格/括号，从最后一个 ')' 之后开始切分；此时首项是
    // 第 3 字段 state，utime（第 14 字段）落在 f[11]、stime 落在 f[12]。
    final close = stat.lastIndexOf(')');
    if (close > 0 && close + 2 <= stat.length) {
      final f = stat.substring(close + 2).trim().split(RegExp(r'\s+'));
      if (f.length > 12) {
        final utime = int.tryParse(f[11]);
        final stime = int.tryParse(f[12]);
        if (utime != null && stime != null) {
          cpuNs = (utime + stime) * 10000000;
        }
      }
    }
  } catch (_) {}
  int? rss;
  try {
    final parts =
        File('/proc/self/statm').readAsStringSync().trim().split(RegExp(r'\s+'));
    final pages = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (pages != null && pages > 0) rss = pages * 4096;
  } catch (_) {}
  rss ??= _currentRss();
  final pss = _readPss(os == 'ohos');
  if (cpuNs == null && rss == null && pss == null) return null;
  return XBUmeProcessUsage(
    cpuNs: cpuNs,
    rss: rss,
    pss: pss?.$1,
    pssItems: pss?.$2,
    cpuCores: Platform.numberOfProcessors,
    cpuScope: (os == 'android' || os == 'ohos') ? 'total' : 'core',
    platform: os,
  );
}

/// 读取 PSS 总量与官方分类。优先整份 smaps（分类所需）；权限受限时退回
/// smaps_rollup（只有总量）。HarmonyOS 对 /proc 有额外限制，读不到时返回 null，
/// 前端自动降级到 RSS。
///
/// 解析整份 smaps 是 O(映射数) 的字符串处理，属于主 isolate 开销，因此缓存
/// 3 秒：PSS 变化慢，内存曲线仍然连续，CPU 百分比不受影响。
int _pssAtMs = 0;
int? _pssTotal;
Map<String, int>? _pssItems;
bool _pssMissing = false;

(int, Map<String, int>?)? _readPss(bool ohos) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - _pssAtMs < 3000) {
    if (_pssTotal != null) return (_pssTotal!, _pssItems);
    if (_pssMissing) return null;
  }
  _pssAtMs = now;
  _pssTotal = null;
  _pssItems = null;
  _pssMissing = false;
  try {
    final entries = parseSmapsEntries(File('/proc/self/smaps').readAsStringSync());
    final breakdown =
        ohos ? ohosPssBreakdown(entries) : androidPssBreakdown(entries);
    if (breakdown != null && breakdown.total > 0) {
      _pssTotal = breakdown.total;
      _pssItems = breakdown.items;
      return (breakdown.total, breakdown.items);
    }
  } catch (_) {}
  try {
    final text = File('/proc/self/smaps_rollup').readAsStringSync();
    for (final line in text.split('\n')) {
      // smaps_rollup 的字段行在不同内核上可能缩进，也可能顶格。
      final field = line.trimLeft();
      if (!field.startsWith('Pss:')) continue;
      final kb = int.tryParse(field.substring(4).trim().split(RegExp(r'\s+')).first);
      if (kb != null && kb > 0) {
        _pssTotal = kb * 1024;
        return (_pssTotal!, null);
      }
    }
  } catch (_) {}
  _pssMissing = true;
  return null;
}

int? _currentRss() {
  try {
    return ProcessInfo.currentRss;
  } catch (_) {
    return null;
  }
}
