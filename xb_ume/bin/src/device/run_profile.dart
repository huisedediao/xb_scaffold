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

/// 一条具名运行配置：GUI 里新建/编辑/删除，MCP 与 AI 按名字选。
///
/// 字段都是 `flutter run` 的通用能力，与具体项目无关（flavor / dart-define /
/// --profile 都是 [args] 的一部分）。没有这一层时只能按平台写死一套参数。
class RunConfig {
  const RunConfig({
    required this.name,
    this.device,
    this.target,
    this.args = const <String>[],
    this.env = const <String, String>{},
    this.preRun = const <String>[],
    this.postStop = const <String>[],
    this.platforms = const <String>[],
    this.note,
  });

  /// 配置名（项目内唯一，GUI 下拉、MCP `config` 参数都用它）。
  final String name;

  /// 绑定的设备 id（可选；GUI 选中配置时回填设备）。
  final String? device;

  /// 入口文件（可选；缺省用 flutter 默认的 lib/main.dart）。
  final String? target;

  /// 追加给 `flutter run` 的参数（如 `--flavor oversea`、`--profile`）。
  final List<String> args;

  /// 注入子进程的环境变量。
  final Map<String, String> env;

  /// 启动前要跑的命令；空则回退项目顶层 `preRun`。
  final List<String> preRun;

  /// 停止后的清理命令；空则回退项目顶层 `postStop`。
  final List<String> postStop;

  /// 限定的平台（归一后的键）；空 = 所有平台。
  final List<String> platforms;

  /// 给人看的备注（GUI 摘要里显示）。
  final String? note;

  /// 配置是否对 [platform]（设备 id 或平台键都可）生效。
  bool appliesTo(String? platform) {
    if (platforms.isEmpty) return true;
    final key = platformKeyOf(platform);
    return key != null && platforms.contains(key);
  }

  static RunConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = _optText(raw['name']);
    if (name == null) return null;
    final env = <String, String>{};
    final rawEnv = raw['env'];
    if (rawEnv is Map) {
      for (final e in rawEnv.entries) {
        final k = '${e.key}'.trim();
        if (k.isEmpty) continue;
        env[k] = '${e.value}';
      }
    }
    return RunConfig(
      name: name,
      device: _optText(raw['device']),
      target: _optText(raw['target']),
      args: _stringList(raw['args']),
      env: env,
      preRun: _stringList(raw['preRun']),
      postStop: _stringList(raw['postStop']),
      platforms: <String>[
        for (final e in _stringList(raw['platforms']))
          if (platformKeyOf(e) case final String k) k,
      ],
      note: _optText(raw['note']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        if (device != null) 'device': device,
        if (target != null) 'target': target,
        if (args.isNotEmpty) 'args': args,
        if (env.isNotEmpty) 'env': env,
        if (preRun.isNotEmpty) 'preRun': preRun,
        if (postStop.isNotEmpty) 'postStop': postStop,
        if (platforms.isNotEmpty) 'platforms': platforms,
        if (note != null) 'note': note,
      };
}

/// 「上次用过的」配置与额外参数：GUI 重开、AI 调用都按它回填。
class LastRun {
  const LastRun({this.config, this.args = const <String>[]});

  final String? config;
  final List<String> args;

  static LastRun? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final config = _optText(raw['config']);
    final args = _stringList(raw['args']);
    if (config == null && args.isEmpty) return null;
    return LastRun(config: config, args: args);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        if (config != null) 'config': config,
        if (args.isNotEmpty) 'args': args,
      };
}

/// 把一行参数文本切成参数表：支持单/双引号包裹与反斜杠转义，
/// 空格 / 制表 / 换行分隔。GUI 的「额外参数」输入框与 preRun 共用这一套。
List<String> splitArgs(String text) {
  final out = <String>[];
  final buf = StringBuffer();
  String? quote;
  var has = false;
  void flush() {
    if (!has) return;
    out.add(buf.toString());
    buf.clear();
    has = false;
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
        continue;
      }
      if (c == r'\' && i + 1 < text.length) {
        final next = text[i + 1];
        // 引号内只认「转义引号」与 `\\`：否则 Windows 路径
        // （--path="C:\tmp"）里的反斜杠会被吃掉。单引号内按 shell 惯例不转义。
        final isEscape =
            quote == '"' && (next == '"' || next == r'\');
        if (isEscape) {
          buf.write(next);
          i++;
          continue;
        }
        buf.write(c);
        continue;
      }
      buf.write(c);
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      has = true;
      continue;
    }
    if (c == r'\' && i + 1 < text.length) {
      buf.write(text[++i]);
      has = true;
      continue;
    }
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      flush();
      continue;
    }
    buf.write(c);
    has = true;
  }
  flush();
  return out;
}

/// 合并「要追加给 flutter run 的参数」：
/// 顶层 `runArgs['*']` → 顶层 `runArgs[平台]` → 选中配置的 args → 本次额外参数。
List<String> mergeRunArgs({
  RunProfile? profile,
  RunConfig? config,
  String? platform,
  List<String> extraArgs = const <String>[],
}) {
  final out = <String>[ ...?profile?.runArgs['*'] ];
  final key = platformKeyOf(platform);
  if (profile != null && key != null) out.addAll(profile.runArgs[key] ?? const <String>[]);
  if (config != null) out.addAll(config.args);
  out.addAll(extraArgs);
  return out;
}

