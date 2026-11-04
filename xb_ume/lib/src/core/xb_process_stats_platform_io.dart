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
// Apple：mach task_threads 取线程数（与 Xcode 调试器看到的线程列表同一来源），
// sysctlbyname("hw.memsize") 取系统物理内存总量。
typedef _MachTaskSelfNative = Uint32 Function();
typedef _MachTaskSelfDart = int Function();
typedef _TaskThreadsNative = Int32 Function(
    Uint32, Pointer<Uint32>, Pointer<Uint32>);
typedef _TaskThreadsDart = int Function(int, Pointer<Uint32>, Pointer<Uint32>);
typedef _MachPortDeallocateNative = Int32 Function(Uint32, Uint32);
typedef _MachPortDeallocateDart = int Function(int, int);
typedef _VmDeallocateNative = Int32 Function(Uint32, UintPtr, UintPtr);
typedef _VmDeallocateDart = int Function(int, int, int);
typedef _SysctlByNameNative = Int32 Function(
    Pointer<Uint8>, Pointer<Uint8>, Pointer<UintPtr>, Pointer<Uint8>, UintPtr);
typedef _SysctlByNameDart = int Function(
    Pointer<Uint8>, Pointer<Uint8>, Pointer<UintPtr>, Pointer<Uint8>, int);
// Windows：kernel32!GetProcessTimes + psapi!GetProcessMemoryInfo（全进程口径）。
typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();
typedef _GetProcessTimesNative = Int32 Function(
    IntPtr, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);
typedef _GetProcessTimesDart = int Function(
    int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);
typedef _GetProcessMemoryInfoNative = Int32 Function(
    IntPtr, Pointer<Void>, Uint32);
typedef _GetProcessMemoryInfoDart = int Function(int, Pointer<Void>, int);

_GetRusageDart? _getrusage;
_ProcPidRusageDart? _procPidRusage;
_GetPidDart? _getpid;
Pointer<Uint8>? _rusageBuf;
Pointer<Uint8>? _procBuf;
_MachTaskSelfDart? _machTaskSelf;
_TaskThreadsDart? _taskThreads;
_MachPortDeallocateDart? _machPortDeallocate;
_VmDeallocateDart? _vmDeallocate;
_SysctlByNameDart? _sysctlByName;
Pointer<Uint8>? _threadBuf;
Pointer<Uint8>? _sysctlNameBuf;
Pointer<Uint8>? _sysctlValueBuf;
Pointer<Uint8>? _sysctlLenBuf;
bool _appleReady = false;
bool _extensionInstalled = false;
_GetCurrentProcessDart? _getCurrentProcess;
_GetProcessTimesDart? _getProcessTimes;
_GetProcessMemoryInfoDart? _getProcessMemoryInfo;
Pointer<Uint8>? _winTimesBuf;
Pointer<Uint8>? _winMemBuf;
bool _windowsReady = false;

/// Windows 的 FILETIME 是 100 纳秒计数（user+sys 分别给出）；换算成纳秒。
/// 拆成纯函数便于在非 Windows 机器上单测。
int windowsCpuNsFromFileTime(int kernel100ns, int user100ns) {
  final total = kernel100ns + user100ns;
  return total <= 0 ? 0 : total * 100;
}

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
  if (Platform.isWindows) return _windowsUsage();
  final os = Platform.operatingSystem;
  if (Platform.isAndroid || Platform.isLinux || os == 'ohos') {
    return _procUsage();
  }
  return null;
}

/// Windows：`GetProcessTimes` 取 kernel+user（FILETIME，100ns）；
/// `GetProcessMemoryInfo` 取 WorkingSetSize（与任务管理器「内存(专用工作集)
/// 接近」）；两者任一失败只降级该项。
XBUmeProcessUsage? _windowsUsage() {
  _initWindows();
  int? cpuNs;
  final times = _getProcessTimes;
  final cur = _getCurrentProcess;
  final tbuf = _winTimesBuf;
  if (times != null && cur != null && tbuf != null) {
    // FILETIME[4]：creation / exit / kernel / user，每个 8 字节。
    final q = tbuf.cast<Uint64>();
    if (times(cur(), q, q + 1, q + 2, q + 3) != 0) {
      cpuNs = windowsCpuNsFromFileTime(q[2], q[3]);
      if (cpuNs == 0) cpuNs = null;
    }
  }
  int? rss;
  final memInfo = _getProcessMemoryInfo;
  final mbuf = _winMemBuf;
  if (memInfo != null && cur != null && mbuf != null) {
    // PROCESS_MEMORY_COUNTERS：cb(4) + PageFaultCount(4) + 8 个指针宽的
    // SIZE_T，cb 必须等于结构体实际大小（调用方负责填）。WorkingSetSize 是
    // 第 2 个 SIZE_T（偏移 8 + 指针宽度）；Flutter 桌面 Windows 只有 x64，
    // 32 位下读法不同，直接跳过该项降级到 _currentRss()。
    final ptrSize = sizeOf<IntPtr>();
    final cb = 8 + 8 * ptrSize;
    mbuf.cast<Uint32>()[0] = cb;
    if (memInfo(cur(), mbuf.cast(), cb) != 0 && ptrSize == 8) {
      final ws = mbuf.cast<Uint64>()[2];
      if (ws > 0) rss = ws;
    }
  }
  rss ??= _currentRss();
  if (cpuNs == null && rss == null) return null;
  return XBUmeProcessUsage(
    cpuNs: cpuNs,
    rss: rss,
    cpuCores: Platform.numberOfProcessors,
    // 与任务管理器同口径：100% = 全部核心容量合计（不是单核）。
    cpuScope: 'total',
    platform: 'windows',
  );
}

