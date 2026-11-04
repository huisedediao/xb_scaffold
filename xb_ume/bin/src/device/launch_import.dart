// 从 .vscode/launch.json（+ tasks.json）导入运行配置。
//
// 这是「可选的导入源」，不是运行时依赖：导入结果落成本工具自有的 RunConfig，
// 之后与在调试页新建的配置完全一样地跑。反向不成立——工具不读 launch.json。
library;

import 'dart:convert';

import 'run_profile.dart';

/// 导入结果：能转的配置 + 跳过的原因（给 GUI 提示，不静默丢）。
class LaunchImportResult {
  const LaunchImportResult({
    this.configs = const <RunConfig>[],
    this.warnings = const <String>[],
  });

  final List<RunConfig> configs;
  final List<String> warnings;
}

/// 解析 `.vscode/launch.json`（允许 `//` 与 `/* */` 注释、尾逗号——VS Code 自己能吃）。
///
/// [tasksText] 是同目录的 tasks.json：`preLaunchTask` 按 label 查到它的
/// command + args，转成配置的 preRun 命令（与 IDE 里点启动等价）。
LaunchImportResult importVsCodeLaunch({
  required String launchText,
  String? tasksText,
}) {
  final warnings = <String>[];
  Object? root;
  try {
    root = jsonDecode(stripJsonc(launchText));
  } catch (e) {
    return LaunchImportResult(
      warnings: <String>['launch.json 不是合法 JSON：$e'],
    );
  }
  final rawConfigs = root is Map ? root['configurations'] : null;
  if (rawConfigs is! List) {
    return const LaunchImportResult(
      warnings: <String>['launch.json 里没有 configurations 数组'],
    );
  }
  final tasks = _taskCommands(tasksText);
  final out = <RunConfig>[];
  final seen = <String>{};
  for (final raw in rawConfigs) {
    if (raw is! Map) continue;
    final name = '${raw['name'] ?? ''}'.trim();
    if (name.isEmpty) {
      warnings.add('跳过一条没有 name 的配置');
      continue;
    }
    if (!seen.add(name)) {
      warnings.add('配置名「$name」重复，只导入第一条');
      continue;
    }
    final args = _dedupe(<String>[
      // VS Code 的 Dart/Flutter 插件：toolArgs 是 flutter run 的参数，
      // args 是 app 自己的参数；手写配置常常只用 args，两者都收。
      for (final a in _strList(raw['toolArgs'])) _toLocalVars(a),
      for (final a in _strList(raw['args'])) _toLocalVars(a),
    ]);
    final mode = '${raw['flutterMode'] ?? ''}'.trim();
    if (mode == 'profile' && !args.contains('--profile')) args.add('--profile');
    if (mode == 'release' && !args.contains('--release')) args.add('--release');
    final program = _toLocalVars('${raw['program'] ?? ''}'.trim());
    final env = <String, String>{};
    final rawEnv = raw['env'];
    if (rawEnv is Map) {
      for (final e in rawEnv.entries) {
        final k = '${e.key}'.trim();
        if (k.isEmpty || e.value == null) continue;
        env[k] = _toLocalVars('${e.value}');
      }
    }
    // envFile 是 IDE 启动器的读文件能力：本工具不读它，提示写进 env。
    final envFile = '${raw['envFile'] ?? ''}'.trim();
    if (envFile.isNotEmpty) {
      warnings.add(
        '配置「$name」用了 envFile（$envFile）：导入不读这个文件，需要的变量请填进配置的 env',
      );
    }
    final preRun = <String>[];
    final taskLabel = '${raw['preLaunchTask'] ?? ''}'.trim();
    if (taskLabel.isNotEmpty) {
      final cmd = tasks[taskLabel];
      if (cmd == null) {
        warnings.add(
          '配置「$name」引用预启动任务「$taskLabel」，但 tasks.json 里找不到同名任务',
        );
      } else {
        preRun.add(cmd);
      }
    }
    out.add(RunConfig(
      name: name,
      target: program.isEmpty ? null : program,
      args: args,
      env: env,
      preRun: preRun,
      note: '从 .vscode/launch.json 导入',
    ));
  }
  if (out.isEmpty && warnings.isEmpty) {
    warnings.add('launch.json 里没有可导入的配置');
  }
  return LaunchImportResult(configs: out, warnings: warnings);
}

