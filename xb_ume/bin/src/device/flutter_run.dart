// `flutter run` 启动器：最可靠的「起 app 并拿到 VM service」路径。
//
// 与 adb/simctl 的「只启动已安装包」不同，它同时完成编译、安装与调试端口
// 的暴露，因此 xbume_app_launch(via: flutter-run) 能直接把新会话注册进
// MCP，后续工具可立刻操作。
//
// 约束：
//   - 进程句柄留在 server 内，terminate 只按精确 PID kill（严禁宽泛 pkill）；
//   - 启动过程 tee 到 $XB_UME_HOME/launch/<ts>-<device>.log，便于失败排查；
//   - 超时/早退都返回可读错误（带日志尾部），不吞异常。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../paths.dart';
import 'bridge.dart';
import 'live_store.dart';
import 'process.dart';
import 'run_profile.dart';

/// 本机已在跑的 `flutter run`（非本服务拉起），用于启动前体检。
class LocalFlutterRun {
  LocalFlutterRun({required this.pid, this.device, required this.cwd});

  final int pid;

  /// 命令行里的 `-d` / `--device-id`；没有则为 null（自动选设备）。
  final String? device;
  final String cwd;
}

/// 解析 `flutter run` 命令行里的 `-d` / `--device-id` 值；没有则返回 null。
///
/// 只认带值的两种写法（`-d x` / `--device-id=x`），不猜默认设备。
String? parseFlutterRunDevice(String commandLine) {
  final parts = commandLine.split(RegExp(r'\s+'));
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i];
    if (p == '-d' || p == '--device-id') {
      return i + 1 < parts.length ? parts[i + 1] : null;
    }
    if (p.startsWith('--device-id=')) {
      return p.substring('--device-id='.length);
    }
  }
  return null;
}

/// 路径比较用规范形式：能解析符号链接就解析（macOS 的 `/var` → `/private/var`）。
String resolvePathForCompare(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } catch (_) {
    return File(path).absolute.path;
  }
}

// 设备 → 平台键的进程内缓存（启动时按配置选参数用；设备插拔后可能过期，
// 但同一进程里很少变，重启 GUI/MCP 自会重建）。
final Map<String, String> _devicePlatformCache = <String, String>{};

/// 用 `flutter devices --machine` 反查设备平台（android / ios / ohos / macos…）。
///
/// 只有运行配置依赖平台时才调用；查不到返回 null（配置只命中 `*`）。
Future<String?> platformOfDevice(String flutter, String device) async {
  final hit = _devicePlatformCache[device];
  if (hit != null) return hit;
  final r = await runCmd(
    flutter,
    <String>['devices', '--machine'],
    timeout: const Duration(seconds: 20),
  );
  if (!r.ok) return null;
  try {
    final raw = jsonDecode(r.stdout);
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        if ('${e['id']}' != device) continue;
        final key = platformKeyOf('${e['targetPlatform'] ?? ''}');
        if (key != null) _devicePlatformCache[device] = key;
        return key;
      }
    }
  } catch (_) {
    // --machine 输出异常：当未知平台处理。
  }
  return null;
}

/// 从 `Get-CimInstance Win32_Process` 的 CSV（列序 `ProcessId,ParentProcessId`）
/// 里求 [root] 的整棵子树（不含 root 自己）。
///
/// 拆成纯函数便于在非 Windows 机器上单测；深度上限 6 层防环。
List<int> parseDescendantPids(String csv, int root) {
  final childrenOf = <int, List<int>>{};
  for (final line in csv.split('\n')) {
    final cols = line.split(',');
    if (cols.length < 2) continue;
    final child = int.tryParse(cols[0].replaceAll('"', '').trim());
    final parent = int.tryParse(cols[1].replaceAll('"', '').trim());
    if (child == null || parent == null) continue;
    childrenOf.putIfAbsent(parent, () => <int>[]).add(child);
  }
  final out = <int>[];
  void walk(int p, int depth) {
    if (depth > 6) return;
    for (final c in childrenOf[p] ?? const <int>[]) {
      if (c <= 1 || c == root || out.contains(c)) continue;
      out.add(c);
      walk(c, depth + 1);
    }
  }

  walk(root, 0);
  return out;
}

/// 启动失败时给人看的摘要：取输出**末尾**。
///
/// 真正的原因（装包失败 / 端口转发失败 / 编译报错）几乎总在最后，而日志
/// 开头是预启动命令与编译进度；按开头截断只剩“正在编译”，正是最没用的一段。
String launchFailureSummary(List<String> tail, {int max = 400}) {
  final text = tail
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .join(' ');
  final body =
      text.length <= max ? text : '…${text.substring(text.length - max)}';
  final advice = launchFailureAdvice(text);
  if (advice == null) return body;
  return body.isEmpty ? advice : '$body\n$advice';
}

/// 常见启动失败的可执行建议（没命中返回 null）。
String? launchFailureAdvice(String output) {
  final t = output.toLowerCase();
  // hdc 的连接被后台堆积的 hilog 客户端占满时，fport 会报此错：装包其实
  // 已经成功，只是拿不到 VM service。重启 hdc server 是最快的恢复手段
  // （会断开其它正在跑的 hdc 会话，所以只提示、不代劳）。
  if (t.contains('connect server failed') && t.contains('fport')) {
    return 'hdc 端口转发失败（装包通常已成功，只是拿不到 VM service）：先清掉'
        '多余的 hdc 客户端，或执行 `hdc kill -r` 重启 hdc server（会断开其它'
        '正在跑的 hdc 会话），再重新点启动。';
  }
  return null;
}

