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

  /// 启动 `flutter run -d <device>` 并等待 VM service 地址。
  ///
  /// [cwd] 默认当前工作目录（MCP server 由使用方指定工程目录启动）。
  /// [waitVm] 为 false 时只看进程是否起来，不等待调试端口（用于纯 UI 验证）。
  Future<LaunchResult> launch({
    required String device,
    String? target,
    String? cwd,
    bool waitVm = true,
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
        runInShell: false,
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
    final children = _childrenOf(pid);
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
    if (Platform.isWindows) return const <int>[];
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

  bool _isAlive(int pid) {
    final r = Process.runSync('kill', <String>['-0', '$pid']);
    return r.exitCode == 0;
  }
}