/// 去掉 JSONC 的注释与对象/数组末尾的多余逗号（字符串内的内容不动）。
String stripJsonc(String text) {
  final out = StringBuffer();
  String? quote;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < text.length) {
        out.write(text[i + 1]);
        i++;
        continue;
      }
      if (c == quote) quote = null;
      continue;
    }
    if (c == '"') {
      quote = c;
      out.write(c);
      continue;
    }
    if (c == '/' && i + 1 < text.length) {
      final n = text[i + 1];
      if (n == '/') {
        while (i < text.length && text[i] != '\n') {
          i++;
        }
        continue;
      }
      if (n == '*') {
        i += 2;
        while (i + 1 < text.length && !(text[i] == '*' && text[i + 1] == '/')) {
          i++;
        }
        i = i + 1 < text.length ? i + 1 : i;
        continue;
      }
    }
    out.write(c);
  }
  return _stripTrailingCommas(out.toString());
}

String _stripTrailingCommas(String text) {
  final out = StringBuffer();
  String? quote;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < text.length) {
        out.write(text[i + 1]);
        i++;
        continue;
      }
      if (c == quote) quote = null;
      continue;
    }
    if (c == '"') {
      quote = c;
      out.write(c);
      continue;
    }
    if (c == ',') {
      var j = i + 1;
      while (j < text.length && ' \t\r\n'.contains(text[j])) {
        j++;
      }
      if (j < text.length && (text[j] == '}' || text[j] == ']')) continue;
    }
    out.write(c);
  }
  return out.toString();
}

/// tasks.json 的 `label → 命令`（只认 shell 任务：command + args）。
Map<String, String> _taskCommands(String? text) {
  if (text == null || text.trim().isEmpty) return const <String, String>{};
  Object? raw;
  try {
    raw = jsonDecode(stripJsonc(text));
  } catch (_) {
    return const <String, String>{};
  }
  final tasks = raw is Map ? raw['tasks'] : raw;
  if (tasks is! List) return const <String, String>{};
  final out = <String, String>{};
  for (final t in tasks) {
    if (t is! Map) continue;
    final label = '${t['label'] ?? ''}'.trim();
    final command = _toLocalVars('${t['command'] ?? ''}'.trim());
    if (label.isEmpty || command.isEmpty) continue;
    final args = <String>[
      for (final a in _strList(t['args'])) _shellQuote(_toLocalVars(a)),
    ];
    out[label] = <String>[command, ...args].join(' ');
  }
  return out;
}

/// VS Code 的 `${workspaceFolder}` → 本工具的 `{projectRoot}`（preRun 支持展开）。
String _toLocalVars(String s) => s
    .replaceAll(r'${workspaceFolder}', '{projectRoot}')
    .replaceAll(r'${workspaceRoot}', '{projectRoot}')
    .replaceAll(r'${file}', '{target}');

String _shellQuote(String s) {
  if (s.isEmpty) return "''";
  if (!RegExp(r'''[\s"'$`\\]''').hasMatch(s)) return s;
  return "'${s.replaceAll("'", "'\\''")}'";
}

List<String> _strList(Object? raw) {
  if (raw is! List) return const <String>[];
  return <String>[
    for (final e in raw)
      if (e != null && '$e'.trim().isNotEmpty) '$e'.trim(),
  ];
}

List<String> _dedupe(List<String> items) {
  final seen = <String>{};
  return <String>[
    for (final i in items)
      if (seen.add(i)) i,
  ];
}
