// flutter run 的「活进程清单」：跨进程复用 / 认领 / 热重载的依据。
//
// flutter run 的 Process 句柄只在拉起它的进程（MCP 或 GUI）里有效，进程本身
// 却活得比拉起者久。因此把「哪个 pid、在什么目录、用什么参数、VM 地址是多少」
// 落到 $XB_UME_HOME/launch/live/<pid>.json，任何一方启动前先读清单，就能：
//   - 同设备 + 同目录 + 同 target 已有存活进程时直接复用，不重装包；
//   - 拉起者重启后重新认领（校验 pid 存活 + 命令行是 flutter run），继续看日志、
//     停止、并通过同名 FIFO 写 stdin 触发热重载；
//   - GUI 与 MCP 看到同一份进程列表，谁先启动都一样。
//
// FIFO 说明：用 `sh -c 'exec 3<>"$1"; shift; exec "$@" <&3'` 把 flutter run 的
// stdin 换成命名管道（读写方式打开，不阻塞启动；exec 不换 pid，kill 依旧精确）。
// 之后任何进程 `printf 'r\n' > fifo` 都能触发热重载。Windows 没有 mkfifo，
// 该平台只会生成 null，调用方降级为「同进程 Process.stdin」。
library;

import 'dart:convert';
import 'dart:io';

import '../paths.dart';

/// 一条 flutter run 的落盘记录。
class LaunchRecord {
  LaunchRecord({
    required this.pid,
    required this.device,
    required this.cwd,
    required this.startedAt,
    this.target,
    this.platform,
    this.config,
    this.wsUri,
    this.logPath,
    this.fifo,
    this.owner = 'mcp',
    this.vmless = false,
  });

  final int pid;
  final String device;

  /// 启动时的工作目录（复用判定按符号链接归一后的路径比较）。
  final String cwd;
  final String? target;

  /// 目标平台（android / ios / ohos / macos…）；若启动方没传也没识别出来则为 null。
  /// 停止清理命令要用它展开 `{platform}`，因此与记录一起落盘。
  final String? platform;

  /// 启动时选中的具名运行配置（没选则为 null）。
  /// 停止时用它找到配置自己的 postStop；重启后认领也能保留选择。
  final String? config;
  final String? wsUri;
  final String? logPath;
  final String? fifo;
  final DateTime startedAt;

  /// 拉起方：mcp / gui。只用于展示与排查，不影响认领。
  final String owner;

  /// true 表示这条会话是 release 运行：**永远不会有 VM service 地址**。
  /// 与「还在等调试端口」区分开，否则下次启动会把一条可复用的会话误报成
  /// 「正在启动」而卡死（release 也不会因为 app 被杀就退出）。
  final bool vmless;

  Map<String, Object?> toJson() => <String, Object?>{
        'pid': pid,
        'device': device,
        'cwd': cwd,
        'target': target,
        'platform': platform,
        'config': config,
        'wsUri': wsUri,
        'logPath': logPath,
        'fifo': fifo,
        'startedAt': startedAt.toIso8601String(),
        'owner': owner,
        'vmless': vmless,
      };

  static LaunchRecord? fromJson(Map<String, Object?> json) {
    final pid = json['pid'];
    final device = json['device']?.toString() ?? '';
    final cwd = json['cwd']?.toString() ?? '';
    if (pid is! int || device.isEmpty || cwd.isEmpty) return null;
    final started = DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return LaunchRecord(
      pid: pid,
      device: device,
      cwd: cwd,
      startedAt: started,
      target: json['target']?.toString(),
      platform: json['platform']?.toString(),
      config: json['config']?.toString(),
      wsUri: json['wsUri']?.toString(),
      logPath: json['logPath']?.toString(),
      fifo: json['fifo']?.toString(),
      owner: json['owner']?.toString() ?? 'mcp',
      // 老记录没有这个字段：按「等调试端口」处理（与实际语义一致）。
      vmless: json['vmless'] == true,
    );
  }
}

/// 清单目录（launch/live）。[dir] 仅供单测覆盖。
String liveDirPath({String? dir}) => dir ?? '${xbUmeHome()}/launch/live';

File _recordFile(int pid, String dir) => File('$dir/$pid.json');

/// 写入 / 更新一条记录（同 pid 覆盖）。
void writeLaunchRecord(LaunchRecord record, {String? dir}) {
  try {
    final path = liveDirPath(dir: dir);
    Directory(path).createSync(recursive: true);
    final tmp = File('$path/${record.pid}.json.tmp');
    tmp.writeAsStringSync(jsonEncode(record.toJson()));
    tmp.renameSync(_recordFile(record.pid, path).path);
  } catch (_) {
    // 清单只影响复用，写失败不影响启动本身。
  }
}

