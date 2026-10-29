import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/ide_gui.dart' as gui;

/// 「调试」Tab 的静态结构 + /api/debug/op 的 HTTP 契约。
/// 用内存 HttpServer 驱动 handleRequest，不启动 GUI，也不碰设备/调试会话。
void main() {
  group('调试页 HTML', () {
    test('含调试 Tab、页面、浮动工具条与关键动作', () {
      const html = gui.guiHtml;
      expect(html.contains('data-tab="debug"'), isTrue);
      expect(html.contains('id="page-debug"'), isTrue);
      expect(html.contains('id="dbg-bar"'), isTrue);
      for (final fn in <String>[
        'dbgStart(',
        'dbgAttach(',
        'dbgAddBp(',
        'dbgToggleBp(',
        'dbgResume(',
        'dbgHot(',
        'dbgStop(',
        'dbgEval(',
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
    });

    test('异常 / 网络定位行接上「一键下断点」', () {
      // 异常栈帧 / 相关 Widget / 网络发起位置的「断点」链接。
      const html = gui.guiHtml;
      for (final fn in <String>[
        'excQuickBp(',
        'excFrameQuickBp(',
        'nwInitQuickBp(',
        'function dbgQuickBp(',
        'rememberBreakpoint',
        'dbgPrefillBp(',
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
      // 位置不属于当前调试会话时不能默默下到错的会话上。
      expect(html.contains('function dbgSamePort('), isTrue);
    });

    test('断点卡片接上日志表达式、全部项目总览与就地编辑', () {
      const html = gui.guiHtml;
      for (final fn in <String>[
        'id="dbg-bp-log"',
        'logMessage',
        'function dbgShowAllSaved(',
        'function dbgRenderSavedAll(',
        'savedAll',
        'function dbgForgetDirAt(',
        'id="dbg-bp-add"',
        'function dbgEditBp(',
        'function dbgCancelBpEdit(',
        'updateBreakpoint',
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
    });

    test('源码面板：点行号下断点（不用手输 文件:行）', () {
      const html = gui.guiHtml;
      for (final fn in <String>[
        'id="dbg-src-card"',
        'id="dbg-src-code"',
        'id="dbg-src-files"',
        'function dbgSrcOpen(',
        'function dbgSrcPick(',
        'function dbgSrcRender(',
        'function dbgSrcMark(',
        'function dbgSrcToggle(',
        'function dbgSrcFollowPause(',
        '/api/fs/dartfiles',
        '/api/fs/file',
        // 没连会话时「再点取消」要能删掉落盘的那一条。
        'forgetBreakpoint',
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
      // 断点表 / 暂停状态变化后都要重刷行内标记，否则点了没反馈。
      expect(html.contains('dbgSrcMark();'), isTrue);
      expect(html.contains('dbgSrcFollowPause();'), isTrue);
    });

    test('单步跟随时项目外文件也能跟（只读，不许下断点）', () {
      const html = gui.guiHtml;
      for (final fn in <String>[
        'function dbgSrcPauseTarget(',
        'function dbgSrcShortPath(',
        "mode: 'pkg'",
        "mode: 'abs'",
        "mode === 'abs'",
        '&abs=',
        'dbgSrcOutside',
        // 项目外只弹提示，不能偷偷写断点下去。
        '不能下断点',
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
    });

    test('接上三类 WebSocket 推送（事件/状态/输出）', () {
      const html = gui.guiHtml;
      // 少接任一条，界面就会「点得动但看不到变化」。
      expect(html.contains("msg.type === 'debug'"), isTrue);
      expect(html.contains("msg.type === 'debugState'"), isTrue);
      expect(html.contains("msg.type === 'debugOutput'"), isTrue);
    });

    test('运行配置：只读摘要 + 打开配置文件 + 启动带平台', () {
      const html = gui.guiHtml;
      for (final s in <String>[
        'id="dbg-profile"',
        'function dbgProfileRefresh(',
        'function dbgProfileText(',
        'function dbgProfileOpen(',
        '/api/openconfig?file=run',
        'dbgPlatformOf(',
        // 启动时把设备平台一并交给后端，配置才能按平台选参数。
        "platform: dbgPlatformOf(dev) || null",
      ]) {
        expect(html.contains(s), isTrue, reason: s);
      }
    });
  });

  group('调试后端接口', () {
    const token = 'test-debug-token-0123456789';
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

    Future<Map<String, Object?>> op(
      String? body, {
      String method = 'POST',
      String query = '',
    }) async {
      final client = HttpClient();
      try {
        final req = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:$port/api/debug/op$query'),
        );
        req.headers.set('x-xbume-token', token);
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(body);
        }
        final resp = await req.close();
        final text = await utf8.decoder.bind(resp).join();
        expect(resp.statusCode, 200, reason: text);
        return jsonDecode(text) as Map<String, Object?>;
      } finally {
        client.close(force: true);
      }
    }

    test('GET status 回空态与输出缓冲', () async {
      final d = await op(null, method: 'GET', query: '?op=status');
      expect(d['ok'], isTrue);
      expect(d['op'], 'status');
      expect(d['attached'], isFalse);
      expect(d['running'], isFalse);
      expect(d['paused'], isFalse);
      expect(d['breakpoints'], isEmpty);
      expect(d['output'], isEmpty);
    });

    test('未开会话时 stop 只断开、不杀进程', () async {
      final d = await op(jsonEncode(<String, Object?>{'op': 'stop'}));
      expect(d['ok'], isTrue);
      expect(d['stopped'], isFalse);
      expect('${d['message']}'.contains('没有在跑'), isTrue);
    });

    test('非法 JSON body 按 status 处理（不报 500）', () async {
      final d = await op('{"op":"hot",{}');
      expect(d['ok'], isTrue);
      expect(d['op'], 'status');
    });

    test('未知 op 回可读错误而不是异常', () async {
      final d = await op(jsonEncode(<String, Object?>{'op': 'no-such-op'}));
      expect(d['ok'], isFalse);
      expect('${d['error']}'.contains('未知操作'), isTrue);
    });

    test('runProfile 只读接口：项目没配置也算正常返回', () async {
      final dir = Directory.systemTemp.createTempSync('xbume_gui_profile_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final d = await op(
        null,
        method: 'GET',
        query: '?op=runProfile&dir=${Uri.encodeQueryComponent(dir.path)}',
      );
      expect(d['ok'], isTrue);
      expect(d['op'], 'runProfile');
      expect('${d['path']}'.endsWith('/debug/run_profiles.json'), isTrue);
      // 没配这个项目：不带 profile 字段（前端显示「未配置」）。
      expect(d.containsKey('profile'), isFalse);
    });
  });
}
