// 调试中枢的运行配置接口（/api/debug/op 的 runProfile / saveConfig /
// deleteConfig / rememberLast / importLaunch）：
// - 弹窗提交的是「文本」，分词/拆行/拆 env 都在后端做，这里验证归一结果；
// - 落盘路径用测试注入，绝不碰真实 $XB_UME_HOME。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/debug/debug_hub.dart';
import '../bin/src/device/flutter_run.dart';
import '../bin/src/mcp/device_tools.dart';
import '../bin/src/mcp/scenario_service.dart';
import '../bin/src/mcp/session_registry.dart';
import '../bin/src/mcp/tools.dart';

/// listConfigs 分支不应拉起 flutter run：真被调到就直接报错。
class _NoLaunch extends FlutterRunLauncher {
  @override
  Future<LaunchResult> launch({
    required String device,
    String? target,
    String? cwd,
    String? platform,
    String? config,
    List<String> extraArgs = const <String>[],
    bool waitVm = true,
    bool force = false,
    String owner = 'mcp',
    Duration timeout = const Duration(seconds: 180),
  }) async =>
      throw StateError('listConfigs 不应该启动 app');
}

void main() {
  late Directory tmp;
  late Directory project;
  late String profilePath;
  late DebugHub hub;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xbume_hub_cfg_');
    project = Directory('${tmp.path}/app')..createSync();
    profilePath = '${tmp.path}/run_profiles.json';
    hub = DebugHub(push: (_) {}, profilePath: profilePath);
  });

  tearDown(() async {
    await hub.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Map<String, Object?> readAll() =>
      jsonDecode(File(profilePath).readAsStringSync()) as Map<String, Object?>;

  List<Map<String, Object?>> configsOf(Map<String, Object?> d) =>
      <Map<String, Object?>>[
        for (final c in (d['configs'] as List? ?? const <Object?>[]))
          (c as Map).cast<String, Object?>(),
      ];

  test('runProfile：没配置也正常返回，path 用注入的落盘路径', () async {
    final d = await hub.handle('runProfile', <String, Object?>{'dir': project.path});
    expect(d['ok'], isTrue);
    expect(d['path'], profilePath);
    expect(d['exists'], isFalse);
    expect(d['configs'], isEmpty);
    expect(d.containsKey('profile'), isFalse);
  });

  test('saveConfig：文本字段在后端分词/拆行/拆 env，写完能读回', () async {
    final d = await hub.handle('saveConfig', <String, Object?>{
      'dir': project.path,
      'config': <String, Object?>{
        'name': ' cn debug ',
        'target': ' lib/main_cn.dart ',
        'platforms': 'android ios',
        'args': '--flavor cn --dart-define=APP_ENV=cn',
        'preRun': 'bash scripts/prepare.sh\n\n  bash scripts/codegen.sh  ',
        'postStop': 'bash scripts/restore.sh',
        'env': 'APP_ENV=cn\n# 注释行\nEMPTY',
        'note': '  国内包  ',
      },
    });
    expect(d['ok'], isTrue, reason: '${d['error']}');
    final c = configsOf(d).single;
    expect(c['name'], 'cn debug');
    expect(c['target'], 'lib/main_cn.dart');
    expect(c['platforms'], <String>['android', 'ios']);
    expect(c['args'], <String>['--flavor', 'cn', '--dart-define=APP_ENV=cn']);
    expect(c['preRun'],
        <String>['bash scripts/prepare.sh', 'bash scripts/codegen.sh']);
    expect(c['postStop'], <String>['bash scripts/restore.sh']);
    expect(c['env'], <String, Object?>{'APP_ENV': 'cn', 'EMPTY': ''});
    expect(c['note'], '国内包');

    // 已落盘：另起一个 hub 读同一个文件也能读到（GUI 重开不丢）。
    final again = await DebugHub(push: (_) {}, profilePath: profilePath)
        .handle('runProfile', <String, Object?>{'dir': project.path});
    expect(configsOf(again).single['name'], 'cn debug');
  });

  test('saveConfig：同名覆盖不新增，没名字当场报错', () async {
    Future<Map<String, Object?>> save(String name, String args) => hub.handle(
          'saveConfig',
          <String, Object?>{
            'dir': project.path,
            'config': <String, Object?>{'name': name, 'args': args},
          },
        );
    await save('cn', '--flavor a');
    final d = await save('cn', '--flavor b');
    expect(d['ok'], isTrue);
    final list = configsOf(d);
    expect(list.length, 1);
    expect(list.single['args'], <String>['--flavor', 'b']);

    final bad = await save('   ', '--x');
    expect(bad['ok'], isFalse);
    expect('${bad['error']}'.contains('配置名不能为空'), isTrue);
  });

  test('deleteConfig：不存在返回 removed=false，删掉 last 指向的配置会清 last', () async {
    await hub.handle('saveConfig', <String, Object?>{
      'dir': project.path,
      'config': <String, Object?>{'name': 'cn'},
    });
    await hub.handle('rememberLast', <String, Object?>{
      'dir': project.path,
      'config': 'cn',
      'argsText': '--dart-define=K=V',
    });

    final missing = await hub.handle('deleteConfig', <String, Object?>{
      'dir': project.path,
      'name': 'nope',
    });
    expect(missing['ok'], isTrue);
    expect(missing['removed'], isFalse);
    expect(configsOf(missing).length, 1);

    final ok = await hub.handle('deleteConfig', <String, Object?>{
      'dir': project.path,
      'name': 'cn',
    });
    expect(ok['removed'], isTrue);
    expect(configsOf(ok), isEmpty);
    final raw = readAll();
    final node = (raw['projects'] as Map).values.single as Map;
    expect(node.containsKey('last'), isFalse);
  });

  test('rememberLast：只记选择时 profile 也能读回（GUI 回填用）', () async {
    final d = await hub.handle('rememberLast', <String, Object?>{
      'dir': project.path,
      'argsText': '--dart-define=A=1  --dart-define=B=2',
    });
    expect(d['ok'], isTrue, reason: '${d['error']}');
    expect(configsOf(d), isEmpty);
    final last = (d['last'] as Map).cast<String, Object?>();
    expect(last['args'], <String>['--dart-define=A=1', '--dart-define=B=2']);
    // 只有 last、没有任何配置：profile 字段仍在（否则前端没法回填）。
    final p = await hub.handle(
        'runProfile', <String, Object?>{'dir': project.path});
    expect(p.containsKey('profile'), isTrue);
    expect(p.containsKey('last'), isTrue);
  });

  test('importLaunch：默认只预览，apply=true 才落盘，重复导入报会覆盖谁', () async {
    Directory('${project.path}/.vscode').createSync();
    File('${project.path}/.vscode/launch.json').writeAsStringSync(
      '{\n'
      '  // 注释与尾逗号都常见，导入器要能吃\n'
      '  "version": "0.2.0",\n'
      '  "configurations": [\n'
      '    {\n'
      '      "name": "cn debug",\n'
      '      "program": "lib/main_cn.dart",\n'
      '      "toolArgs": ["--dart-define=APP_ENV=cn",],\n'
      '      "preLaunchTask": "prepare",\n'
      '      "env": {"APP_ENV": "cn"},\n'
      '    },\n'
      '    {"name": "release", "flutterMode": "release"},\n'
      '  ],\n'
      '}\n',
    );
    File('${project.path}/.vscode/tasks.json').writeAsStringSync(
      '{"version":"2.0.0","tasks":['
      '{"label":"prepare","type":"shell","command":"bash",'
      '"args":["scripts/prepare.sh","--fast"]}]}',
    );

    final preview = await hub.handle(
        'importLaunch', <String, Object?>{'dir': project.path});
    expect(preview['ok'], isTrue, reason: '${preview['error']}');
    expect(preview['apply'], isFalse);
    expect((preview['found'] as List).length, 2);
    expect(preview['overwrites'], isEmpty);
    expect(configsOf(preview), isEmpty, reason: '预览不写盘');
    expect(File(profilePath).existsSync(), isFalse);

    final applied = await hub.handle('importLaunch', <String, Object?>{
      'dir': project.path,
      'apply': true,
    });
    expect(applied['ok'], isTrue);
    final list = configsOf(applied);
    expect(list.map((c) => c['name']).toList(), <String>['cn debug', 'release']);
    final cn = list.first;
    expect(cn['target'], 'lib/main_cn.dart');
    expect(cn['preRun'], <String>['bash scripts/prepare.sh --fast']);
    expect(cn['args'], <String>['--dart-define=APP_ENV=cn']);
    expect(cn['env'], <String, Object?>{'APP_ENV': 'cn'});
    expect(list.last['args'], <String>['--release']);

    // 再导一次：同名都在，前端据此提示「会覆盖」。
    final again = await hub.handle('importLaunch', <String, Object?>{
      'dir': project.path,
      'apply': true,
    });
    expect((again['overwrites'] as List).length, 2);
  });

  test('importLaunch：没有 launch.json 时回可读错误', () async {
    final d = await hub.handle(
        'importLaunch', <String, Object?>{'dir': project.path});
    expect(d['ok'], isFalse);
    expect('${d['error']}'.contains('launch.json 不存在'), isTrue);
  });

  test('MCP xbume_app_launch：暴露 config / args / listConfigs，只列不启动', () async {
    final tool = deviceTools().firstWhere((t) => t.name == 'xbume_app_launch');
    final props =
        (tool.inputSchema['properties'] as Map).cast<String, Object?>();
    expect(props.keys, containsAll(<String>['config', 'args', 'listConfigs']));
    // 只查配置清单时不该再要求 deviceId（AI 先看有哪些可选）。
    expect(tool.inputSchema['required'], <String>['deviceId']);

    final sessions = SessionRegistry();
    final ctx = McpToolContext(
      sessions: sessions,
      scenarios: ScenarioService(sessions),
      launcher: _NoLaunch(),
      deviceBackend: 'adb',
    );
    final r = await tool.handler(ctx, <String, Object?>{
      'cwd': project.path,
      'listConfigs': true,
    });
    expect(r.isError, isFalse);
    final text = (r.content.single as Map)['text'] as String;
    expect(text, contains('运行配置（0 条）'));
    expect(text, contains('还没有配置'));
    final s = r.structured!;
    expect(s['cwd'], project.path);
    expect(s['configs'], isEmpty);
    expect(s.containsKey('last'), isFalse);
  });
}
