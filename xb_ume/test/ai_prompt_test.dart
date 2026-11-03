// 「AI 调试模式」的指令生成与项目校验：
// - 指令里必须带项目路径/设备/app_launch 的 cwd（否则 AI 会去 ~/.xb_ume_ide 里跑 flutter run）
// - eval 行只在服务真的开了 eval 时出现（避免 AI 调用不存在的工具）
// - GUI 的「AI 调试」Tab 与命令共用同一份 prompt.dart，前端只能做源码级断言
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/ai/prompt.dart';

void main() {
  group('resolveProjectDir', () {
    test('接受含 pubspec.yaml 的目录', () {
      final dir = Directory.systemTemp.createTempSync('xb_ai_proj_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/pubspec.yaml').writeAsStringSync('name: demo\n');
      expect(resolveProjectDir(dir.path), dir.absolute.path);
    });

    test('拒绝没有 pubspec.yaml 的目录并说明原因', () {
      final dir = Directory.systemTemp.createTempSync('xb_ai_empty_');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(
        () => resolveProjectDir(dir.path),
        throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', contains('pubspec.yaml'))),
      );
    });
  });

  group('buildAiPrompt', () {
    const project = '/tmp/my_flutter_app';
    const device = 'emulator-5554';

    test('写死项目与设备，并明确 cwd 交给 app_launch', () {
      final p = buildAiPrompt(
        projectDir: project,
        deviceId: device,
        hasEval: true,
      );
      expect(p, contains(project));
      expect(p, contains(device));
      expect(p, contains('xbume_app_launch'));
      expect(p, contains('"cwd": "$project"'));
      // 热重载与复跑是闭环的关键，必须在指令里。
      expect(p, contains('xbume_hot_reload'));
      expect(p, contains('"reload"'));
      expect(p, contains('"restart"'));
      expect(p, contains('xbume_timeline'));
      // 拉起前先看现成会话：带 launcher 标记的直接复用，不重跑。
      expect(p, contains('xbume_sessions'));
      expect(p, contains('launcher'));
      expect(p, contains('xbume_use_session'));
      expect(p, contains('reused=true'));
      expect(p, contains('force: true'));
      // 复用优先，且区分「·可热重载」与「·只读」：只读会话也能接（看现场 /
      // 下断点），不要为了看数据就把 IDE 拉起的会话重启掉。
      expect(p, contains('复用优先'));
      expect(p, contains('·可热重载'));
      expect(p, contains('·只读'));
      expect(p, contains('(a) 只读接入'));
      expect(p, contains('(b) 由 xb_ume 接管'));
      // 热重载的回落：只读会话会报错，别反复重试。
      expect(p, contains('只对带·可热重载标记的会话有效'));
      expect(p, contains('不要反复重试'));
    });

    test('三档重载级别写进指令，并点名必须进程级重启的改动', () {
      final p = buildAiPrompt(
        projectDir: project,
        deviceId: device,
        hasEval: true,
      );
      expect(p, contains('按改动类型选重载级别'));
      expect(p, contains('① xbume_hot_reload'));
      expect(p, contains('② xbume_hot_reload'));
      expect(p, contains('③ xbume_app_launch'));
      // 热重启的能力边界必须写清：不重装包、不重编原生。
      expect(p, contains('不会重装包、也不会重编原生'));
      // 四类必须 force 的改动，少一类 AI 就会在旧进程上得出「已修复」。
      for (final s in <String>[
        'pubspec.yaml',
        'MethodChannel',
        '--dart-define',
        '只在 app 启动那一刻读一次',
      ]) {
        expect(p, contains(s), reason: '缺少 $s');
      }
      // 判断不了就按最重的来，且重启后要重新走一遍。
      expect(p, contains('判断不了属于哪一档时按最重的来'));
      expect(p, contains('重启后必须重新走一遍同样的路径再下结论'));
    });

    test('eval 未开启时不出现 xbume_eval', () {
      final p = buildAiPrompt(
        projectDir: project,
        deviceId: device,
        hasEval: false,
      );
      expect(p, isNot(contains('xbume_eval')));
      expect(p, contains('xbume_hot_reload'));
    });
  });

  group('aiClientConfig', () {
    test('HTTP 配置带 token 头', () {
      final c = aiClientConfig(
          url: 'http://127.0.0.1:46140/mcp', token: 'abc123');
      expect(c, contains('"type": "http"'));
      expect(c, contains('http://127.0.0.1:46140/mcp'));
      expect(c, contains('X-XBUME-Token'));
      expect(c, contains('abc123'));
    });
  });

  group('GUI AI 调试 Tab（源码断言）', () {
    test('前端与后端接口都在 ide_gui.dart 里', () {
      final src = File('bin/ide_gui.dart').readAsStringSync();
      // Tab 与页面。
      expect(src, contains('data-tab="ai"'));
      expect(src, contains('id="page-ai"'));
      expect(src, contains('/api/ai/setup'));
      expect(src, contains('/api/ai/config'));
      // 一键开启必须强制带 eval，不能依赖卡片上的勾选。
      expect(src, contains('startMcp(forceEval: true)'));
      expect(src, contains("if (forceEval || readMcpAllowEval()) '--allow-eval'"));
      // 启动前先判断「服务是不是自己拉起的」，不猜进程。
      expect(src, contains('不是工具箱启动的'));
      // 项目目录可下拉选（候选 = 会话反推 + 最近用过），设备用下拉而非手填。
      expect(src, contains('list="ai-dir-list"'));
      expect(src, contains('id="ai-dir-list"'));
      expect(src, contains('<select id="ai-device"'));
      expect(src, contains("'sessionDirs': state.sessionProjectRoots"));
      expect(src, contains("cfg['aiRecentDirs']"));
      expect(src, contains('projectRoot = root'));
      // 项目目录可直接选：后台列目录（浏览器拿不到绝对路径），前端只负责跳转/选定。
      expect(src, contains("path == '/api/fs/dirs'"));
      expect(src, contains("queryParameters['path']"));
      expect(src, contains('listSync(followLinks: false)'));
      expect(src, contains('id="ai-dir-pick"'));
      expect(src, contains('function aiPickDir()'));
      expect(src, contains('function aiPickChoose()'));
      expect(src, contains("aiPickLoad(this.dataset.path)"));
      // 页面说明不能再说「AI 调试不复用 VM 会话」：本工具拉起的会话可以复用
      // 也能热重载，只有 IDE 拉起的才是只读。
      expect(src, isNot(contains('AI 调试不复用它')));
      expect(src, contains('AI 调试会直接<b>复用</b>'));
      expect(src, contains('IDE 拉起的只能只读接入'));
    });
  });
}
