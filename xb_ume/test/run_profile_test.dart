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
}