/// 删除记录（进程退出 / 停止 / 陈旧清理）。
void removeLaunchRecord(int pid, {String? dir}) {
  try {
    final f = _recordFile(pid, liveDirPath(dir: dir));
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

/// 读出全部记录（坏文件跳过）。
List<LaunchRecord> readLaunchRecords({String? dir}) {
  final dir0 = Directory(liveDirPath(dir: dir));
  if (!dir0.existsSync()) return const <LaunchRecord>[];
  final out = <LaunchRecord>[];
  for (final e in dir0.listSync()) {
    if (e is! File || !e.path.endsWith('.json')) continue;
    try {
      final decoded = jsonDecode(e.readAsStringSync());
      if (decoded is! Map) continue;
      final r = LaunchRecord.fromJson(decoded.cast<String, Object?>());
      if (r != null) out.add(r);
    } catch (_) {
      // 半写入的文件忽略。
    }
  }
  out.sort((a, b) => a.startedAt.compareTo(b.startedAt));
  return out;
}

/// 进程是否存活。Windows 没有 kill -0，用 tasklist 精确查 pid。
bool pidAlive(int pid) {
  if (pid <= 1) return false;
  if (Platform.isWindows) {
    try {
      final r = Process.runSync('tasklist', <String>['/FI', 'PID eq $pid', '/NH']);
      return '${r.stdout}'.contains('$pid');
    } catch (_) {
      return false;
    }
  }
  try {
    return Process.runSync('kill', <String>['-0', '$pid']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 命令行是否是一条 `flutter run`（flutter_tools.snapshot 后第一个子命令是 run）。
///
/// 纯函数便于单测：也认 `dart .../flutter_tools.snapshot run` 与 Windows 的
/// `flutter.bat run`（后者不含 snapshot，故额外匹配 `flutter\run`）。
bool commandLooksLikeFlutterRun(String commandLine) {
  final snap = commandLine.indexOf('flutter_tools.snapshot');
  if (snap >= 0) {
    final rest =
        commandLine.substring(snap + 'flutter_tools.snapshot'.length).trim();
    if (rest.isEmpty) return false;
    return rest.split(RegExp(r'\s+')).first == 'run';
  }
  // Windows：flutter.bat 经 cmd 后命令行形如 `... flutter.bat run -d ...`。
  final bat = RegExp(r'flutter(?:\.bat)?\s+run(?:\s|$)').firstMatch(commandLine);
  return bat != null;
}

/// 取进程完整命令行（拿不到返回 null）。
String? processCommand(int pid) {
  if (Platform.isWindows) return null;
  try {
    final r = Process.runSync('ps', <String>['-p', '$pid', '-o', 'command=']);
    if (r.exitCode != 0) return null;
    final s = '${r.stdout}'.trim();
    return s.isEmpty ? null : s;
  } catch (_) {
    return null;
  }
}

/// 取进程工作目录（lsof 不可用返回 null）。
String? processCwd(int pid) {
  if (Platform.isWindows) return null;
  try {
    final r = Process.runSync('lsof', <String>['-a', '-p', '$pid', '-d', 'cwd', '-Fn']);
    if (r.exitCode != 0) return null;
    for (final line in '${r.stdout}'.split('\n')) {
      final t = line.trim();
      if (t.startsWith('n')) return t.substring(1);
    }
  } catch (_) {
    // ignored
  }
  return null;
}

/// 清单里的 pid 是否仍指向同一条 flutter run（认领校验）。
bool recordStillValid(LaunchRecord record) {
  if (!pidAlive(record.pid)) return false;
  final cmd = processCommand(record.pid);
  if (cmd != null) return commandLooksLikeFlutterRun(cmd);
  // 拿不到命令行（Windows）：只信 pid 存活。
  return Platform.isWindows;
}

/// 创建一条命名管道，返回路径；Windows 或 mkfifo 不可用时返回 null。
String? createLaunchFifo() {
  if (Platform.isWindows) return null;
  try {
    final dir = Directory('${xbUmeHome()}/launch')..createSync(recursive: true);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final path = '${dir.path}/fifo-$stamp-${DateTime.now().microsecond}';
    final r = Process.runSync('mkfifo', <String>['-m', '600', path]);
    if (r.exitCode != 0) return null;
    return path;
  } catch (_) {
    return null;
  }
}

/// 往 FIFO 写一段内容（`r\n` / `R\n`）。
///
/// 用 sh 的 `printf > fifo` 而不是 Dart 的文件写：Dart 打开时带 O_TRUNC，
/// 对 FIFO 语义不明确；shell 重定向是标准的「打开-写-关闭」。打开会阻塞到
/// 读者就绪，flutter run 一直在读，所以正常立即返回；仍加超时兜底。
Future<bool> writeLaunchFifo(
  String path,
  String data, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  if (Platform.isWindows) return false;
  try {
    if (!File(path).existsSync()) return false;
    final r = await Process.run(
      'sh',
      <String>['-c', r'printf %s "$1" > "$2"', 'sh', data, path],
    ).timeout(timeout);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 删掉 FIFO（进程退出后调用；失败无影响）。
void removeLaunchFifo(String? path) {
  if (path == null || path.isEmpty) return;
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

/// 启动前的粗粒度互斥：GUI 与 MCP 同时点「启动」时不各起一个。
///
/// 用 `launch/.lock`（独占创建）实现；超过 [stale] 的锁视为崩溃残留。
/// 拿不到锁时返回 false，调用方可以照常继续（最坏情况是两个 flutter run
/// 互相顶掉，可接受），也可以稍后重试。
bool acquireLaunchLock({Duration stale = const Duration(seconds: 10)}) {
  try {
    final dir = Directory('${xbUmeHome()}/launch')..createSync(recursive: true);
    final f = File('${dir.path}/.lock');
    try {
      f.createSync(exclusive: true);
      return true;
    } on FileSystemException {
      final age = DateTime.now().difference(f.lastModifiedSync());
      if (age > stale) {
        f.deleteSync();
        f.createSync(exclusive: true);
        return true;
      }
      return false;
    }
  } catch (_) {
    return false;
  }
}

void releaseLaunchLock() {
  try {
    final f = File('${xbUmeHome()}/launch/.lock');
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}