/// hdc 客户端连不上 hdc server（「Connect server failed」）导致的启动失败。
///
/// 这类报错几乎总是一次性扰动：设备日志流还在跑、`hdc list targets` 也能
/// 回，只是那一下新建连接被拒——装包往往已成功，只是 fport 没建起来。
bool isTransientHdcFailure(String message) =>
    message.toLowerCase().contains('connect server failed');

/// `hdc list targets` 的输出里是否有 [device]（用来判断目标是不是 OHOS）。
bool hdcSeesDevice(String output, String device) {
  final id = device.trim();
  if (id.isEmpty) return false;
  for (final line in output.split('\n')) {
    final t = line.trim();
    if (t == id || t.startsWith('$id ') || t.startsWith('$id\t')) return true;
  }
  return false;
}

/// 从 `ps -ax -o pid,ppid,args` 的输出里挑出**我们遗留的** hdc 日志流客户端。
///
/// 只认「PPID=1（父进程已死）+ `hdc -t <id> hilog`」：这是 GUI「日志」对每台
/// 设备常驻的流，GUI 被硬杀（旧版 `--install` 是 kill -9）后它就成孤儿，每个
/// 占一条 hdc server 连接；攒够了 `fport` 就报 `Connect server failed`。
/// DevEco 的形态是 `hdc -t <id> shell hilog -v time`（多一层 shell 子命令），
/// 不能误杀。
List<int> parseOrphanHdcLogClients(String psOutput) {
  final out = <int>[];
  for (final line in psOutput.split('\n')) {
    final m = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.*)$').firstMatch(line);
    if (m == null) continue;
    final pid = int.tryParse(m.group(1)!);
    if (pid == null || m.group(2) != '1') continue;
    final args = (m.group(3) ?? '').trimRight();
    if (!RegExp(r'(^|[\s/])hdc\s').hasMatch(args)) continue;
    if (!RegExp(r'\s-t\s').hasMatch(args) || !args.endsWith('hilog')) continue;
    if (args.contains(' shell ')) continue;
    out.add(pid);
  }
  return out;
}

/// hdc 体检用到的外部副作用（单测注入假实现，不碰真实 hdc / ps）。
class HdcOps {
  HdcOps({
    required this.listTargets,
    required this.listOrphanPids,
    required this.killPid,
    required this.restartServer,
  });

  final Future<CmdResult> Function(Duration timeout) listTargets;
  final Future<List<int>> Function() listOrphanPids;
  final bool Function(int pid) killPid;
  final Future<void> Function() restartServer;

  /// 真实实现；本机没有 hdc 可执行文件时返回 null（非 OHOS 环境直接跳过）。
  static HdcOps? real() {
    final exe = findExecutable('hdc');
    if (exe == null) return null;
    return HdcOps(
      listTargets: (t) => runCmd(exe, <String>['list', 'targets'], timeout: t),
      listOrphanPids: () async {
        if (Platform.isWindows) return const <int>[];
        final r = await runCmd('ps', <String>['-ax', '-o', 'pid,ppid,args'],
            timeout: const Duration(seconds: 5));
        return r.ok ? parseOrphanHdcLogClients(r.stdout) : const <int>[];
      },
      killPid: (pid) {
        try {
          // 精确 PID + SIGTERM：严禁宽泛 pkill。
          return Process.killPid(pid);
        } catch (_) {
          return false;
        }
      },
      restartServer: () async {
        await runCmd(exe, <String>['kill', '-r'],
            timeout: const Duration(seconds: 15));
      },
    );
  }
}

/// 启动前给 hdc 做一次体检与自愈（只对 OHOS 有意义）。
///
/// 顺序按「能不动 server 就不动」：先回收孤儿 hilog 客户端，再探测
/// `hdc list targets`；仍不通且目标确定是 OHOS 时才重启 hdc server（会断开
/// 其它正在跑的 hdc 会话，所以只在确认要连这台设备时做）。
///
/// 返回做过的事（一句话，写进状态行 / 工具输出）；什么也没做返回 null。
Future<String?> hdcPreflight(
  String device, {
  bool assumeOhos = false,
  HdcOps? ops,
  Duration probeTimeout = const Duration(seconds: 6),
}) async {
  final o = ops ?? HdcOps.real();
  if (o == null) return null;
  final notes = <String>[];

  var probe = await o.listTargets(probeTimeout);
  final isOhos = assumeOhos || (probe.ok && hdcSeesDevice(probe.stdout, device));
  if (!isOhos) return null; // Android / iOS / 桌面：不碰 hdc

  var reaped = 0;
  for (final pid in await o.listOrphanPids()) {
    if (o.killPid(pid)) reaped++;
  }
  if (reaped > 0) notes.add('回收 hdc 遗留日志客户端 $reaped 个');

  // 回收后可能就通了：再探一次，能不动 server 就不动。
  if (!probe.ok) probe = await o.listTargets(probeTimeout);
  if (!probe.ok) {
    await o.restartServer();
    probe = await o.listTargets(probeTimeout);
    notes.add(probe.ok
        ? 'hdc server 无响应，已自动重启'
        : 'hdc server 无响应，自动重启后仍不可用（可能拿不到 VM service）');
  }
  return notes.isEmpty ? null : notes.join('；');
}

/// 一次 flutter run 的结果。
class LaunchResult {
  LaunchResult({
    required this.pid,
    required this.device,
    required this.logPath,
    this.target,
    this.wsUri,
    this.tail = '',
    this.reused = false,
    this.preRunCommands = const <String>[],
    this.preRunLines = const <String>[],
    this.note,
  });

  final int pid;
  final String device;
  final String? target;
  final String logPath;