/// 本次启动该跑的 preRun 命令模板：配置里写了就用配置的，否则回退项目顶层。
List<String> preRunFor(RunProfile? profile, RunConfig? config) =>
    (config != null && config.preRun.isNotEmpty)
        ? config.preRun
        : (profile?.preRun ?? const <String>[]);

/// 本次停止该跑的 postStop 命令模板：配置里写了就用配置的，否则回退项目顶层。
List<String> postStopFor(RunProfile? profile, RunConfig? config) =>
    (config != null && config.postStop.isNotEmpty)
        ? config.postStop
        : (profile?.postStop ?? const <String>[]);

/// 本次入口文件：显式传的优先，其次配置里的；都没有则 null（用 flutter 默认）。
String? targetFor(String? explicit, RunConfig? config) =>
    (explicit != null && explicit.trim().isNotEmpty) ? explicit : config?.target;

/// 「给了配置名但项目里没有这条」时的报错文案（GUI/MCP 直接能照做）。
String missingRunConfigMessage({
  required String? configName,
  required String projectRoot,
  RunProfile? profile,
}) {
  final names = profile?.configs.map((c) => c.name).toList() ?? const <String>[];
  if (names.isEmpty) {
    return '项目 $projectRoot 还没有运行配置：在调试页新建一个，或不传 config 参数。';
  }
  return '没有名为「${(configName ?? '').trim()}」的运行配置。可用：${names.join('、')}';
}

/// 把「弹窗提交的原始字段」归一成 [RunConfig.fromJson] 能吃的结构：
/// args / platforms 接受一行文本（分词），preRun / postStop 接受多行文本，
/// env 接受 `KEY=VALUE` 每行一条。已经是数组 / 对象的原样保留。
Object? normalizeConfigRequest(Object? raw) {
  if (raw is! Map) return raw;
  final m = Map<String, Object?>.from(raw);
  final args = m['args'];
  if (args is String) m['args'] = splitArgs(args);
  final platforms = m['platforms'];
  if (platforms is String) m['platforms'] = splitArgs(platforms);
  for (final key in const <String>['preRun', 'postStop']) {
    final v = m[key];
    if (v is String) m[key] = splitLines(v);
  }
  final env = m['env'];
  if (env is String) m['env'] = parseEnvText(env);
  return m;
}

/// 按行切（preRun / postStop 文本框）：去首尾空白，跳过空行。
List<String> splitLines(String text) => <String>[
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];

/// `KEY=VALUE` 每行一条（env 文本框）；没写 `=` 的按空值处理，`#` 开头是注释。
Map<String, String> parseEnvText(String text) {
  final out = <String, String>{};
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final i = t.indexOf('=');
    if (i <= 0) {
      out[t] = '';
      continue;
    }
    out[t.substring(0, i).trim()] = t.substring(i + 1).trim();
  }
  return out;
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
    this.configs = const <RunConfig>[],
    this.last,
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

  /// 具名运行配置（GUI 新建/编辑/删除，MCP 按名字选）。
  final List<RunConfig> configs;

  /// 上次选中的配置与额外参数（服务端记住，GUI 与 AI 共用）。
  final LastRun? last;

  /// 按名字取配置（精确匹配，忽略名称两侧空白）。不存在返回 null。
  RunConfig? configNamed(String? name) {
    final want = (name ?? '').trim();
    if (want.isEmpty) return null;
    for (final c in configs) {
      if (c.name == want) return c;
    }
    return null;
  }

  /// 只算「有实质配置」：仅记住上次选择（last）不算，避免影响未配置项目的启动。
  bool get isEmpty =>
      preRun.isEmpty && postStop.isEmpty && runArgs.isEmpty && configs.isEmpty;

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
    final configs = <RunConfig>[];
    final rawConfigs = raw['configs'];
    if (rawConfigs is List) {
      final seen = <String>{};
      for (final e in rawConfigs) {
        final c = RunConfig.fromJson(e);
        // 重名只认第一条：手写文件时重复了不会让下拉出现两个同名项。
        if (c == null || !seen.add(c.name)) continue;
        configs.add(c);
      }
    }
    return RunProfile(
      platforms: platforms,
      preRun: preRun,
      postStop: postStop,
      runArgs: args,
      timeoutSec: timeout,
      continueOnError: raw['continueOnError'] == true,
      configs: configs,
      last: LastRun.fromJson(raw['last']),
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
        if (configs.isNotEmpty)
          'configs': <Object?>[for (final c in configs) c.toJson()],
        if (last != null) 'last': last!.toJson(),
      };
}

