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
import 'process.dart';

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

/// 一次 flutter run 的结果。
class LaunchResult {
  LaunchResult({
    required this.pid,
    required this.device,
    required this.logPath,
    this.target,
    this.wsUri,
    this.tail = '',
  });

  final int pid;
  final String device;
  final String? target;
  final String logPath;

  /// 解析到的 VM service 地址（waitVm=false 或未就绪时为 null）。
  final String? wsUri;

  /// 失败时的日志尾部（最多 30 行）。
  final String tail;
}

/// 正在运行的 flutter run 句柄。
class LaunchHandle {
  LaunchHandle({
    required this.pid,
    required this.device,
    required this.target,
    required this.logPath,
    required this.startedAt,
    required this.process,
  });

  final int pid;
  final String device;
  final String? target;
  final String logPath;
  final DateTime startedAt;

  /// 自己拉起的 flutter run 进程：stdin 用于热重载（r / R），只碰自己的进程。
  final Process process;
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
  StopResult({required this.stopped, this.children = const <int>[]});

  final bool stopped;
  final List<int> children;
}

/// flutter run 进程管理（单实例挂在 McpToolContext 上）。
class FlutterRunLauncher {
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
  /// [cwd] 默认当前工作目录（MCP server 由使用方指定工程目录启动）。
  /// [waitVm] 为 false 时只看进程是否起来，不等待调试端口（用于纯 UI 验证）。
  /// [force] 为 true 时跳过「同设备同目录已有 flutter run」的体检。
  Future<LaunchResult> launch({
    required String device,
    String? target,
    String? cwd,
    bool waitVm = true,
    bool force = false,
    Duration timeout = const Duration(seconds: 180),
  }) async {
    final flutter = findExecutable('flutter');
    if (flutter == null) {
      throw DeviceCommandError(
          'flutter-run', 'flutter run', '未找到 flutter 可执行文件（检查 PATH）');
    }
    final workdir = (cwd == null || cwd.trim().isEmpty) ? Directory.current.path : cwd;
    if (!Directory(workdir).existsSync()) {
      throw DeviceCommandError('flutter-run', 'flutter run', '工作目录不存在：$workdir');
    }
    // 体检：同设备 + 同目录已有 flutter run 时默认不重复拉起（手机上重装包
    // 会直接顶掉那个会话，IDE 会报 Lost connection to device）。
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
    final logDir = Directory('${xbUmeHome()}/launch');
    if (!logDir.existsSync()) logDir.createSync(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final logPath = '${logDir.path}/$stamp-$device.log';
    final sink = File(logPath).openWrite();

    final Process proc;
    try {
      proc = await Process.start(
        flutter,
        <String>['run', '-d', device, if (target != null && target.isNotEmpty) ...<String>['--target', target]],
        workingDirectory: workdir,
        // Windows 上 flutter 是 flutter.bat：CreateProcess 不能直接执行批处理，
        // 必须走 cmd；其他平台（或原生 .exe）保持直启。
        runInShell: needsShellOnWindows(flutter),
      );
    } on ProcessException catch (e) {
      await sink.close();
      throw DeviceCommandError('flutter-run', 'flutter run', e.message);
    }

    final handle = LaunchHandle(
      pid: proc.pid,
      device: device,
      target: target,
      logPath: logPath,
      startedAt: DateTime.now(),
      process: proc,
    );
    _live[proc.pid] = handle;

    final tail = <String>[];
    final vmReady = Completer<String?>();
    final vmPattern = RegExp(r'A Dart VM Service .* is available at:\s*(http\S+)');

    Future<void> pump(Stream<List<int>> stream) async {
      await for (final chunk in stream.transform(utf8.decoder).transform(const LineSplitter())) {
        sink.writeln(chunk);
        handle.addLine(chunk);
        tail.add(chunk);
        if (tail.length > 60) tail.removeAt(0);
        if (!vmReady.isCompleted) {
          final m = vmPattern.firstMatch(chunk);
          if (m != null) {
            handle.wsUri = m.group(1)!;
            vmReady.complete(handle.wsUri);
          }
        }
      }
    }

    final outPump = pump(proc.stdout);
    final errPump = pump(proc.stderr);
    final exited = proc.exitCode.then((code) => code);

    if (!waitVm) {
      // 只确认进程没有立刻退出。
      final early = await Future.any<int?>(<Future<int?>>[
        exited,
        Future<int?>.delayed(const Duration(milliseconds: 1500), () => null),
      ]);
      if (early != null) {
        _live.remove(proc.pid);
        await sink.close();
        throw DeviceCommandError('flutter-run', 'flutter run',
            '进程启动即退出（code=$early）：${oneLine(tail.join(' '), max: 400)}');
      }
      return LaunchResult(
        pid: proc.pid,
        device: device,
        target: target,
        logPath: logPath,
        tail: tail.join('\n'),
      );
    }

    final ready = await _waitVm(vmReady.future, exited, timeout);
    unawaited(outPump);
    unawaited(errPump);
    await sink.flush();
    if (ready == null) {
      // 超时/早退：留进程继续跑（可能只是编译慢），把日志尾部回给调用方判断。
      throw DeviceCommandError(
        'flutter-run',
        'flutter run',
        '等待 VM service 超时（${timeout.inSeconds}s）或进程退出，日志：$logPath\n'
            '${oneLine(tail.join(' '), max: 400)}',
      );
    }
    return LaunchResult(
      pid: proc.pid,
      device: device,
      target: target,
      logPath: logPath,
      wsUri: ready,
      tail: tail.join('\n'),
    );
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
  /// 只对自己 `launch()` 拉起的进程生效：向它的 stdin 写按键，再等输出里的
  /// 完成标记。flutter run 虽在非 TTY 下不会进 singleCharMode，但
  /// `TerminalHandler` 仍监听 stdin（`processTerminalInput` 会 trim），所以
  /// 管道写入可用。
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

    final sub = h.lines.listen((line) {
      captured.add(line);
      if (captured.length > 60) captured.removeAt(0);
      if (successRe.hasMatch(line)) {
        finish(true, line.trim());
      } else if (failRe.hasMatch(line)) {
        finish(false, line.trim());
      }
    });
    // 进程中途退出时不要干等到超时。
    unawaited(h.process.exitCode.then((code) {
      if (!done.isCompleted) finish(false, 'flutter run 已退出（code=$code）');
    }));

    try {
      h.process.stdin.writeln(restart ? 'R' : 'r');
      await h.process.stdin.flush();
    } catch (e) {
      await sub.cancel();
      throw DeviceCommandError(
          'flutter-run', 'hot reload', 'stdin 写入失败（进程可能已退出）：$e');
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
    await sub.cancel();
    return result;
  }

  /// 按精确 PID 结束 flutter run，并把它的子进程（被拉起的 app）一并结束。
  ///
  /// 先 SIGTERM，3 秒后 SIGKILL；子进程必须在杀父进程**之前**取快照，
  /// 否则 parent 退出后它们会被 init 收养，无从得知归属。
  Future<StopResult> stop(int pid) async {
    final children = Platform.isWindows
        ? await _descendantsOnWindows(pid)
        : _childrenOf(pid);
    final alive = Process.killPid(pid, ProcessSignal.sigterm);
    if (!alive) {
      _live.remove(pid)?.dispose();
      return StopResult(stopped: false);
    }
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!_isAlive(pid)) break;
    }
    if (_isAlive(pid)) Process.killPid(pid, ProcessSignal.sigkill);
    _live.remove(pid)?.dispose();
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
    return StopResult(stopped: true, children: killed);
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

  bool _isAlive(int pid) {
    if (Platform.isWindows) {
      // Windows 没有 kill -0：用 tasklist 精确查 pid。注意找不到时 tasklist
      // 的退出码仍可能是 0（只打印「信息: 没有运行的任务…」），必须看输出里
      // 有没有这个 pid。
      try {
        final r = Process.runSync(
          'tasklist',
          <String>['/FI', 'PID eq $pid', '/NH'],
        );
        return '${r.stdout}'.contains('$pid');
      } catch (_) {
        return false;
      }
    }
    final r = Process.runSync('kill', <String>['-0', '$pid']);
    return r.exitCode == 0;
  }
}