  /// 解析到的 VM service 地址（waitVm=false 或未就绪时为 null）。
  final String? wsUri;

  /// 失败时的日志尾部（最多 30 行）。
  final String tail;

  /// true 表示命中已有存活会话，直接复用，没有重新拉起（不会重装包）。
  final bool reused;

  /// 项目运行配置里实际执行过的预启动命令（复用会话时为空）。
  final List<String> preRunCommands;

  /// 预启动命令的输出行（已带 `[pre-run]` 前缀，同时也是日志文件头部）。
  final List<String> preRunLines;

  /// 给人看的额外说明（如「hdc 拒连，已自动重试一次」）。
  final String? note;
}

/// 正在运行的 flutter run 句柄。
class LaunchHandle {
  LaunchHandle({
    required this.pid,
    required this.device,
    required this.target,
    required this.logPath,
    required this.startedAt,
    required this.cwd,
    this.platform,
    this.process,
    this.fifo,
    this.adopted = false,
    this.owner = 'mcp',
  });

  final int pid;
  final String device;
  final String? target;
  final String logPath;
  final DateTime startedAt;

  /// 启动时的工作目录（复用判定按符号链接归一后的路径比较）。
  final String cwd;

  /// 目标平台（android / ios / ohos / macos…）：运行配置按它选参数与展开变量。
  /// 认领来的旧会话可能为空。
  final String? platform;

  /// 自己拉起的 flutter run 进程；认领来的进程为 null（拿不到句柄）。
  final Process? process;

  /// stdin 用的命名管道；null 表示该平台/会话不支持外部写 stdin。
  final String? fifo;

  /// true 表示从磁盘清单认领，不是本进程拉起。
  final bool adopted;

  /// 拉起方：mcp / gui。仅用于展示。
  final String owner;

  String? wsUri;

  final StreamController<String> _lines = StreamController<String>.broadcast();
  final List<String> _recent = <String>[];

  /// 实时输出（stdout + stderr 合并，按行）。
  Stream<String> get lines => _lines.stream;

  /// 最近 400 行输出（超时/失败时回给调用方排障）。
  List<String> get recent => List<String>.unmodifiable(_recent);

  void addLine(String line) {
    _recent.add(line);
    if (_recent.length > 400) _recent.removeRange(0, _recent.length - 400);
    if (!_lines.isClosed) _lines.add(line);
  }

  void dispose() {
    if (!_lines.isClosed) _lines.close();
  }
}

/// 一次热重载 / 热重启的结果。
class HotReloadResult {
  HotReloadResult({
    required this.ok,
    required this.restart,
    required this.pid,
    required this.elapsedMs,
    required this.message,
    this.lines = const <String>[],
  });

  final bool ok;
  final bool restart;
  final int pid;
  final int elapsedMs;

  /// 命中的完成标记行，或超时/失败说明。
  final String message;

  /// 本次等待窗口内新增的输出（最多 60 行）。
  final List<String> lines;
}

/// 停止结果：flutter run 进程是否被结束，以及随之结束的子进程（app 本体）。
class StopResult {
  StopResult({
    required this.stopped,
    this.children = const <int>[],
    this.postStopLines = const <String>[],
  });

  final bool stopped;
  final List<int> children;

  /// 停止后执行的项目清理命令输出（已带 `[post-stop]` 前缀）。
  final List<String> postStopLines;
}

/// flutter run 进程管理（单实例挂在 McpToolContext 上）。
class FlutterRunLauncher {
  FlutterRunLauncher({this.hdcOps});

  /// 启动前 hdc 体检用的副作用集合（null=真实实现；单测注入假实现）。
  final HdcOps? hdcOps;

  final Map<int, LaunchHandle> _live = <int, LaunchHandle>{};

  List<LaunchHandle> get live => _live.values.toList(growable: false);

  LaunchHandle? byPid(int pid) => _live[pid];

  /// 扫描本机正在跑的 `flutter run`（排除本服务自己拉起的），只读，不做任何 kill。
  ///
  /// 识别方式：命令行含 `flutter_tools.snapshot` 且其后第一个子命令是 `run`；
  /// 设备取 `-d` / `--device-id`，工作目录取 `lsof -d cwd`。
  List<LocalFlutterRun> localFlutterRuns() {
    if (Platform.isWindows) return const <LocalFlutterRun>[];
    final pids = <int>[];
    final devices = <String?>[];
    try {
      final r = Process.runSync('ps', <String>['-axo', 'pid,command']);
      if (r.exitCode != 0) return const <LocalFlutterRun>[];
      for (final line in '${r.stdout}'.split('\n')) {
        final t = line.trim();
        final sp = t.indexOf(' ');
        if (sp <= 0) continue;
        final pid = int.tryParse(t.substring(0, sp));
        if (pid == null || _live.containsKey(pid)) continue;
        final cmd = t.substring(sp + 1);
        final snap = cmd.indexOf('flutter_tools.snapshot');
        if (snap < 0) continue;
        final rest = cmd.substring(snap + 'flutter_tools.snapshot'.length).trim();
        if (rest.isEmpty || rest.split(RegExp(r'\s+')).first != 'run') continue;
        pids.add(pid);
        devices.add(parseFlutterRunDevice(cmd));
      }
    } catch (_) {
      return const <LocalFlutterRun>[];
    }
    if (pids.isEmpty) return const <LocalFlutterRun>[];
    final cwds = _cwdsOf(pids);
    final out = <LocalFlutterRun>[];
    for (var i = 0; i < pids.length; i++) {
      final cwd = cwds[pids[i]];
      if (cwd == null || cwd.isEmpty) continue;
      out.add(LocalFlutterRun(pid: pids[i], device: devices[i], cwd: cwd));
    }
    return out;
  }