void _initWindows() {
  if (_windowsReady) return;
  _windowsReady = true;
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    _getCurrentProcess = kernel32.lookupFunction<_GetCurrentProcessNative,
        _GetCurrentProcessDart>('GetCurrentProcess');
    _getProcessTimes = kernel32.lookupFunction<_GetProcessTimesNative,
        _GetProcessTimesDart>('GetProcessTimes');
  } catch (_) {}
  try {
    final psapi = DynamicLibrary.open('psapi.dll');
    _getProcessMemoryInfo = psapi.lookupFunction<_GetProcessMemoryInfoNative,
        _GetProcessMemoryInfoDart>('GetProcessMemoryInfo');
  } catch (_) {}
  try {
    // msvcrt 的 malloc 用来给 FFI 结构体准备缓冲区（进程生命周期内复用）。
    final crt = DynamicLibrary.open('msvcrt.dll');
    final malloc = crt.lookupFunction<_MallocNative, _MallocDart>('malloc');
    _winTimesBuf = malloc(64);
    _winMemBuf = malloc(72);
  } catch (_) {}
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
  final threads = _appleThreadCount();
  final totalMemory = _appleTotalMemory();
  if (cpuNs == null && rss == null) return null;
  return XBUmeProcessUsage(
    cpuNs: cpuNs,
    rss: rss,
    footprint: footprint,
    cpuCores: Platform.numberOfProcessors,
    threads: threads,
    totalMemory: totalMemory,
    cpuScope: 'core',
    platform: Platform.operatingSystem,
  );
}

/// 进程线程数：`task_threads` 返回的端口数组长度（与 Xcode 调试器线程列表同一来源）。
/// 取到后必须归还每个线程端口并释放数组，否则每次采样都会漏 mach port。
int? _appleThreadCount() {
  final taskThreads = _taskThreads;
  final self = _machTaskSelf;
  final buf = _threadBuf;
  if (taskThreads == null || self == null || buf == null) return null;
  final task = self();
  // 出参布局：偏移 0 = thread_act_array_t（指针），偏移 8 = count（4 字节）。
  buf.cast<Uint64>()[0] = 0;
  buf.cast<Uint32>()[2] = 0;
  if (taskThreads(task, buf.cast(), buf.cast<Uint32>() + 2) != 0) return null;
  final arrayAddr = buf.cast<IntPtr>()[0];
  final count = buf.cast<Uint32>()[2];
  if (arrayAddr != 0) {
    final array = Pointer<Uint32>.fromAddress(arrayAddr);
    final deallocPort = _machPortDeallocate;
    if (deallocPort != null) {
      for (var i = 0; i < count; i++) {
        deallocPort(task, array[i]);
      }
    }
    _vmDeallocate?.call(task, arrayAddr, count * 4);
  }
  return count > 0 ? count : null;
}

