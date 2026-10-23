import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';

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
  return XBUmeProcessUsage(cpuNs: cpuNs, rss: rss, footprint: footprint);
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
/// /proc/self/statm 的常驻页数换算 RSS；无 footprint 口径。
XBUmeProcessUsage? _procUsage() {
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
  if (cpuNs == null && rss == null) return null;
  return XBUmeProcessUsage(cpuNs: cpuNs, rss: rss);
}

int? _currentRss() {
  try {
    return ProcessInfo.currentRss;
  } catch (_) {
    return null;
  }
}