  /// 同设备 + 同目录下已在运行的 flutter run（启动前体检用）。
  ///
  /// 只问「同一个 app 已经在这个设备上跑着」这种会互相顶掉的场景；
  /// 同设备但不同目录不拦，交给调用方判断。
  LocalFlutterRun? findConflict({
    required String device,
    required String cwd,
  }) {
    final target = resolvePathForCompare(cwd);
    for (final r in localFlutterRuns()) {
      if (r.device != device) continue;
      if (resolvePathForCompare(r.cwd) != target) continue;
      return r;
    }
    return null;
  }

  /// 批量取进程工作目录（pid → cwd）。lsof 不可用时返回空表。
  Map<int, String> _cwdsOf(List<int> pids) {
    final out = <int, String>{};
    try {
      final r = Process.runSync(
        'lsof',
        <String>['-a', '-p', pids.join(','), '-d', 'cwd', '-Fn'],
      );
      if (r.exitCode != 0) return out;
      int? cur;
      for (final line in '${r.stdout}'.split('\n')) {
        final t = line.trim();
        if (t.startsWith('p')) {
          cur = int.tryParse(t.substring(1));
        } else if (t.startsWith('n') && cur != null) {
          out[cur] = t.substring(1);
        }
      }
    } catch (_) {
      // lsof 不可用：按无冲突处理。
    }
    return out;
  }

  /// 启动 `flutter run -d <device>` 并等待 VM service 地址。
  ///
  /// 复用优先级（`force: false` 时）：
  ///   1. 本服务 / GUI 已拉起且有 VM 地址的同设备同目录同 target 进程 → 直接复用；
  ///   2. 正在启动中的同类进程 → 报错让调用方稍后重试（避免并发重装包）；
  ///   3. 外部（IDE 拉起）的同设备同目录进程 → 报错，除非 `force: true`。
  /// `force: true` 会先停掉自己拉起的同类会话，再重新拉起。
  ///
  /// 遇到 hdc 的一次性拒连（[isTransientHdcFailure]）会自动重试一次：
  /// 编译与装包已经完成，第二次是增量构建，比让用户再点一次（还可能再
  /// 撞上）划算；第二次仍失败就把错误原样抛给调用方。
  Future<LaunchResult> launch({
    required String device,
    String? target,
    String? cwd,
    String? platform,
    bool waitVm = true,
    bool force = false,
    String owner = 'mcp',
    Duration timeout = const Duration(seconds: 180),
  }) async {
    try {
      return await launchOnce(
        device: device,
        target: target,
        cwd: cwd,
        platform: platform,
        waitVm: waitVm,
        force: force,
        owner: owner,
        timeout: timeout,
      );
    } on DeviceCommandError catch (e) {
      if (!isTransientHdcFailure(e.message)) rethrow;
      // hdc server 那一下拒连：隔一秒再拉一次（第一次启动进程已退出，
      // 不会与新会话冲突）。
      await Future<void>.delayed(const Duration(seconds: 1));
      return launchOnce(
        device: device,
        target: target,
        cwd: cwd,
        platform: platform,
        waitVm: waitVm,
        force: force,
        owner: owner,
        timeout: timeout,
        retryNote: 'hdc 上次拒连（Connect server failed），已自动重试一次',
      );
    }
  }