/// 系统物理内存总量：`sysctlbyname("hw.memsize")`，与 NSProcessInfo.physicalMemory 同值。
int? _appleTotalMemory() {
  final sysctlByName = _sysctlByName;
  final name = _sysctlNameBuf;
  final value = _sysctlValueBuf;
  final len = _sysctlLenBuf;
  if (sysctlByName == null || name == null || value == null || len == null) {
    return null;
  }
  len.cast<UintPtr>()[0] = 8;
  if (sysctlByName(name, value, len.cast(), nullptr, 0) != 0) return null;
  final total = value.cast<Uint64>()[0];
  return total > 0 ? total : null;
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
  try {
    _machTaskSelf =
        libc.lookupFunction<_MachTaskSelfNative, _MachTaskSelfDart>(
            'mach_task_self');
    _taskThreads = libc.lookupFunction<_TaskThreadsNative, _TaskThreadsDart>(
        'task_threads');
    _machPortDeallocate = libc.lookupFunction<
        _MachPortDeallocateNative,
        _MachPortDeallocateDart>('mach_port_deallocate');
    _vmDeallocate = libc.lookupFunction<_VmDeallocateNative,
        _VmDeallocateDart>('vm_deallocate');
  } catch (_) {}
  try {
    _sysctlByName = libc.lookupFunction<_SysctlByNameNative,
        _SysctlByNameDart>('sysctlbyname');
    if (malloc != null) {
      _threadBuf = malloc(16);
      _sysctlLenBuf = malloc(16);
      _sysctlValueBuf = malloc(16);
      // 名字写进 C 字符串：“hw.memsize” + \0，进程生命周期内复用。
      const key = 'hw.memsize';
      final nameBuf = malloc(key.length + 1);
      for (var i = 0; i < key.length; i++) {
        nameBuf[i] = key.codeUnitAt(i);
      }
      nameBuf[key.length] = 0;
      _sysctlNameBuf = nameBuf;
    }
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
  int? threads;
  try {
    threads = parseProcStatusThreads(
        File('/proc/self/status').readAsStringSync());
  } catch (_) {}
  int? totalMemory;
  try {
    totalMemory = parseMemTotalBytes(File('/proc/meminfo').readAsStringSync());
  } catch (_) {}
  if (cpuNs == null && rss == null && pss == null) return null;
  return XBUmeProcessUsage(
    cpuNs: cpuNs,
    rss: rss,
    pss: pss?.$1,
    pssItems: pss?.$2,
    cpuCores: Platform.numberOfProcessors,
    threads: threads,
    totalMemory: totalMemory,
    cpuScope: (os == 'android' || os == 'ohos') ? 'total' : 'core',
    platform: os,
  );
}

/// `/proc/self/status` 的 `Threads:` 字段（行首可能是若干空格）。
int? parseProcStatusThreads(String content) {
  for (final line in content.split('\n')) {
    final field = line.trimLeft();
    if (!field.startsWith('Threads:')) continue;
    final value = int.tryParse(field.substring(8).trim().split(RegExp(r'\s+')).first);
    if (value != null && value > 0) return value;
  }
  return null;
}

/// `/proc/meminfo` 的 `MemTotal:`（单位 kB，返回字节）。
int? parseMemTotalBytes(String content) {
  for (final line in content.split('\n')) {
    final field = line.trimLeft();
    if (!field.startsWith('MemTotal:')) continue;
    final kb =
        int.tryParse(field.substring(9).trim().split(RegExp(r'\s+')).first);
    if (kb != null && kb > 0) return kb * 1024;
  }
  return null;
}

/// 读取 PSS 总量与官方分类。
///
/// 总量取自 `/proc/self/smaps_rollup`（642 字节）：Android 11+ 的
/// `dumpsys meminfo` 与 Android Studio Memory Profiler 的 Total 都是这个
/// 汇总值；逐 VMA 遍历整份 smaps 求和会系统性偏低（实测 API 31 低 ~13%），
/// 不能直接当总量。
///
/// 分类只能用整份 smaps（rollup 没有分类）。读整份 smaps 要解码 2MB+ 文本、
/// 串行 7 万行，开销明显，因此分类降频到 15 秒；总量仍然 3 秒一取。
/// HarmonyOS 对 /proc 有额外限制，两个文件都读不到时返回 null，
/// 前端自动降级到 RSS。
int _pssAtMs = 0;
int _pssItemsAtMs = 0;
int? _pssTotal;
Map<String, int>? _pssItems;

(int, Map<String, int>?)? _readPss(bool ohos) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - _pssAtMs >= 3000) {
    _pssAtMs = now;
    _pssTotal = _readRollupPss();
  }
  // 总量读不到时每次都用整份 smaps 兜底，再读不到就降级 RSS；
  // 总量正常时分类每 15 秒刷一次就够。
  final itemsTtl = _pssTotal == null ? 3000 : 15000;
  if (now - _pssItemsAtMs >= itemsTtl) {
    _pssItemsAtMs = now;
    final breakdown = _readSmapsBreakdown(ohos);
    if (breakdown != null && breakdown.total > 0) {
      _pssItems = breakdown.items;
      _pssTotal ??= breakdown.total;
    }
  }
  if (_pssTotal != null) {
    return (_pssTotal!, _pssItems);
  }
  return null;
}

/// `smaps_rollup` 的 `Pss:` 总量（字节）；读不到返 null。
int? _readRollupPss() {
  try {
    final text = File('/proc/self/smaps_rollup').readAsStringSync();
    for (final line in text.split('\n')) {
      // 字段行在不同内核上可能缩进，也可能顶格。
      final field = line.trimLeft();
      if (!field.startsWith('Pss:')) continue;
      final kb = int.tryParse(field.substring(4).trim().split(RegExp(r'\s+')).first);
      return (kb != null && kb > 0) ? kb * 1024 : null;
    }
  } catch (_) {}
  return null;
}

/// 整份 smaps 按官方分类汇总；读不到返 null。
XBUmePssBreakdown? _readSmapsBreakdown(bool ohos) {
  try {
    final entries = parseSmapsEntries(File('/proc/self/smaps').readAsStringSync());
    return ohos ? ohosPssBreakdown(entries) : androidPssBreakdown(entries);
  } catch (_) {
    return null;
  }
}

int? _currentRss() {
  try {
    return ProcessInfo.currentRss;
  } catch (_) {
    return null;
  }
}
