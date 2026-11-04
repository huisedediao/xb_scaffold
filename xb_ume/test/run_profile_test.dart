// 项目级运行配置（$XB_UME_HOME/debug/run_profiles.json）：
// - 没配置 / 配错 / 只对别的平台生效时，flutter run 的行为必须和以前一模一样；
// - 变量展开、平台归一、按平台取参数都是纯函数，可在不碰设备的情况下验证。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/run_profile.dart';

void main() {
  group('platformKeyOf', () {
    test('把设备/平台的各种写法归一到配置键', () {
      const cases = <String, String>{
        'android': 'android',
        'android-arm64': 'android',
        'ios': 'ios',
        'ios-real': 'ios',
        'ios-sim': 'ios',
        'ohos': 'ohos',
        'harmony': 'ohos',
        'darwin': 'macos',
        'macos': 'macos',
        'windows': 'windows',
        'linux': 'linux',
        ' Android ': 'android',
      };
      cases.forEach((raw, want) {
        expect(platformKeyOf(raw), want, reason: raw);
      });
    });

    test('认不出来时返回 null（只命中 *）', () {
      expect(platformKeyOf(null), isNull);
      expect(platformKeyOf(''), isNull);
      expect(platformKeyOf('web'), isNull);
      expect(platformKeyOf('chrome'), isNull);
    });
  });

  group('expandRunVars', () {
    test('展开四个占位符', () {
      final s = expandRunVars(
        'run --device {device} --target {target} --platform {platform} '
        '--root {projectRoot}',
        projectRoot: '/p',
        device: '2LQ0224125000898',
        target: 'lib/main.dart',
        platform: 'ohos',
      );
      expect(s, 'run --device 2LQ0224125000898 --target lib/main.dart '
          '--platform ohos --root /p');
    });

    test('缺省值与不认识的占位符都原样保留，不误伤 shell 语法', () {
      expect(
        expandRunVars('echo {target} {platform} {unknown}',
            projectRoot: '/p', device: 'd'),
        'echo   {unknown}',
      );
      expect(
        expandRunVars(r'echo ${HOME} {device}', projectRoot: '/p', device: 'd'),
        r'echo ${HOME} d',
      );
    });
  });

  group('RunProfile.fromJson', () {
    test('正常配置：平台键归一，timeout 收敛到 5..900，坏平台键丢弃', () {
      final p = RunProfile.fromJson(<String, Object?>{
        'platforms': <String>['android', 'ios-real', 'web'],
        'preRun': <String>['bash scripts/dev_run.sh --prepare', '  '],
        'postStop': <String>['bash scripts/dev_run.sh --restore'],
        'runArgs': <String, Object?>{
          '*': <String>['--dart-define=A=1'],
          'android': <String>['--flavor', 'oversea'],
          'ios-sim': <String>['--simulator'],
          'web': <String>['--web-renderer'],
          'ohos': <String>[],
        },
        'timeoutSec': 9999,
        'continueOnError': true,
      })!;
      expect(p.platforms, <String>['android', 'ios']);
      expect(p.preRun, <String>['bash scripts/dev_run.sh --prepare']);
      expect(p.postStop, hasLength(1));
      expect(p.runArgs.keys, <String>['*', 'android', 'ios']);
      expect(p.timeoutSec, 900);
      expect(p.continueOnError, isTrue);
    });

    test('类型不对不抛异常：按空配置处理', () {
      final p = RunProfile.fromJson(<String, Object?>{
        'platforms': 'android',
        'preRun': 'bash x',
        'runArgs': <String, Object?>{'android': 'not-a-list'},
        'timeoutSec': 'soon',
        'continueOnError': 'yes',
      })!;
      expect(p.platforms, isEmpty);
      expect(p.preRun, isEmpty);
      expect(p.runArgs, isEmpty);
      expect(p.timeoutSec, 180);
      expect(p.continueOnError, isFalse);
      expect(p.isEmpty, isTrue);
    });

    test('不是对象直接返回 null', () {
      expect(RunProfile.fromJson(null), isNull);
      expect(RunProfile.fromJson('x'), isNull);
      expect(RunProfile.fromJson(<String>['x']), isNull);
    });
  });

  group('appliesTo（只对指定平台生效）', () {
    test('不限定平台：任何平台都生效', () {
      const p = RunProfile(preRun: <String>['x']);
      expect(p.appliesTo('android'), isTrue);
      expect(p.appliesTo('macos'), isTrue);
      expect(p.appliesTo(null), isTrue);
    });

    test('限定了平台：只在这些平台上生效，识别不出平台按不生效', () {
      const p = RunProfile(
        platforms: <String>['android', 'ios', 'ohos'],
        preRun: <String>['x'],
      );
      expect(p.appliesTo('android-arm64'), isTrue);
      expect(p.appliesTo('ios-real'), isTrue);
      expect(p.appliesTo('ohos'), isTrue);
      expect(p.appliesTo('macos'), isFalse);
      expect(p.appliesTo('windows'), isFalse);
      expect(p.appliesTo(null), isFalse);
    });

    test('限定了平台就要求识别平台（needsPlatform）', () {
      const p = RunProfile(platforms: <String>['ohos']);
      expect(p.needsPlatform(), isTrue);
      const q = RunProfile(runArgs: <String, List<String>>{
        '*': <String>['--x'],
      });
      expect(q.needsPlatform(), isFalse);
    });
  });

  group('argsFor', () {
    test('* 在前，平台专属在后', () {
      const p = RunProfile(runArgs: <String, List<String>>{
        'android': <String>['--flavor', 'cn'],
        '*': <String>['--dart-define=A=1'],
      });
      expect(p.argsFor('android'),
          <String>['--dart-define=A=1', '--flavor', 'cn']);
      expect(p.argsFor('macos'), <String>['--dart-define=A=1']);
    });
  });

  group('loadRunProfile', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('xbume_run_profile_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    File writeConfig(Object? body) {
      final f = File('${tmp.path}/run_profiles.json');
      f.writeAsStringSync(body is String ? body : jsonEncode(body));
      return f;
    }

    test('按项目根命中；尾部斜杠 / 符号链接视为同一项目', () {
      final project = Directory('${tmp.path}/app')..createSync();
      final link = Link('${tmp.path}/app-link')..createSync(project.path);
      final f = writeConfig(<String, Object?>{
        'version': 1,
        'projects': <String, Object?>{
          '${project.path}/': <String, Object?>{
            'preRun': <String>['bash scripts/dev_run.sh --prepare'],
          },
        },
      });
      final p = loadRunProfile(link.path, filePath: f.path);
      expect(p, isNotNull);
      expect(p!.preRun, hasLength(1));
      expect(loadRunProfile(project.path, filePath: f.path), isNotNull);
    });

    test('项目没配置 / 空配置 都返回 null（等于不介入）', () {
      final f = writeConfig(<String, Object?>{
        'version': 1,
        'projects': <String, Object?>{
          '/other/app': <String, Object?>{'preRun': <String>['x']},
          '/empty/app': <String, Object?>{},
        },
      });
      expect(loadRunProfile('/no/such/app', filePath: f.path), isNull);
      expect(loadRunProfile('/empty/app', filePath: f.path), isNull);
      expect(loadRunProfile('', filePath: f.path), isNull);
    });

    test('坏 JSON / 结构不对 / 文件不存在：返回 null 而不是抛异常', () {
      final bad = writeConfig('{"version":1,"projects":{');
      expect(loadRunProfile('/app', filePath: bad.path), isNull);
      expect(loadRunProfile('/app', filePath: '${tmp.path}/nope.json'), isNull);
      final list = writeConfig(<Object?>[1, 2, 3]);
      expect(loadRunProfile('/app', filePath: list.path), isNull);
      final noProjects = writeConfig(<String, Object?>{'version': 1});
      expect(loadRunProfile('/app', filePath: noProjects.path), isNull);
    });
  });

  group('runProfileCommands', () {
    test('按顺序执行并把输出交给回调', () async {
      final dir = Directory.systemTemp.createTempSync('xbume_run_cmd_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final lines = <String>[];
      final results = await runProfileCommands(
        <String>['echo one', 'echo two'],
        cwd: dir.path,
        timeout: const Duration(seconds: 10),
        onLine: lines.add,
      );
      expect(results.map((r) => r.ok), <bool>[true, true]);
      expect(results.map((r) => r.output), <String>['one', 'two']);
      expect(lines, contains('[pre-run] \$ echo one'));
      expect(lines, contains('[pre-run] one'));
      expect(lines, contains('[pre-run] two'));
    });

    test('失败即停：后面的命令不再执行', () async {
      final dir = Directory.systemTemp.createTempSync('xbume_run_cmd_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final results = await runProfileCommands(
        <String>['exit 3', 'touch should_not_exist'],
        cwd: dir.path,
        timeout: const Duration(seconds: 10),
      );
      expect(results, hasLength(1));
      expect(results.first.ok, isFalse);
      expect(results.first.code, 3);
      expect(File('${dir.path}/should_not_exist').existsSync(), isFalse);
    });

    test('空行 / 空白命令被跳过', () async {
      final dir = Directory.systemTemp.createTempSync('xbume_run_cmd_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final results = await runProfileCommands(
        <String>['', '   '],
        cwd: dir.path,
        timeout: const Duration(seconds: 10),
      );
      expect(results, isEmpty);
    });

    test('超时标记为失败并带上 timedOut', () async {
      final dir = Directory.systemTemp.createTempSync('xbume_run_cmd_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final results = await runProfileCommands(
        <String>['sleep 5'],
        cwd: dir.path,
        timeout: const Duration(seconds: 1),
      );
      expect(results, hasLength(1));
      expect(results.first.ok, isFalse);
      expect(results.first.timedOut, isTrue);
      expect(results.first.errorText, contains('超时'));
    });
  });

  group('runProfileFilePath', () {
    test('落在 XB_UME_HOME/debug 下（与断点落盘同目录）', () {
      expect(runProfileFilePath(), endsWith('/debug/run_profiles.json'));
    });
  });

  // 具名运行配置：GUI 新建/编辑/删除，MCP 与 AI 按名选。
  group('RunConfig.fromJson', () {
    test('字段全量解析，平台键归一', () {
      final c = RunConfig.fromJson(<String, Object?>{
        'name': ' overseas debug ',
        'device': '26KUT23C26001579',
        'target': 'lib/main.dart',
        'args': <String>['--flavor', 'oversea', '  '],
        'env': <String, Object?>{'FOO': 'bar', ' ': 'x'},
        'preRun': <String>['bash scripts/dev_run.sh --prepare'],
        'postStop': <String>['bash scripts/dev_run.sh --restore'],
        'platforms': <String>['android-arm64', 'web'],
        'note': '海外版',
      })!;
      expect(c.name, 'overseas debug');
      expect(c.device, '26KUT23C26001579');
      expect(c.target, 'lib/main.dart');
      expect(c.args, <String>['--flavor', 'oversea']);
      expect(c.env, <String, String>{'FOO': 'bar'});
      expect(c.preRun, hasLength(1));
      expect(c.postStop, hasLength(1));
      expect(c.platforms, <String>['android']);
      expect(c.note, '海外版');
    });

    test('没名字 / 不是对象 一律 null（避免下拉里出现空名项）', () {
      expect(RunConfig.fromJson(null), isNull);
      expect(RunConfig.fromJson('x'), isNull);
      expect(RunConfig.fromJson(<String, Object?>{'args': <String>['--x']}), isNull);
      expect(RunConfig.fromJson(<String, Object?>{'name': '  '}), isNull);
    });

    test('toJson 只写非空字段，能原样转回', () {
      const c = RunConfig(
        name: 'cn',
        args: <String>['--flavor', 'cn'],
        platforms: <String>['android'],
      );
      final json = c.toJson();
      expect(json.keys, containsAll(<String>['name', 'args', 'platforms']));
      expect(json.containsKey('env'), isFalse);
      final back = RunConfig.fromJson(json)!;
      expect(back.name, 'cn');
      expect(back.args, <String>['--flavor', 'cn']);
      expect(back.platforms, <String>['android']);
    });

    test('appliesTo：没限定平台就都生效，限定了就要认得出平台', () {
      const any = RunConfig(name: 'x', args: <String>['--profile']);
      expect(any.appliesTo('macos'), isTrue);
      const androidOnly =
          RunConfig(name: 'x', platforms: <String>['android']);
      expect(androidOnly.appliesTo('android-arm64'), isTrue);
      expect(androidOnly.appliesTo('macos'), isFalse);
      expect(androidOnly.appliesTo(null), isFalse);
    });
  });

  group('splitArgs', () {
    test('空格分隔、引号包裹、反斜杠转义', () {
      expect(splitArgs('--flavor cn'), <String>['--flavor', 'cn']);
      expect(
        splitArgs('--dart-define="K=V with space" --x'),
        <String>['--dart-define=K=V with space', '--x'],
      );
      expect(splitArgs("'a b'  c"), <String>['a b', 'c']);
      expect(splitArgs(r'--flag=a\ b'), <String>['--flag=a b']);
      expect(splitArgs('   '), isEmpty);
      expect(splitArgs(''), isEmpty);
    });

    test('引号里的反斜杠交给下一个字符，不丢字符', () {
      expect(splitArgs(r'--path="C:\tmp"'), <String>[r'--path=C:\tmp']);
    });
  });

  group('mergeRunArgs', () {
    test('顶层 * → 平台专用 → 配置 args → 本次额外参数', () {
      const p = RunProfile(runArgs: <String, List<String>>{
        '*': <String>['--dart-define=A=1'],
        'android': <String>['--flavor', 'oversea'],
      });
      const c = RunConfig(name: 'cn', args: <String>['--profile']);
      expect(
        mergeRunArgs(
          profile: p,
          config: c,
          platform: 'android-arm64',
          extraArgs: <String>['--dart-define=B=2'],
        ),
        <String>[
          '--dart-define=A=1',
          '--flavor',
          'oversea',
          '--profile',
          '--dart-define=B=2',
        ],
      );
    });

    test('没有配置 / 没有 profile / 平台认不出都不报错', () {
      expect(mergeRunArgs(), isEmpty);
      expect(
        mergeRunArgs(profile: const RunProfile(), platform: null),
        isEmpty,
      );
      expect(
        mergeRunArgs(config: const RunConfig(name: 'x', args: <String>['--x'])),
        <String>['--x'],
      );
    });
  });

  group('preRunFor / postStopFor / targetFor（配置优先，缺了回退项目顶层）', () {
    const profile = RunProfile(
      preRun: <String>['bash project-prepare'],
      postStop: <String>['bash project-restore'],
    );
    const own = RunConfig(
      name: 'own',
      preRun: <String>['bash cfg-prepare'],
      postStop: <String>['bash cfg-restore'],
      target: 'lib/alt.dart',
    );
    const plain = RunConfig(name: 'plain');

    test('配置自己写了就用配置的', () {
      expect(preRunFor(profile, own), <String>['bash cfg-prepare']);
      expect(postStopFor(profile, own), <String>['bash cfg-restore']);
    });

    test('配置没写（或没选配置）就回退项目顶层', () {
      expect(preRunFor(profile, plain), <String>['bash project-prepare']);
      expect(preRunFor(profile, null), <String>['bash project-prepare']);
      expect(postStopFor(profile, plain), <String>['bash project-restore']);
      expect(preRunFor(null, null), isEmpty);
      expect(postStopFor(null, null), isEmpty);
    });

    test('入口文件：显式传的优先，空白等于没传', () {
      expect(targetFor('lib/main.dart', own), 'lib/main.dart');
      expect(targetFor('  ', own), 'lib/alt.dart');
      expect(targetFor(null, own), 'lib/alt.dart');
      expect(targetFor(null, plain), isNull);
    });
  });

  group('missingRunConfigMessage', () {
    test('项目没有任何配置 vs 名字写错（列可用名）', () {
      expect(
        missingRunConfigMessage(configName: 'x', projectRoot: '/p'),
        contains('还没有运行配置'),
      );
      const p = RunProfile(configs: <RunConfig>[
        RunConfig(name: 'cn debug'),
        RunConfig(name: 'oversea debug'),
      ]);
      final msg =
          missingRunConfigMessage(configName: ' nope ', projectRoot: '/p', profile: p);
      expect(msg, contains('nope'));
      expect(msg, contains('cn debug、oversea debug'));
    });
  });

  group('配置增删改（落盘）+ last', () {
    late Directory tmp;
    late String home;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('xbume_run_crud_');
      home = '${tmp.path}/run_profiles.json';
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    Map<String, Object?> readAll() =>
        jsonDecode(File(home).readAsStringSync()) as Map<String, Object?>;

    test('新建后能读回，且保留手写的顶层字段与其他项目', () {
      final project = '${tmp.path}/app';
      Directory(project).createSync();
      File(home).writeAsStringSync(jsonEncode(<String, Object?>{
        'version': 1,
        'projects': <String, Object?>{
          project: <String, Object?>{'preRun': <String>['bash x']},
          '/other': <String, Object?>{'preRun': <String>['y']},
        },
      }));
      saveRunConfig(
        project,
        const RunConfig(
          name: 'cn debug',
          args: <String>['--flavor', 'cn'],
          preRun: <String>['bash scripts/dev_run.sh --flavor cn'],
        ),
        filePath: home,
      );
      final p = loadRunProfile(project, filePath: home)!;
      expect(p.configs, hasLength(1));
      expect(p.configs.single.name, 'cn debug');
      // 顶层手写字段不能被吃掉
      expect(p.preRun, <String>['bash x']);
      final all = readAll();
      expect(all['version'], 2);
      expect((all['projects'] as Map).containsKey('/other'), isTrue);
    });

    test('同名覆盖不重复，顺序稳定', () {
      final project = '${tmp.path}/app';
      Directory(project).createSync();
      saveRunConfig(project,
          const RunConfig(name: 'a', args: <String>['--x']), filePath: home);
      saveRunConfig(project,
          const RunConfig(name: 'b', args: <String>['--y']), filePath: home);
      saveRunConfig(project,
          const RunConfig(name: 'a', args: <String>['--z']), filePath: home);
      final p = loadRunProfile(project, filePath: home)!;
      expect(p.configs.map((c) => c.name), <String>['b', 'a']);
      expect(p.configs.last.args, <String>['--z']);
    });

    test('删除：存在的删掉并清 last，不存在返回 false', () {
      final project = '${tmp.path}/app';
      Directory(project).createSync();
      saveRunConfig(project, const RunConfig(name: 'a'), filePath: home);
      rememberLastRun(project, config: 'a', args: <String>['--x'], filePath: home);
      expect(deleteRunConfig(project, 'a', filePath: home), isTrue);
      expect(deleteRunConfig(project, 'a', filePath: home), isFalse);
      final p = loadProjectProfile(project, filePath: home)!;
      expect(p.configs, isEmpty);
      expect(p.last, isNull);
    });

    test('记住 last：能读回；都为空时清掉', () {
      final project = '${tmp.path}/app';
      Directory(project).createSync();
      rememberLastRun(
        project,
        config: 'oversea debug',
        args: <String>['--dart-define=K=V'],
        filePath: home,
      );
      final p = loadProjectProfile(project, filePath: home)!;
      expect(p.last!.config, 'oversea debug');
      expect(p.last!.args, <String>['--dart-define=K=V']);
      // 只有 last 不算「有配置」：启动链路行为不变
      expect(loadRunProfile(project, filePath: home), isNull);
      rememberLastRun(project, filePath: home);
      expect(loadProjectProfile(project, filePath: home)!.last, isNull);
    });

    test('只记住 last 的项目也能被 loadProjectProfile 读到', () {
      final project = '${tmp.path}/app';
      Directory(project).createSync();
      rememberLastRun(project, args: <String>['--x'], filePath: home);
      final p = loadProjectProfile(project, filePath: home)!;
      expect(p.last!.config, isNull);
      expect(p.last!.args, <String>['--x']);
      expect(loadRunProfile(project, filePath: home), isNull);
    });

    test('坏 JSON：写之前先备份，不静默吃掉用户内容', () {
      final project = '${tmp.path}/app';
      Directory(project).createSync();
      File(home).writeAsStringSync('{"projects": {oops');
      saveRunConfig(project, const RunConfig(name: 'a'), filePath: home);
      final backups = Directory(tmp.path)
          .listSync()
          .map((e) => e.path)
          .where((p) => p.contains('.broken-'))
          .toList();
      expect(backups, hasLength(1));
      expect(loadRunProfile(project, filePath: home)!.configs, hasLength(1));
    });

    test('重名配置手写进文件时只认第一条', () {
      final project = '${tmp.path}/app';
      Directory(project).createSync();
      File(home).writeAsStringSync(jsonEncode(<String, Object?>{
        'projects': <String, Object?>{
          project: <String, Object?>{
            'configs': <Object?>[
              <String, Object?>{'name': 'a', 'args': <String>['--first']},
              <String, Object?>{'name': 'a', 'args': <String>['--second']},
            ],
          },
        },
      }));
      final p = loadRunProfile(project, filePath: home)!;
      expect(p.configs.map((c) => c.name), <String>['a']);
      expect(p.configs.single.args, <String>['--first']);
    });

    test('configNamed：忽略两侧空白，不存在返回 null', () {
      const p = RunProfile(configs: <RunConfig>[
        RunConfig(name: 'cn debug', args: <String>['--flavor', 'cn']),
      ]);
      expect(p.configNamed(' cn debug ')!.args, <String>['--flavor', 'cn']);
      expect(p.configNamed('nope'), isNull);
      expect(p.configNamed(null), isNull);
      expect(p.configNamed(''), isNull);
    });
  });
}