  /// 单次启动实现（[launch] 的重试外壳会调两次；单测直接覆写它）。
  Future<LaunchResult> launchOnce({
    required String device,
    String? target,
    String? cwd,
    String? platform,
    bool waitVm = true,
    bool force = false,
    String owner = 'mcp',
    Duration timeout = const Duration(seconds: 180),
    String? retryNote,
  }) async {
    final flutter = resolveFlutter();
    if (flutter == null) {
      throw DeviceCommandError(
        'flutter-run',
        'flutter run',
        '未找到 flutter 可执行文件：PATH 里没有，也没在常见安装位置找到。'
            '把 flutter 的 bin 目录加进 PATH，或用环境变量 XB_UME_FLUTTER 指定'
            '（可给 flutter 可执行文件或 SDK 根目录）。',
      );
    }
    final workdir = (cwd == null || cwd.trim().isEmpty) ? Directory.current.path : cwd;
    if (!Directory(workdir).existsSync()) {
      throw DeviceCommandError('flutter-run', 'flutter run', '工作目录不存在：$workdir');
    }
    final logDir = Directory('${xbUmeHome()}/launch');
    if (!logDir.existsSync()) logDir.createSync(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final logPath = '${logDir.path}/$stamp-$device.log';

    // OHOS：起进程前先给 hdc 做一次体检与自愈（拒连时 fport 必然失败，白编译
    // 一遍还会再多一个孤儿客户端）。放在启动锁外：重启 server 要几秒，不占锁。
    final preflightNote = await hdcPreflight(
      device,
      assumeOhos: platform == 'ohos',
      ops: hdcOps,
    );
    final notes = <String>[
      if (retryNote != null) retryNote,
      if (preflightNote != null) preflightNote,
    ];

    var locked = false;
    IOSink? sink;
    String? fifo;
    // 预启动命令与输出（复用会话时保持为空）。
    final preRunCommands = <String>[];
    final preRunLines = <String>[];
    late final Process proc;
    late final LaunchHandle handle;
    try {
      // 锁只护「判定 + 起进程」这一段：GUI 与 MCP 同时点启动时不各起一个。
      locked = acquireLaunchLock();
      // 先把磁盘清单里的旧进程纳入视野（自己或对方重启后仍能复用）。
      adoptRecords();
      final existing = _findLiveSameRun(device: device, cwd: workdir, target: target);
      if (existing != null) {
        if (force) {
          // 显式重启语义：先精确停掉旧会话，再走下面的启动流程。
          await stop(existing.pid);
        } else if (existing.wsUri != null) {
          return LaunchResult(
            pid: existing.pid,
            device: device,
            target: target,
            logPath: existing.logPath,
            wsUri: existing.wsUri,
            reused: true,
            tail: existing.recent.length > 20
                ? existing.recent.sublist(existing.recent.length - 20).join('\n')
                : existing.recent.join('\n'),
          );
        } else {
          throw DeviceCommandError(
            'flutter-run',
            'flutter run -d $device',
            '设备 $device 上已有一条本服务拉起的 flutter run（pid ${existing.pid}，目录 ${existing.cwd}）'
                '正在启动或等待调试端口；稍后重试，或先停止它（force 会重建）。',
          );
        }
      }
      // 体检：外部（IDE）拉起的同设备同目录会话，继续会重装包并顶掉它。
      if (!force) {
        final conflict = findConflict(device: device, cwd: workdir);
        if (conflict != null) {
          throw DeviceCommandError(
            'flutter-run',
            'flutter run -d $device',
            '设备 $device 上已有 flutter run 正在同一目录跑（pid ${conflict.pid}，目录 ${conflict.cwd}）：'
                '继续会在手机上重装包并顶掉它（IDE 会报 Lost connection to device）。'
                '要复用现有会话直接 xbume_sessions → xbume_use_session（该会话不支持热重载）；'
                '确认重新拉起请传 force: true。',
          );
        }
      }

      // 项目级运行配置：与 IDE 的 preLaunchTask 等价。没有配置 / 配置损坏 /
      // 配置限定了平台且当前设备不在其中时，active 为 null：下面不执行任何
      // 额外命令、不追加任何参数。
      final profile = loadRunProfile(workdir);
      final platformKey = platformKeyOf(platform) ??
          (profile != null && profile.needsPlatform()
              ? await platformOfDevice(flutter, device)
              : null);
      final active = (profile != null && profile.appliesTo(platformKey))
          ? profile
          : null;
      if (active != null && active.preRun.isNotEmpty) {
        for (final raw in active.preRun) {
          preRunCommands.add(expandRunVars(
            raw,
            projectRoot: workdir,
            device: device,
            target: target,
            platform: platformKey,
          ));
        }
        final results = await runProfileCommands(
          preRunCommands,
          cwd: workdir,
          timeout: Duration(seconds: active.timeoutSec),
          onLine: preRunLines.add,
        );
        // 预启动输出写在日志文件头部：FIFO 模式用 >> 追加，GUI 的
        // 输出区从文件头读，能看到准备过程。
        if (preRunLines.isNotEmpty) {
          try {
            File(logPath).writeAsStringSync(
              '${preRunLines.join('\n')}\n',
              mode: FileMode.append,
            );
          } catch (_) {
            // 日志写失败不影响启动。
          }
        }
        final failed = results.where((r) => !r.ok).toList();
        if (failed.isNotEmpty && !active.continueOnError) {
          throw DeviceCommandError('flutter-run', 'pre-run', failed.first.errorText);
        }
      }
      final runArgs = <String>[
        'run',
        '-d',
        device,
        if (target != null && target.isNotEmpty) ...<String>['--target', target],
        if (active != null) ...active.argsFor(platformKey),
      ];
      // stdin 换成命名管道：拉起方或任何后续实例都能 `printf 'r\n' > fifo`
      // 触发热重载；exec 不换 pid，kill 依旧精确。
      //
      // 注意：fd3 用读写方式（3<>）只为了「持住写端」，让下面只读打开 stdin
      // 不阻塞、也不会因外部写者退出而 EOF。不能直接把 <&3 当 stdin——
      // Dart 的 stdin 从 O_RDWR 的 FIFO 上读不到数据（实测 r/h/q 全部无效）。
      //
      // 输出直接重定向到日志文件（而非管道）：拉起方退出（MCP/GUI 重启）后
      // flutter run 仍在写日志，不会因管道读端消失而 SIGPIPE 死掉。
      // mkfifo 不可用时（Windows）退回直启 + 管道转发。
      final fifo0 = createLaunchFifo();
      fifo = fifo0;
      if (fifo0 != null) {
        proc = await Process.start(
          'sh',
          <String>[
            '-c',
            r'fifo="$1"; log="$2"; shift 2; exec 3<>"$fifo"; exec "$@" >> "$log" 2>&1 < "$fifo"',
            'sh',
            fifo0,
            logPath,
            flutter,
            ...runArgs,
          ],
          workingDirectory: workdir,
          environment: execEnvironment(),
        );
      } else {
        // append 而不是 truncate：日志文件开头已经有预启动命令的输出。
        sink = File(logPath).openWrite(mode: FileMode.append);
        proc = await Process.start(
          flutter,
          runArgs,
          workingDirectory: workdir,
          environment: execEnvironment(),
          // Windows 上 flutter 是 flutter.bat：CreateProcess 不能直接执行批处理，
          // 必须走 cmd；其他平台（或原生 .exe）保持直启。
          runInShell: needsShellOnWindows(flutter),
        );
      }
      handle = LaunchHandle(
        pid: proc.pid,
        device: device,
        target: target,
        logPath: logPath,
        startedAt: DateTime.now(),
        cwd: workdir,
        platform: platformKey,
        process: proc,
        fifo: fifo,
        owner: owner,
      );
      _live[proc.pid] = handle;
      _writeRecord(handle);
    } on ProcessException catch (e) {
      throw DeviceCommandError('flutter-run', 'flutter run', e.message);
    } catch (_) {
      rethrow;
    } finally {
      if (locked) releaseLaunchLock();
    }

    // 输出统一落到日志文件：
    //   - FIFO 模式由 sh 直接重定向，本进程退出也不影响 flutter run；
    //   - 没有 FIFO（Windows）时走进程管道，由 pump 转发。
    final tail = <String>[];
    final vmReady = Completer<String?>();
    final vmPattern = RegExp(r'A Dart VM Service .* is available at:\s*(http\S+)');
    var outputStopped = false;

    Future<void> pump(Stream<List<int>> stream) async {
      await for (final chunk
          in stream.transform(utf8.decoder).transform(const LineSplitter())) {
        sink?.writeln(chunk);
        handle.addLine(chunk);
        tail.add(chunk);
        if (tail.length > 60) tail.removeAt(0);
        if (!vmReady.isCompleted) {
          final m = vmPattern.firstMatch(chunk);
          if (m != null) {
            handle.wsUri = m.group(1)!;
            _writeRecord(handle);
            vmReady.complete(handle.wsUri);
          }
        }
      }
    }

    if (fifo != null) {
      unawaited(_tailLog(
        handle,
        stopped: () => outputStopped,
        vmReady: vmReady,
        vmPattern: vmPattern,
        tail: tail,
      ));
    } else {
      unawaited(pump(proc.stdout));
      unawaited(pump(proc.stderr));
    }

    final exited = proc.exitCode.then((code) async {
      outputStopped = true;
      await sink?.flush();
      await sink?.close();
      return code;
    });
    // 进程退出后清清单与 FIFO，避免下次认领到死进程。
    unawaited(proc.exitCode.then((_) => _cleanupExited(proc.pid)));

    if (!waitVm) {
      // 只确认进程没有立刻退出。
      final early = await Future.any<int?>(<Future<int?>>[
        exited,
        Future<int?>.delayed(const Duration(milliseconds: 1500), () => null),
      ]);
      if (early != null) {
        _cleanupExited(proc.pid);
        await sink?.close();
        throw DeviceCommandError('flutter-run', 'flutter run',
            '进程启动即退出（code=$early）：${oneLine(tail.join(' '), max: 400)}');
      }
      return LaunchResult(
        pid: proc.pid,
        device: device,
        target: target,
        logPath: logPath,
        tail: tail.join('\n'),
        preRunCommands: preRunCommands,
        preRunLines: preRunLines,
        note: notes.isEmpty ? null : notes.join('；'),
      );
    }

    final ready = await _waitVm(vmReady.future, exited, timeout);
    if (ready == null) {
      // 超时/早退：留进程继续跑（可能只是编译慢），把日志尾部回给调用方判断。
      // 带上 logPath：GUI 据此把完整日志接到「运行输出」，不只给一条摘要。
      throw DeviceCommandError(
        'flutter-run',
        'flutter run',
        '等待 VM service 超时（${timeout.inSeconds}s）或进程退出\n'
            '${launchFailureSummary(tail)}\n'
            '完整日志：$logPath',
        logPath: logPath,
      );
    }
    return LaunchResult(
      pid: proc.pid,
      device: device,
      target: target,
      logPath: logPath,
      wsUri: ready,
      tail: tail.join('\n'),
      preRunCommands: preRunCommands,
      preRunLines: preRunLines,
      note: notes.isEmpty ? null : notes.join('；'),
    );
  }
  
  /// 把磁盘清单里仍存活的 flutter run 认领进内存（自己或其他实例拉起过）。
  ///
  /// 只校验「pid 存活 + 命令行仍是 flutter run」；陈旧记录直接删除。
  List<LaunchHandle> adoptRecords() {
    final adopted = <LaunchHandle>[];
    for (final r in readLaunchRecords()) {
      if (_live.containsKey(r.pid)) continue;
      if (!recordStillValid(r)) {
        removeLaunchRecord(r.pid);
        removeLaunchFifo(r.fifo);
        continue;
      }
      final h = LaunchHandle(
        pid: r.pid,
        device: r.device,
        target: r.target,
        logPath: r.logPath ?? '',
        startedAt: r.startedAt,
        cwd: r.cwd,
        platform: r.platform,
        fifo: r.fifo,
        adopted: true,
        owner: r.owner,
      )..wsUri = r.wsUri;
      _live[r.pid] = h;
      adopted.add(h);
    }
    return adopted;
  }
  
  void _writeRecord(LaunchHandle h) {
    writeLaunchRecord(LaunchRecord(
      pid: h.pid,
      device: h.device,
      cwd: h.cwd,
      startedAt: h.startedAt,
      target: h.target,
      platform: h.platform,
      wsUri: h.wsUri,
      logPath: h.logPath,
      fifo: h.fifo,
      owner: h.owner,
    ));
  }
  
  void _cleanupExited(int pid) {
    removeLaunchRecord(pid);
    final h = _live.remove(pid);
    if (h == null) return;
    removeLaunchFifo(h.fifo);
    h.dispose();
  }
  
  /// 同设备 + 同目录 + 同 target 的本服务会话；不存在返回 null。
  LaunchHandle? _findLiveSameRun({
    required String device,
    required String cwd,
    String? target,
  }) {
    final normalized = resolvePathForCompare(cwd);
    LaunchHandle? hit;
    final dead = <int>[];
    for (final h in _live.values) {
      if (h.device != device) continue;
      if (resolvePathForCompare(h.cwd) != normalized) continue;
      if ((h.target ?? '') != (target ?? '')) continue;
      if (!_isAlive(h.pid)) {
        dead.add(h.pid);
        continue;
      }
      hit = h;
      break;
    }
    for (final pid in dead) {
      removeLaunchRecord(pid);
      _live.remove(pid)?.dispose();
    }
    return hit;
  }

  /// 等 VM service 地址；进程退出或超时返回 null。
  Future<String?> _waitVm(
    Future<String?> ready,
    Future<int> exited,
    Duration timeout,
  ) async {
    final done = Completer<String?>();
    unawaited(ready.then((url) {
      if (!done.isCompleted) done.complete(url);
    }));
    unawaited(exited.then((_) {
      if (!done.isCompleted) done.complete(null);
    }));
    return done.future.timeout(timeout, onTimeout: () => null);
  }

  /// 按端口反查自己拉起的 flutter run（会话 → 进程）。
  int? pidForPort(int port) {
    for (final h in _live.values) {
      final u = h.wsUri;
      if (u == null) continue;
      if (Uri.tryParse(u)?.port == port) return h.pid;
    }
    return null;
  }

  /// 触发热重载（r）或热重启（R）。
  ///
  /// 对本服务或 GUI 拉起的会话都生效：优先向 FIFO 写按键（跨进程），没有
  /// FIFO 时退回自己进程的 stdin。flutter run 虽在非 TTY 下不会进
  /// singleCharMode，但 `TerminalHandler` 仍监听 stdin（`processTerminalInput`
  /// 会 trim），所以管道写入可用。
  Future<HotReloadResult> hotReload(
    int pid, {
    bool restart = false,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final h = _live[pid];
    if (h == null) {
      throw DeviceCommandError(
          'flutter-run', 'hot reload', '未找到由本服务拉起的 flutter run 进程（pid $pid）');
    }
    final sw = Stopwatch()..start();
    final captured = <String>[];
    final done = Completer<HotReloadResult>();
    final successRe = restart
        ? RegExp(r'Restarted application|Hot restart performed')
        : RegExp(r'Reloaded \d+ (?:of \d+ )?libraries|Hot reload performed|No changes detected');
    final failRe = restart
        ? RegExp(r'Hot restart failed|Failed to restart|Compilation failed|Error: Compiler message')
        : RegExp(r'Hot reload was rejected|Hot reload failed|Failed to hot reload|Compilation failed|Error: Compiler message');

    void finish(bool ok, String message) {
      if (done.isCompleted) return;
      done.complete(HotReloadResult(
        ok: ok,
        restart: restart,
        pid: pid,
        elapsedMs: sw.elapsedMilliseconds,
        message: message,
        lines: List<String>.of(captured),
      ));
    }

    final proc = h.process;
    var stopped = false;

    void onLine(String line) {
      captured.add(line);
      if (captured.length > 60) captured.removeAt(0);
      if (successRe.hasMatch(line)) {
        finish(true, line.trim());
      } else if (failRe.hasMatch(line)) {
        finish(false, line.trim());
      }
    }

    if (proc != null) {
      // 进程中途退出时不要干等到超时。
      unawaited(proc.exitCode.then((code) {
        if (!done.isCompleted) finish(false, 'flutter run 已退出（code=$code）');
      }));
    } else {
      // 认领来的进程没有输出跟随：临时从日志末尾跟一份（只关心新行）。
      unawaited(_tailLog(h, stopped: () => stopped, fromEnd: true));
    }

    final sub = h.lines.listen(onLine);

    // 写 r / R：FIFO 优先（拉起者重启、GUI/MCP 交叉控制都能用）。
    var wrote = false;
    final fifo = h.fifo;
    if (fifo != null && fifo.isNotEmpty) {
      wrote = await writeLaunchFifo(fifo, restart ? 'R\n' : 'r\n');
    }
    if (!wrote && proc != null) {
      try {
        proc.stdin.writeln(restart ? 'R' : 'r');
        await proc.stdin.flush();
        wrote = true;
      } catch (e) {
        stopped = true;
        await sub.cancel();
        throw DeviceCommandError(
            'flutter-run', 'hot reload', 'stdin 写入失败（进程可能已退出）：$e');
      }
    }
    if (!wrote) {
      stopped = true;
      await sub.cancel();
      throw DeviceCommandError(
        'flutter-run',
        'hot reload',
        '无法向 pid $pid 写 stdin（该会话由上一个实例拉起且没有可用 FIFO）：'
            'Windows 或旧版会话只能查看输出与停止；需要热重载请停止后用 app_launch 重新拉起。',
      );
    }

    final result = await done.future.timeout(
      timeout,
      onTimeout: () => HotReloadResult(
        ok: false,
        restart: restart,
        pid: pid,
        elapsedMs: sw.elapsedMilliseconds,
        message: '等待 ${timeout.inSeconds}s 未看到${restart ? '热重启' : '热重载'}完成标记',
        lines: <String>[...h.recent.length > 20
            ? h.recent.sublist(h.recent.length - 20)
            : h.recent],
      ),
    );
    stopped = true;
    await sub.cancel();
    return result;
  }

  /// 跟随日志文件增量：把新行送进 [LaunchHandle.lines]，并按需解析 VM 地址。
  ///
  /// FIFO 模式下 flutter run 的输出由 shell 直接写文件（没有管道句柄），
  /// 本方法与 [stopped] 配合一直跟到进程退出；[fromEnd] 为 true 时从当前
  /// 末尾开始（认领场景只看新输出）。
  Future<void> _tailLog(
    LaunchHandle h, {
    required bool Function() stopped,
    Completer<String?>? vmReady,
    RegExp? vmPattern,
    List<String>? tail,
    bool fromEnd = false,
  }) async {
    final path = h.logPath;
    if (path.isEmpty) return;
    final f = File(path);
    var offset = fromEnd ? (f.existsSync() ? f.lengthSync() : 0) : 0;
    var pending = '';
    final pattern = vmPattern ??
        RegExp(r'A Dart VM Service .* is available at:\s*(http\S+)');
    while (!stopped()) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!f.existsSync()) continue;
      final len = f.lengthSync();
      if (len < offset) {
        offset = 0; // 文件被截断 / 轮转
        pending = '';
      }
      if (len == offset) continue;
      RandomAccessFile? raf;
      try {
        raf = f.openSync();
        raf.setPositionSync(offset);
        final chunk = utf8.decode(raf.readSync(len - offset), allowMalformed: true);
        offset = len;
        pending += chunk;
        final parts = pending.split('\n');
        pending = parts.removeLast(); // 末尾可能是半行
        for (final line in parts) {
          h.addLine(line);
          if (tail != null) {
            tail.add(line);
            if (tail.length > 60) tail.removeAt(0);
          }
          if (vmReady != null && !vmReady.isCompleted) {
            final m = pattern.firstMatch(line);
            if (m != null) {
              h.wsUri = m.group(1)!;
              _writeRecord(h);
              vmReady.complete(h.wsUri);
            }
          }
          if (stopped()) break;
        }
      } catch (_) {
        offset = 0;
      } finally {
        try {
          raf?.closeSync();
        } catch (_) {}
      }
    }
  }