String? _optText(Object? raw) {
  if (raw == null) return null;
  final t = '$raw'.trim();
  return (t.isEmpty || t == 'null') ? null : t;
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
/// 「只记住了上次选择（last）、没有任何实质配置」也算未配置，保持启动链路原行为。
/// [filePath] 仅供测试注入，正常调用走 [runProfileFilePath]。
RunProfile? loadRunProfile(String projectRoot, {String? filePath}) {
  final p = loadProjectProfile(projectRoot, filePath: filePath);
  return (p == null || p.isEmpty) ? null : p;
}

/// 读项目配置（不筛「空配置」）：GUI 要拿 `configs` 与 `last` 回填，
/// 即使该项目只记住了上次选择也得能读到。
RunProfile? loadProjectProfile(String projectRoot, {String? filePath}) {
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
  return RunProfile.fromJson(projects[key]);
}

// --------------------------------------------------------------- 配置增删改

/// 新建或覆盖一条配置（同名即覆盖），返回落盘后的配置列表。
///
/// 写入时保留项目下其他字段（顶层 preRun / runArgs 等）与其它项目的配置：
/// 手写文件里的自定义键不会被吃掉。
List<RunConfig> saveRunConfig(
  String projectRoot,
  RunConfig config, {
  String? filePath,
}) {
  final name = config.name.trim();
  if (name.isEmpty) throw ArgumentError('配置名不能为空');
  if (projectRoot.trim().isEmpty) throw ArgumentError('缺少项目目录');
  late List<RunConfig> out;
  _mutateProject(projectRoot, filePath, (m) {
    final kept = <RunConfig>[];
    for (final raw in _rawConfigs(m)) {
      final c = RunConfig.fromJson(raw);
      if (c == null || c.name == name) continue;
      kept.add(c);
    }
    kept.add(RunConfig(
      name: name,
      device: config.device,
      target: config.target,
      args: config.args,
      env: config.env,
      preRun: config.preRun,
      postStop: config.postStop,
      platforms: config.platforms,
      note: config.note,
    ));
    m['configs'] = <Object?>[for (final c in kept) c.toJson()];
    // 同名覆盖时 last 里的配置名依旧有效，不用动；改名等于新建一条，
    // 旧名由 deleteRunConfig 负责清 last。
    out = kept;
  });
  return out;
}

/// 删除一条配置；不存在返回 false。若正是「上次选中的」，同时清掉 last。
bool deleteRunConfig(
  String projectRoot,
  String name, {
  String? filePath,
}) {
  final want = name.trim();
  if (want.isEmpty) return false;
  var removed = false;
  _mutateProject(projectRoot, filePath, (m) {
    final kept = <Object?>[];
    for (final raw in _rawConfigs(m)) {
      final c = RunConfig.fromJson(raw);
      if (c == null) continue;
      if (c.name == want) {
        removed = true;
        continue;
      }
      kept.add(c.toJson());
    }
    if (removed) m['configs'] = kept;
    final last = m['last'];
    if (removed && last is Map && '${last['config'] ?? ''}'.trim() == want) {
      m.remove('last');
    }
  });
  return removed;
}

/// 记住「上次选的配置 + 额外参数」；两者都空则清掉 last。
void rememberLastRun(
  String projectRoot, {
  String? config,
  List<String> args = const <String>[],
  String? filePath,
}) {
  if (projectRoot.trim().isEmpty) return;
  final name = (config ?? '').trim();
  _mutateProject(projectRoot, filePath, (m) {
    if (name.isEmpty && args.isEmpty) {
      m.remove('last');
      return;
    }
    m['last'] = LastRun(
      config: name.isEmpty ? null : name,
      args: args,
    ).toJson();
  });
}

List<Object?> _rawConfigs(Map<String, Object?> project) {
  final raw = project['configs'];
  return raw is List ? List<Object?>.of(raw) : const <Object?>[];
}

/// 读全量 → 改本项目节点 → 原子写回。
void _mutateProject(
  String projectRoot,
  String? filePath,
  void Function(Map<String, Object?> project) change,
) {
  final path = filePath ?? runProfileFilePath();
  final data = _readAllRaw(path);
  final projects = data['projects'] is Map
      ? Map<String, Object?>.from(data['projects'] as Map)
      : <String, Object?>{};
  final key = _findProjectKey(projects, projectRoot) ??
      normalizeProjectRoot(projectRoot);
  final node = projects[key] is Map
      ? Map<String, Object?>.from(projects[key] as Map)
      : <String, Object?>{};
  change(node);
  projects[key] = node;
  data['version'] = 2;
  data['projects'] = projects;
  _writeAll(path, data);
}

Map<String, Object?> _readAllRaw(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    return <String, Object?>{'version': 2, 'projects': <String, Object?>{}};
  }
  try {
    final raw = jsonDecode(f.readAsStringSync());
    if (raw is Map) return Map<String, Object?>.from(raw);
  } catch (_) {
    // 坏 JSON：先备份再重建，避免用户手写时的小错误导致内容被默默吃掉。
    try {
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      f.copySync('$path.broken-$stamp');
    } catch (_) {}
  }
  return <String, Object?>{'version': 2, 'projects': <String, Object?>{}};
}

void _writeAll(String path, Map<String, Object?> data) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  final tmp = File('$path.tmp');
  tmp.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(data)}\n',
  );
  tmp.renameSync(path);
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
