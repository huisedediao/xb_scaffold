// 项目级「运行配置」：本工具拉起 flutter run 前要做的准备、要追加的参数、
// 以及停止后的清理。
//
// 为什么需要：有的项目在 flutter run 之前必须先做本地准备（按目标平台 /
// 包名 / buildNumber 生成构建期密文、Android flavor、iOS 临时签名等），IDE
// 靠 launch.json 的 preLaunchTask 完成；本工具直接起 flutter run，需要一份
// 等价的、按项目生效的配置。
//
// 文件：$XB_UME_HOME/debug/run_profiles.json（与断点落盘同一套「项目根 → 配置」）：
//   {"version":1,"projects":{"<项目根绝对路径>":{
//      "platforms":["android","ios","ohos"],
//      "preRun":["bash scripts/dev_run.sh --prepare --platform {platform}"],
//      "postStop":["bash scripts/dev_run.sh --restore"],
//      "runArgs":{"android":["--flavor","oversea"]},
//      "timeoutSec":180,"continueOnError":false}}}
//
// 约束：
//   - 没有配置 / 配置损坏时完全不介入，正常 flutter run 行为不变；
//   - 只在新建会话时执行 preRun，复用已有会话不重复执行；
//   - 命令在项目根目录执行；失败默认中止启动（continueOnError 可放宽）；
//   - platforms 非空时只在这些平台上生效（如只在手机上做包名相关准备，
//     桌面端跑同一项目保持原样）。
library;

import 'dart:convert';
import 'dart:io';

import '../paths.dart';
import 'process.dart';

/// 一条配置命令的执行结果。
class RunCommandResult {
  RunCommandResult({
    required this.command,
    required this.code,
    required this.output,
    this.timedOut = false,
  });

  final String command;
  final int code;

  /// stdout + stderr（已去掉首尾空白）。
  final String output;
  final bool timedOut;

  bool get ok => code == 0 && !timedOut;

  /// 失败时给人看的摘要（命令 + 输出尾部）。
  String get errorText {
    final t = output.trim();
    final tail = t.length <= 400 ? t : t.substring(t.length - 400);
    final why = timedOut ? '超时' : '退出码 $code';
    return '命令失败（$why）：$command${tail.isEmpty ? '' : '\n$tail'}';
  }
}

/// 项目级运行配置。
class RunProfile {
  const RunProfile({
    this.platforms = const <String>[],
    this.preRun = const <String>[],
    this.postStop = const <String>[],
    this.runArgs = const <String, List<String>>{},
    this.timeoutSec = 180,
    this.continueOnError = false,
  });

  /// 生效平台（归一后的键）；空 = 所有平台。
  final List<String> platforms;

  /// 启动前按顺序执行的命令（shell 语义，工作目录 = 项目根）。
  final List<String> preRun;

  /// 停止（按精确 PID 杀完进程）后执行的清理命令。
  final List<String> postStop;

  /// 追加给 `flutter run` 的参数，按平台分（`*` 为兜底）。
  final Map<String, List<String>> runArgs;

  /// 单条命令超时。
  final int timeoutSec;

  /// preRun 失败是否仍继续启动（默认 false：中止，避免起一个必然不可用的 app）。
  final bool continueOnError;

  bool get isEmpty => preRun.isEmpty && postStop.isEmpty && runArgs.isEmpty;

  /// 这套配置是否对 [platform]（已归一）生效。
  ///
  /// 限定了平台但识别不出当前平台时按不生效处理：宁可少做，
  /// 也不要在一台不相关的设备上执行别的平台的准备脚本。
  bool appliesTo(String? platform) {
    if (platforms.isEmpty) return true;
    final key = platformKeyOf(platform);
    return key != null && platforms.contains(key);
  }

  /// 结构不对返回 null：坏配置按「未配置」处理，不影响正常启动。
  static RunProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final platforms = <String>[
      for (final e in _stringList(raw['platforms']))
        if (platformKeyOf(e) case final String k) k,
    ];
    final preRun = _stringList(raw['preRun']);
    final postStop = _stringList(raw['postStop']);
    final args = <String, List<String>>{};
    final rawArgs = raw['runArgs'];
    if (rawArgs is Map) {
      for (final e in rawArgs.entries) {
        final key = '${e.key}'.trim();
        if (key.isEmpty) continue;
        final normalized = key == '*' ? '*' : platformKeyOf(key);
        // 不认识的平台键丢掉：写错了不会静默影响其他平台。
        if (normalized == null) continue;
        final list = _stringList(e.value);
        if (list.isEmpty) continue;
        args[normalized] = list;
      }
    }
    var timeout = 180;
    final t = raw['timeoutSec'];
    if (t is num) timeout = t.toInt().clamp(5, 900);
    return RunProfile(
      platforms: platforms,
      preRun: preRun,
      postStop: postStop,
      runArgs: args,
      timeoutSec: timeout,
      continueOnError: raw['continueOnError'] == true,
    );
  }

  /// 某平台要追加的参数：`*` 在前，平台专属在后。
  List<String> argsFor(String? platform) {
    final out = <String>[...?runArgs['*']];
    final key = platformKeyOf(platform);
    if (key != null) out.addAll(runArgs[key] ?? const <String>[]);
    return out;
  }

  /// 配置是否依赖平台：只有依赖时才去问 `flutter devices`，避免拖慢启动。
  bool needsPlatform() =>
      platforms.isNotEmpty ||
      runArgs.keys.any((k) => k != '*') ||
      preRun.any((c) => c.contains('{platform}')) ||
      postStop.any((c) => c.contains('{platform}'));

  Map<String, Object?> toJson() => <String, Object?>{
        'platforms': platforms,
        'preRun': preRun,
        'postStop': postStop,
        'runArgs': runArgs,
        'timeoutSec': timeoutSec,
        'continueOnError': continueOnError,
      };
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return const <String>[];
  return <String>[
    for (final e in raw)
      if ('$e'.trim().isNotEmpty) '$e'.trim(),
  ];
}