  /// 按精确 PID 结束 flutter run，并把它的子进程（被拉起的 app）一并结束。
  ///
  /// 先 SIGTERM，3 秒后 SIGKILL；子进程必须在杀父进程**之前**取快照，
  /// 否则 parent 退出后它们会被 init 收养，无从得知归属。
  /// 杀完再跑项目运行配置里的 `postStop`（如 iOS 还原 pbxproj 签名）。
  Future<StopResult> stop(int pid) async {
    // 清理命令要用启动时的目录/设备/平台，必须在 _cleanupExited 之前取。
    final h = _live[pid];
    final children = Platform.isWindows
        ? await _descendantsOnWindows(pid)
        : _childrenOf(pid);
    final alive = Process.killPid(pid, ProcessSignal.sigterm);
    if (!alive) {
      _cleanupExited(pid);
      return StopResult(stopped: false, postStopLines: await _runPostStop(h));
    }
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!_isAlive(pid)) break;
    }
    if (_isAlive(pid)) Process.killPid(pid, ProcessSignal.sigkill);
    _cleanupExited(pid);
    final killed = <int>[];
    for (final c in children) {
      if (c <= 1 || c == pid) continue;
      if (!_isAlive(c)) continue;
      Process.killPid(c, ProcessSignal.sigterm);
      killed.add(c);
    }
    // 给 app 一点退出时间，顽固的再补一刀。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    for (final c in killed) {
      if (_isAlive(c)) Process.killPid(c, ProcessSignal.sigkill);
    }
    return StopResult(
      stopped: true,
      children: killed,
      postStopLines: await _runPostStop(h),
    );
  }

  /// 执行项目运行配置里的停止后清理命令；失败只回提示，不影响「已停止」。
  Future<List<String>> _runPostStop(LaunchHandle? h) async {
    if (h == null) return const <String>[];
    final profile = loadRunProfile(h.cwd);
    if (profile == null || profile.postStop.isEmpty) return const <String>[];
    final cmds = <String>[
      for (final raw in profile.postStop)
        expandRunVars(
          raw,
          projectRoot: h.cwd,
          device: h.device,
          target: h.target,
          platform: h.platform,
        ),
    ];
    final lines = <String>[];
    try {
      await runProfileCommands(
        cmds,
        cwd: h.cwd,
        timeout: Duration(seconds: profile.timeoutSec),
        tag: 'post-stop',
        onLine: lines.add,
      );
    } catch (_) {
      // 会话已经停了，清理失败只提示。
    }
    return lines;
  }

  /// 直接子进程（ps -axo pid,ppid）。
  List<int> _childrenOf(int pid) {
    try {
      final r = Process.runSync('ps', <String>['-axo', 'pid,ppid']);
      if (r.exitCode != 0) return const <int>[];
      final out = <int>[];
      for (final line in '${r.stdout}'.split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        if (int.tryParse(parts[1]) == pid) {
          final c = int.tryParse(parts[0]);
          if (c != null) out.add(c);
        }
      }
      return out;
    } catch (_) {
      return const <int>[];
    }
  }

  /// Windows 上没有 ps：一次 PowerShell 取全表（pid,ppid），本地求整棵子树。
  ///
  /// `flutter.bat` 会经 cmd 再拉起 dart（flutter_tools），app 本体是孙进程，
  /// 只取一层会漏掉 app，所以这里递归到底。
  Future<List<int>> _descendantsOnWindows(int pid) async {
    try {
      final r = await Process.run('powershell', <String>[
        '-NoProfile',
        '-Command',
        'Get-CimInstance Win32_Process | '
            'Select-Object ProcessId,ParentProcessId | '
            'ConvertTo-Csv -NoTypeInformation',
      ]);
      if (r.exitCode != 0) return const <int>[];
      return parseDescendantPids('${r.stdout}', pid);
    } catch (_) {
      return const <int>[];
    }
  }

  bool _isAlive(int pid) => pidAlive(pid);
}
