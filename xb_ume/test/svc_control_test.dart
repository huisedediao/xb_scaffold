import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/ide_gui.dart' as gui;
import '../bin/src/control/svc_control.dart' as svc;

/// 服务控制（GUI / daemon 启停重启）的纯函数 + 路径约定 + HTTP 契约。
/// 不启动真实 GUI、不碰 launchd、不发任何停止/重启请求（那会动到本机服务）。
void main() {
  group('目标与执行顺序', () {
    test('normalizeSvcTarget 只认 gui / daemon / all', () {
      expect(svc.normalizeSvcTarget('gui'), 'gui');
      expect(svc.normalizeSvcTarget(' DAEMON '), 'daemon');
      expect(svc.normalizeSvcTarget('All'), 'all');
      expect(svc.normalizeSvcTarget(''), isNull);
      expect(svc.normalizeSvcTarget(null), isNull);
      expect(svc.normalizeSvcTarget('desktop'), isNull);
    });

    test('重启全部时 daemon 必须先于 GUI', () {
      // 反过来会出现新 GUI 起来后短暂读到「守护进程未运行」的空窗。
      expect(svc.svcActionOrder('all'), <String>['daemon', 'gui']);
      expect(svc.svcActionOrder('gui'), <String>['gui']);
      expect(svc.svcActionOrder('daemon'), <String>['daemon']);
      expect(svc.svcActionOrder('nope'), isEmpty);
    });
  });

  group('launchd 命令拼装', () {
    test('kickstart -k 原地重启（不产生双实例空窗）', () {
      expect(
        svc.launchdKickstartArgs('501'),
        <String>['kickstart', '-k', 'gui/501/com.xbume.ide'],
      );
    });

    test('bootstrap / bootout 带 plist 路径', () {
      const plist = '/Users/x/Library/LaunchAgents/com.xbume.ide.plist';
      expect(
        svc.launchdBootstrapArgs('501', plist),
        <String>['bootstrap', 'gui/501', plist],
      );
      expect(
        svc.launchdBootoutArgs('501', plist),
        <String>['bootout', 'gui/501', plist],
      );
    });
  });

  group('GUI 接班人', () {
    test('参数带 --restart-owner 与固定端口', () {
      final args = svc.guiSuccessorArgs(
        script: '/Users/x/.xb_ume_ide/ide_gui.dart',
        ownerPid: 42183,
        port: 46129,
      );
      expect(args.first, '/Users/x/.xb_ume_ide/ide_gui.dart');
      expect(args.contains('--restart-owner'), isTrue);
      expect(args[args.indexOf('--restart-owner') + 1], '42183');
      expect(args[args.indexOf('--port') + 1], '46129');
    });
  });

  group('重新部署命令', () {
    test('shell：先等旧 pid 退出，再跑源码 --install 并追加日志', () {
      final cmd = svc.redeployShellCommand(
        waitPid: 42183,
        dartBin: '/dart',
        installScript: '/repo/bin/ide.dart',
        logPath: '/h/install.log',
      );
      expect(cmd.contains('while kill -0 42183'), isTrue);
      expect(cmd.contains('"/repo/bin/ide.dart" --install'), isTrue);
      expect(cmd.contains('/h/install.log'), isTrue);
      // 必须是 cd 到源码目录执行（--install 依赖项目里的 package_config）。
      expect(cmd.contains('--install'), isTrue);
    });

    test('powershell：等价等待 + 输出重定向', () {
      final cmd = svc.redeployPowerShellCommand(
        waitPid: 77,
        dartBin: r'C:\dart.exe',
        installScript: r'C:\repo\bin\ide.dart',
        logPath: r'C:\h\install.log',
      );
      expect(cmd.contains('Get-Process -Id 77'), isTrue);
      expect(cmd.contains('--install'), isTrue);
      expect(cmd.contains(r'C:\h\install.log'), isTrue);
    });
  });

  group('配置与日志纯函数', () {
    test('sourceRootFromConfig 容忍坏 JSON / 空值', () {
      expect(
        svc.sourceRootFromConfig('{"sourceRoot":"/repo/xb_ume","ideOrder":["code"]}'),
        '/repo/xb_ume',
      );
      expect(svc.sourceRootFromConfig('{"sourceRoot":"  "}'), isNull);
      expect(svc.sourceRootFromConfig('{"ideOrder":[]}'), isNull);
      expect(svc.sourceRootFromConfig('not json'), isNull);
      expect(svc.sourceRootFromConfig(null), isNull);
    });

    test('installLogTail 只保留尾部若干行', () {
      const text = 'l1\nl2\nl3\nl4';
      expect(svc.installLogTail(text, maxLines: 2), 'l3\nl4');
      expect(svc.installLogTail(text, maxLines: 10), text);
      expect(svc.installLogTail('', maxLines: 3), '');
      expect(svc.installLogTail(text, maxLines: 0), '');
    });

    test('部署副本缺 src 依赖时点名具体文件', () {
      final dir = Directory.systemTemp.createTempSync('xbume_svc_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final script = File('${dir.path}${Platform.pathSeparator}ide.dart')
        ..writeAsStringSync("import 'src/a.dart';\nimport 'src/b.dart';\n");
      final src = Directory('${dir.path}${Platform.pathSeparator}src')
        ..createSync();
      File('${src.path}${Platform.pathSeparator}a.dart').writeAsStringSync('//');
      expect(svc.missingDaemonDeps(scriptPath: script.path), <String>['src/b.dart']);
      // 脚本本身不存在时也要给出可读的提示，而不是空列表。
      expect(
        svc.missingDaemonDeps(scriptPath: '${dir.path}/nope/ide.dart'),
        isNotEmpty,
      );
    });
  });

  group('路径与双端约定', () {
    test('所有路径都落在 ~/.xb_ume_ide 下', () {
      expect(svc.svcInstallDir().endsWith('.xb_ume_ide'), isTrue);
      expect(svc.daemonScriptPath().endsWith('ide.dart'), isTrue);
      expect(svc.guiScriptPath().endsWith('ide_gui.dart'), isTrue);
      expect(svc.daemonPlistPath().endsWith('com.xbume.ide.plist'), isTrue);
      expect(svc.installLogPath().endsWith('install.log'), isTrue);
      expect(svc.guiTokenPath().endsWith('gui.token'), isTrue);
      expect(svc.svcConfigPath().endsWith('config.json'), isTrue);
    });

    test('端口与标签和 GUI / 守护脚本保持一致', () {
      // GUI 自己仍用 kGuiPortBase 做端口顺延扫描，两边必须同值。
      expect(svc.kGuiPortBase, gui.kGuiPortBase);
      expect(svc.kDaemonLockPort, 46128);
      expect(svc.kDaemonLabel, 'com.xbume.ide');
      expect(svc.kDaemonStatusToken, 'xbume-ide-status');
    });
  });

  group('GUI 服务菜单结构', () {
    test('顶栏有状态徽标、下拉与动作函数', () {
      const html = gui.guiHtml;
      for (final s in <String>[
        'id="svc-badge-gui"',
        'id="svc-badge-daemon"',
        'id="svc-menu"',
        'id="svc-btn"',
        'function svcToggle(',
        'function svcPoll(',
        'function svcRender(',
        'function svcAct(',
        'function svcOverlay(',
        'function svcShowLog(',
        'id="svc-overlay"',
        'id="svc-logbox"',
        "/api/svc/' + action",
        "svcAct('restart','daemon')",
        "svcAct('stop','gui')",
        "svcAct('restart','all')",
      ]) {
        expect(html.contains(s), isTrue, reason: s);
      }
    });

    test('调试/守护功能没被误删（exc-overlay 仍在）', () {
      expect(gui.guiHtml.contains('id="exc-overlay"'), isTrue);
      expect(gui.guiHtml.contains('function restartDaemon('), isTrue);
    });
  });

  group('服务控制 HTTP 契约', () {
    const token = 'test-svc-token-0123456789';
    late HttpServer server;
    late int port;
    late gui.GuiState state;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      state = gui.GuiState();
      gui.setGuiAuthForTest(token, port);
      server.listen((req) {
        unawaited(gui.handleRequest(state, req));
      });
    });

    tearDown(() async {
      await state.dispose();
      await server.close(force: true);
      gui.setGuiAuthForTest('', 0);
    });

    Future<Map<String, Object?>> get(String path) async {
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
        req.headers.set('x-xbume-token', token);
        final resp = await req.close();
        final text = await utf8.decoder.bind(resp).join();
        expect(resp.statusCode, 200, reason: text);
        return jsonDecode(text) as Map<String, Object?>;
      } finally {
        client.close(force: true);
      }
    }

    test('status 返回 GUI 自身信息与源码目录', () async {
      final d = await get('/api/svc/status');
      expect(d['ok'], isTrue);
      final g = d['gui'] as Map;
      expect(g['pid'], isPositive);
      expect(g['port'], port);
      expect(g['uptimeSec'], isA<int>());
      // daemon 可能是 null（未运行）也可能是本机常驻实例的信息，两种都合法。
      expect(d.containsKey('daemon'), isTrue);
      expect(d.containsKey('sourceRoot'), isTrue);
    });

    test('log 无文件时也给空态，不报错', () async {
      final d = await get('/api/svc/log');
      expect(d['ok'], isTrue);
      expect(d['offset'], isA<int>());
      expect(d['text'], isA<String>());
    });

    test('未知动作返回明确错误、不产生副作用', () async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(
          Uri.parse('http://127.0.0.1:$port/api/svc/nope'),
        );
        req.headers.set('x-xbume-token', token);
        req.headers.contentLength = 0;
        final resp = await req.close();
        final text = await utf8.decoder.bind(resp).join();
        final d = jsonDecode(text) as Map<String, Object?>;
        expect(d['ok'], isFalse);
        expect('${d['message']}'.contains('未知动作'), isTrue);
      } finally {
        client.close(force: true);
      }
    });

    test('未授权请求被拒（令牌不匹配）', () async {
      final client = HttpClient();
      try {
        final req =
            await client.getUrl(Uri.parse('http://127.0.0.1:$port/api/svc/status'));
        req.headers.set('x-xbume-token', 'wrong-token');
        final resp = await req.close();
        expect(resp.statusCode, 403);
      } finally {
        client.close(force: true);
      }
    });

    test('重启后的旧 Cookie 不会压过正确的 header 令牌', () async {
      // 浏览器里的 Cookie 名字只含端口，GUI 重启后同名但值已变；页面里带的
      // header 才是新令牌，不能因陈旧 Cookie 就判未授权。
      final client = HttpClient();
      try {
        final req =
            await client.getUrl(Uri.parse('http://127.0.0.1:$port/api/svc/status'));
        req.headers.set('x-xbume-token', token);
        req.headers.set('cookie', 'xbume_gui_$port=stale-token-from-last-run');
        final resp = await req.close();
        final text = await utf8.decoder.bind(resp).join();
        expect(resp.statusCode, 200, reason: text);
        expect((jsonDecode(text) as Map<String, Object?>)['ok'], isTrue);
      } finally {
        client.close(force: true);
      }
    });

    test('旧标签页遇到 403 会自动重载一次（限频）', () {
      // 令牌随进程启动重新生成，旧标签页拿不到新令牌；只能靠重载重新签发。
      const html = gui.guiHtml;
      expect(html.contains('r.status !== 403'), isTrue);
      expect(html.contains("sessionStorage.setItem('xbume_auth_reload'"), isTrue);
      expect(html.contains('location.reload(); }, 80)'), isTrue);
    });
  });

  group('本工具常驻进程识别（全新运行前要回收的清单）', () {
    const dart = '/Users/x/xb_flutter/bin/cache/dart-sdk/bin/dart';

    test('部署版：GUI / 热键监听 / 常驻 MCP / daemon 都命中', () {
      expect(
        svc.isOwnToolCommandLine(
            '$dart /Users/x/.xb_ume_ide/ide_gui.dart --restart-owner 1 --port 46129'),
        isTrue,
      );
      expect(
        svc.isOwnToolCommandLine(
            '$dart /Users/x/.xb_ume_ide/src/hotkeys/hotkey_listener.dart '
            '--home /Users/x --port 46129'),
        isTrue,
      );
      expect(
        svc.isOwnToolCommandLine(
            '$dart /Users/x/.xb_ume_ide/mcp.dart --http 46140 --name mcp-46140'),
        isTrue,
      );
      expect(
        svc.isOwnToolCommandLine('$dart /Users/x/.xb_ume_ide/ide.dart --daemon'),
        isTrue,
      );
    });

    test('分发版：Contents/MacOS 下的 xbume-* 入口命中，stdio MCP 不碰', () {
      const exe = '/Applications/XbUme.app/Contents/MacOS';
      expect(svc.isOwnToolCommandLine('$exe/xbume-gui --port 46129'), isTrue);
      expect(svc.isOwnToolCommandLine('$exe/xbume-hotkey --home /Users/x'),
          isTrue);
      expect(svc.isOwnToolCommandLine('$exe/xbume-ide --daemon'), isTrue);
      expect(svc.isOwnToolCommandLine('$exe/xbume-mcp --http 46140'), isTrue);
      // stdio 实例是 AI 客户端当前会话的工具连接，杀了客户端会直接报错。
      expect(svc.isOwnToolCommandLine('$exe/xbume-mcp'), isFalse);
    });

    test('部署器、flutter run、编辑器与 grep 都不能误杀', () {
      expect(svc.isOwnToolCommandLine('dart run xb_ume:ide --install'), isFalse);
      expect(
        svc.isOwnToolCommandLine('/Users/x/xb_ume/bin/ide.dart --install'),
        isFalse,
      );
      expect(
        svc.isOwnToolCommandLine('flutter_tools.snapshot run -d DEVICE'),
        isFalse,
      );
      expect(svc.isOwnToolCommandLine('grep ide_gui.dart'), isFalse);
      expect(
        svc.isOwnToolCommandLine('/usr/bin/vim /Users/x/.xb_ume_ide/ide_gui.dart'),
        isFalse,
      );
      // 部署版 MCP 的 stdio 实例同样不能碰（AI 客户端当场会用不了工具）。
      expect(
        svc.isOwnToolCommandLine('$dart /Users/x/.xb_ume_ide/mcp.dart'),
        isFalse,
      );
      expect(svc.isOwnToolCommandLine(''), isFalse);
    });
  });

  group('桌面图标 = 一键全新开启（源码安装与分发版同一语义）', () {
    test('POSIX 启动器带 exec + --fresh，不再只拉起 GUI', () {
      final posix = svc.freshLauncherCommand(
        dartBin: '/d/bin/dart',
        installDir: '/Users/x/.xb_ume_ide',
      );
      expect(
        posix,
        'exec "/d/bin/dart" "/Users/x/.xb_ume_ide/ide.dart" --fresh',
      );
      expect(posix.contains('--ensure-daemon'), isFalse);
    });

    test('Windows 启动器同样走 --fresh（无 exec）', () {
      final win = svc.freshLauncherCommand(
        dartBin: r'C:\dart-sdk\bin\dart.exe',
        installDir: r'C:\Users\x\.xb_ume_ide',
        shell: false,
      );
      expect(win.contains('--fresh'), isTrue);
      expect(win.startsWith('exec '), isFalse);
    });

    test('回收先 SIGTERM 走优雅退出，再 SIGKILL 兑底', () {
      // SIGKILL 不触发 GUI 的优雅退出，它拉起的 hdc hilog / adb logcat /
      // simctl log stream 会留成孤儿，攒几天就能把 hdc 连接占满。
      final source =
          File('bin/src/control/svc_control.dart').readAsStringSync();
      final start = source.indexOf('Future<List<int>> killOwnToolProcesses(');
      expect(start, greaterThanOrEqualTo(0), reason: '未找到 killOwnToolProcesses');
      final end = source.indexOf('\n}\n', start);
      final body = source.substring(start, end);
      final term = body.indexOf('force: false');
      final hard = body.indexOf('force: true');
      expect(term, greaterThanOrEqualTo(0), reason: '先发 SIGTERM');
      expect(hard, greaterThan(term), reason: 'SIGKILL 只能做超时兑底');
    });
  });
}
