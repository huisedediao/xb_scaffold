// .vscode/launch.json + tasks.json → 本工具的 RunConfig。
//
// 导入是「可选入口」：解析出的配置之后与手工新建的完全一样，运行时不读
// launch.json。所以这里只验证「能读懂 VS Code 的写法 + 不静默丢东西」。
library;

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/launch_import.dart';

void main() {
  group('stripJsonc', () {
    test('去掉行注释、块注释与尾逗号（字符串里的不动）', () {
      const src = '''
{
  // 行注释
  "a": "keep // not a comment",
  /* 块
     注释 */
  "list": [1, 2, 3,],
  "obj": {"x": 1,},
}
''';
      final out = stripJsonc(src);
      expect(out.contains('行注释'), isFalse);
      expect(out.contains('块'), isFalse);
      expect(out.contains('keep // not a comment'), isTrue);
      expect(out.contains('3,],'), isFalse);
      expect(out.contains('1,}'), isFalse);
    });

    test('字符串里的转义引号不会让状态提前结束', () {
      final out = stripJsonc(r'{"a": "x\"y", "b": 1,}');
      expect(out.contains(r'x\"y'), isTrue);
      expect(out.trim().endsWith('}'), isTrue);
    });
  });

  group('importVsCodeLaunch', () {
    test('flutter 配置：args / program / flutterMode / note 都转过来', () {
      const launch = '''
{
  // VS Code 配置
  "version": "0.2.0",
  "configurations": [
    {
      "name": "oversea debug",
      "request": "launch",
      "type": "dart",
      "program": "lib/main.dart",
      "args": ["--flavor", "oversea"],
    },
    {
      "name": "release",
      "type": "dart",
      "flutterMode": "release",
      "args": ["--flavor", "cn"],
    },
  ],
}
''';
      final r = importVsCodeLaunch(launchText: launch);
      expect(r.configs, hasLength(2));
      final a = r.configs.first;
      expect(a.name, 'oversea debug');
      expect(a.target, 'lib/main.dart');
      expect(a.args, <String>['--flavor', 'oversea']);
      expect(a.note, contains('launch.json'));
      // flutterMode=release 没有显式 --release 时补上
      expect(r.configs[1].args, <String>['--flavor', 'cn', '--release']);
      expect(r.warnings, isEmpty);
    });

    test('toolArgs 与 args 都收，完全重复的去掉', () {
      const launch = '''
{"configurations": [
  {"name": "x", "toolArgs": ["-d", "macos"], "args": ["-d", "macos", "--x"]}
]}
''';
      final r = importVsCodeLaunch(launchText: launch);
      expect(r.configs.single.args, <String>['-d', 'macos', '--x']);
    });

    test('preLaunchTask 按 tasks.json 的 label 变成 preRun 命令', () {
      const launch = '''
{"configurations": [
  {"name": "cn debug", "preLaunchTask": "aksk-prepare: android cn"}
]}
''';
      const tasks = '''
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "aksk-prepare: android cn",
      "type": "shell",
      "command": "bash",
      "args": ["scripts/dev_run.sh", "--prepare", "{platform}"],
    },
  ],
}
''';
      final r = importVsCodeLaunch(launchText: launch, tasksText: tasks);
      final c = r.configs.single;
      expect(c.preRun, hasLength(1));
      expect(c.preRun.single, 'bash scripts/dev_run.sh --prepare {platform}');
      expect(r.warnings, isEmpty);
    });

    test('任务找不到 / 缺 name / 坏 JSON：给提示，不抛异常', () {
      const launch = '''
{"configurations": [
  {"name": "a", "preLaunchTask": "missing-task"},
  {"args": ["--x"]},
]}
''';
      final r = importVsCodeLaunch(launchText: launch);
      expect(r.configs, hasLength(1));
      expect(r.configs.single.preRun, isEmpty);
      expect(r.warnings.join('\n'), contains('missing-task'));
      expect(r.warnings.join('\n'), contains('没有 name'));

      final bad = importVsCodeLaunch(launchText: '{"configurations": [');
      expect(bad.configs, isEmpty);
      expect(bad.warnings.single, contains('不是合法 JSON'));

      final none = importVsCodeLaunch(launchText: '{"version": "0.2.0"}');
      expect(none.configs, isEmpty);
      expect(none.warnings.single, contains('configurations'));
    });

    test('env 跟着配置走，envFile 给提示（不静默丢变量）', () {
      const launch = '''
{"configurations": [
  {"name": "x", "env": {"APP_ENV": "cn", "ROOT": "\${workspaceFolder}"}},
  {"name": "y", "envFile": "\${workspaceFolder}/.env"}
]}
''';
      final r = importVsCodeLaunch(launchText: launch);
      expect(r.configs.first.env,
          <String, String>{'APP_ENV': 'cn', 'ROOT': '{projectRoot}'});
      expect(r.configs[1].env, isEmpty);
      expect(r.warnings.single, contains('envFile'));
    });

    test(r'${workspaceFolder} 转成本工具的 {projectRoot}', () {
      const launch = r'''
{"configurations": [
  {"name": "x", "program": "${workspaceFolder}/lib/main.dart",
   "args": ["--dart-define=ROOT=${workspaceFolder}"]}
]}
''';
      final c = importVsCodeLaunch(launchText: launch).configs.single;
      expect(c.target, '{projectRoot}/lib/main.dart');
      expect(c.args.single, '--dart-define=ROOT={projectRoot}');
    });
  });
}