/// 运行配置文件路径（与断点落盘同目录）。
String runProfileFilePath() => '${xbUmeHome()}/debug/run_profiles.json';

/// 读某个项目的运行配置；未配置 / 文件损坏 / 项目不匹配都返回 null。
///
/// [filePath] 仅供测试注入，正常调用走 [runProfileFilePath]。
RunProfile? loadRunProfile(String projectRoot, {String? filePath}) {
  if (projectRoot.trim().isEmpty) return null;
  final f = File(filePath ?? runProfileFilePath());
  if (!f.existsSync()) return null;
  Object? raw;
  try {
    raw = jsonDecode(f.readAsStringSync());
  } catch (_) {
    return null; // 坏 JSON 当未配置，不阻塞启动。
  }
  if (raw is! Map) return null;
  final projects = raw['projects'];
  if (projects is! Map) return null;
  final key = _findProjectKey(projects, projectRoot);
  if (key == null) return null;
  final p = RunProfile.fromJson(projects[key]);
  return (p == null || p.isEmpty) ? null : p;
}

String? _findProjectKey(Map projects, String root) {
  final want = normalizeProjectRoot(root);
  if (want.isEmpty) return null;
  for (final k in projects.keys) {
    final key = '$k';
    if (normalizeProjectRoot(key) == want) return key;
  }
  return null;
}

/// 项目根归一：能解析符号链接就解析（macOS `/var` → `/private/var`），
/// 再去掉尾部斜杠；路径不存在时退回绝对路径。
String normalizeProjectRoot(String root) {
  var p = root.trim();
  if (p.isEmpty) return '';
  try {
    p = Directory(p).resolveSymbolicLinksSync();
  } catch (_) {
    p = Directory(p).absolute.path;
  }
  while (p.length > 1 && (p.endsWith('/') || p.endsWith(r'\'))) {
    if (p.endsWith(':/') || p.endsWith(r':\')) break;
    p = p.substring(0, p.length - 1);
  }
  return p;
}

/// 把设备 / targetPlatform 的各种写法归一成配置键。
///
/// `android-arm64` → android、`ios-real` → ios、`darwin` → macos、
/// `harmony` → ohos；认不出返回 null（只命中 `*`）。
String? platformKeyOf(String? raw) {
  final s = (raw ?? '').trim().toLowerCase();
  if (s.isEmpty) return null;
  if (s.startsWith('android')) return 'android';
  if (s.startsWith('ios')) return 'ios';
  if (s.startsWith('ohos') || s.startsWith('harmony')) return 'ohos';
  if (s.startsWith('darwin') || s == 'macos') return 'macos';
  if (s.startsWith('windows')) return 'windows';
  if (s.startsWith('linux')) return 'linux';
  return null;
}

/// 展开命令里的占位符。
///
/// 支持 `{projectRoot}` `{device}` `{target}` `{platform}`；
/// 不认识的 `{xxx}` 原样保留，避免误伤 shell 语法。
String expandRunVars(
  String command, {
  required String projectRoot,
  required String device,
  String? target,
  String? platform,
}) {
  final vars = <String, String>{
    'projectRoot': projectRoot,
    'device': device,
    'target': target ?? '',
    'platform': platform ?? '',
  };
  return command.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
    final v = vars[m.group(1)];
    return v ?? m.group(0)!;
  });
}

/// 逐条执行命令（shell 语义），返回每条的结果。
///
/// [onLine] 收到带 `[tag]` 前缀的输出行（命令本身也会先打一行），
/// 调用方决定写到日志还是 GUI；单条命令超时按 [timeout] 计。
Future<List<RunCommandResult>> runProfileCommands(
  List<String> commands, {
  required String cwd,
  Duration timeout = const Duration(seconds: 180),
  String tag = 'pre-run',
  void Function(String line)? onLine,
}) async {
  final results = <RunCommandResult>[];
  final shell = Platform.isWindows ? 'cmd' : 'sh';
  final flag = Platform.isWindows ? '/c' : '-c';
  for (final raw in commands) {
    final cmd = raw.trim();
    if (cmd.isEmpty) continue;
    onLine?.call('[$tag] \$ $cmd');
    final r = await runCmd(
      shell,
      <String>[flag, cmd],
      timeout: timeout,
      workingDirectory: cwd,
    );
    final text = '${r.stdout}${r.stderr}'.trim();
    for (final line in text.split('\n')) {
      final t = line.trimRight();
      if (t.isEmpty) continue;
      onLine?.call('[$tag] ${t.length > 500 ? '${t.substring(0, 500)}…' : t}');
    }
    if (!r.ok) {
      onLine?.call('[$tag] 失败：${r.timedOut ? '超时' : '退出码 ${r.code}'}');
    }
    results.add(RunCommandResult(
      command: cmd,
      code: r.code,
      output: text,
      timedOut: r.timedOut,
    ));
    if (!results.last.ok) break; // 失败即停：后续命令多半也依赖上一步。
  }
  return results;
}
