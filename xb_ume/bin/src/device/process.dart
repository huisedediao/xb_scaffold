// 外部命令执行与可执行文件定位（设备层共用）。
//
// 设计约定：
//   - 只用 dart:io，不引入 shell 依赖；超时必须杀掉子进程，避免 MCP 工具
//     调用被 adb/hdc 无响应拖死；
//   - 失败不抛异常，统一回 [CmdResult]（code 非 0 / 超时 -1），
//     由各 Bridge 决定是「能力缺失」还是「命令报错」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bridge.dart';

/// 一次命令执行结果。
class CmdResult {
  CmdResult(this.code, this.stdout, this.stderr, {this.timedOut = false});

  final int code;
  final String stdout;
  final String stderr;
  final bool timedOut;

  bool get ok => code == 0 && !timedOut;

  /// 错误摘要（命令失败时用于拼提示）。
  String get errorText {
    if (timedOut) return '命令超时';
    final e = stderr.trim();
    if (e.isNotEmpty) return e;
    final o = stdout.trim();
    return o.isNotEmpty ? o : '退出码 $code';
  }

  @override
  String toString() => 'CmdResult(code=$code, out=${stdout.length}B)';
}

/// 执行命令；超时自动 kill，返回 code=-1。
Future<CmdResult> runCmd(
  String exe,
  List<String> args, {
  Duration timeout = const Duration(seconds: 20),
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  Process proc;
  try {
    proc = await Process.start(
      exe,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: false,
    );
  } on ProcessException catch (e) {
    return CmdResult(127, '', '${e.message}${e.errorCode == 0 ? '' : '(${e.errorCode})'}');
  }
  final out = StringBuffer();
  final err = StringBuffer();
  final done = Completer<void>();
  final subOut = proc.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((String line) => out.writeln(line));
  final subErr = proc.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((String line) => err.writeln(line));
  unawaited(proc.exitCode.then((_) {
    if (!done.isCompleted) done.complete();
  }));
  var timedOut = false;
  try {
    await done.future.timeout(timeout);
  } on TimeoutException {
    timedOut = true;
    proc.kill(ProcessSignal.sigkill);
  } finally {
    await subOut.cancel();
    await subErr.cancel();
  }
  final code = timedOut ? -1 : await proc.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
  return CmdResult(code, out.toString(), err.toString(), timedOut: timedOut);
}

/// 在 PATH 中定位可执行文件；找不到返回 null（不调用 which，跨平台一致）。
String? findExecutable(String name) {
  if (name.contains('/') || name.contains(r'\')) {
    return File(name).existsSync() ? name : null;
  }
  final path = Platform.environment['PATH'] ?? '';
  final sep = Platform.isWindows ? ';' : ':';
  final exts = Platform.isWindows
      ? <String>['.exe', '.bat', '.cmd', '']
      : <String>[''];
  for (final dir in path.split(sep)) {
    if (dir.trim().isEmpty) continue;
    for (final ext in exts) {
      final f = File('$dir${Platform.pathSeparator}$name$ext');
      if (f.existsSync()) return f.path;
    }
  }
  return null;
}

/// 把命令行结果压成一行（日志/错误提示用）。
String oneLine(String s, {int max = 200}) {
  final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length <= max ? t : '${t.substring(0, max)}…';
}

/// 命令必须成功，否则抛 [DeviceCommandError]（由各 Bridge 调用）。
void requireOk(CmdResult r, String backend, String command) {
  if (r.ok) return;
  throw DeviceCommandError(backend, command, oneLine(r.errorText));
}
