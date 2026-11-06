// 「全局快捷键」前后端契约：工具条上的标签 / ⌨ 弹窗、/api/hotkeys 的读写、
// 以及监听器回调入口 /api/hotkey/action 的约束。
//
// 这里只做结构断言与「非法配置被拒」的写接口测试，绝不提交合法配置、也绝不
// 调用 /api/hotkey/action —— 那会在真的调试会话上触发热重载。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/ide_gui.dart' as gui;

void main() {
  group('页面结构', () {
    const html = gui.guiHtml;

    test('工具条两个按钮带快捷键标签，旁边有「快捷键」设置入口', () {
      expect(html.contains('<span class="kbd" id="dbg-b-hot-k"></span>'), isTrue);
      expect(
        html.contains('<span class="kbd" id="dbg-b-restart-k"></span>'),
        isTrue,
      );
      expect(html.contains('>快捷键</button>'), isTrue,
          reason: '设置入口用文字：⌨ 在部分系统字体会渲染成方块');
      expect(html.contains('onclick="hkOpen()"'), isTrue);
      // 标签样式必须给 .kbd 留空时隐藏，否则没设置时按钮右侧多一坨空白
      expect(html.contains('#dbg-bar .kbd'), isTrue);
      expect(html.contains('.kbd:empty'), isTrue);
    });

    test('设置弹窗含启用开关、完成通知开关、两条录制框、保存与状态区', () {
      for (final id in <String>[
        'hk-mask',
        'hk-card',
        'hk-enabled',
        'hk-notify',
        'hk-reload',
        'hk-restart',
        'hk-msg',
        'hk-stat',
      ]) {
        expect(html.contains('id="$id"'), isTrue, reason: '缺 $id');
      }
      expect(html.contains("onclick=\"hkRecord('reload')\""), isTrue);
      expect(html.contains("onclick=\"hkRecord('restart')\""), isTrue);
      expect(html.contains('保存并应用'), isTrue);
    });

    test('完成通知开关参与保存与回填，缺省当开', () {
      expect(html.contains('onchange="hkToggleNotify(this)"'), isTrue);
      expect(html.contains('function hkToggleNotify('), isTrue);
      expect(html.contains('notify: hkState.notify !== false'), isTrue,
          reason: '保存要把开关带上');
      expect(html.contains('notify: d.config.notify !== false'), isTrue,
          reason: '老配置没这个字段时要当成开');
      expect(html.contains('完成后发系统通知'), isTrue);
    });

    test('录制在捕获阶段拦按键，并强制带 ⌘/⌃/⌥', () {
      // 捕获阶段（第三个参数 true）：否则输入框/页面快捷键先把按键吃掉。
      // 页面里还有别的 keydown（草稿间快捷键），按 hkRec 定位到录制这一段。
      final anchor = html.indexOf('if (!hkRec) return;');
      expect(anchor, greaterThanOrEqualTo(0));
      final start = html.lastIndexOf("document.addEventListener('keydown'", anchor);
      expect(start, greaterThanOrEqualTo(0));
      final end = html.indexOf('}, true);', start);
      expect(end, greaterThan(start), reason: '录制监听没走捕获阶段');
      final seg = html.substring(start, end + '}, true);'.length);
      expect(seg.contains('}, true);'), isTrue, reason: '必须在捕获阶段监听');
      expect(seg.contains('e.preventDefault()'), isTrue);
      expect(seg.contains('e.stopPropagation()'), isTrue);
      expect(seg.contains("e.key === 'Escape'"), isTrue, reason: 'Esc 要能取消录制');
      expect(seg.contains("'Backspace'"), isTrue, reason: '退格要能清除绑定');
      expect(seg.contains('至少带一个'), isTrue, reason: '纯按键必须拒绝');
      expect(seg.contains('hkSame('), isTrue, reason: '两条不能录成同一组合');
    });

    test('Windows 用 Ctrl+ 写法，提示文案不写死 macOS', () {
      // 服务端 /api/hotkeys 回报 platform=windows 时，标签与提示改成 Ctrl+… /
      // Ctrl / Alt / Win，不用 ⌘ / ⌃ / ⌥ 符号。
      expect(html.contains('function hkModLabel('), isTrue);
      expect(html.contains("hkWin = d.platform === 'windows'"), isTrue);
      expect(html.contains('id="hk-modhint"'), isTrue);
      expect(html.contains('Ctrl / Alt / Win'), isTrue);
      expect(html.contains('目前只实现了 macOS'), isFalse,
          reason: 'Windows 也支持后，这句旧文案不能留');
    });

    test('没打开调试页也要显示已设置的键位 / 弹窗能拉到服务端状态', () {
      // 启动与切到调试页各刷一次（工具条是全局浮层，不依赖调试 Tab）
      final loadCalls = RegExp(r'hkLoad\(\);').allMatches(html).length;
      expect(loadCalls, greaterThanOrEqualTo(3),
          reason: '应包含 load 事件、dbgShow、hkOpen 三处刷新');
      expect(html.contains("fetch('/api/hotkeys')"), isTrue);
      expect(html.contains("fetch('/api/hotkeys', {"), isTrue);
      expect(html.contains("method: 'POST'"), isTrue);
    });
  });

  group('服务端路由', () {
    test('/api/hotkeys 读写都在，动作入口只收 POST 且标记 via=hotkey', () {
      final src = File('bin/ide_gui.dart').readAsStringSync();
      expect(src.contains("if (path == '/api/hotkeys')"), isTrue);
      expect(src.contains('hotkeyService.save(body)'), isTrue);
      expect(src.contains('jsonEncode(hotkeyService.status())'), isTrue);
      expect(
        src.contains("path == '/api/hotkey/action' && req.method == 'POST'"),
        isTrue,
        reason: '监听器回调必须限定 POST，GET 不能触发',
      );
      final i = src.indexOf("path == '/api/hotkey/action'");
      final seg = src.substring(i, i + 900);
      expect(seg.contains("'via': 'hotkey'"), isTrue,
          reason: '要标来源，DebugHub 才能在提示里区分');
      expect(seg.contains("'restart': restart"), isTrue);
    });

    test('GUI 启动拉起监听器、退出时收掉', () {
      final src = File('bin/ide_gui.dart').readAsStringSync();
      expect(src.contains('unawaited(hotkeyService.start());'), isTrue);
      final i = src.indexOf('Future<void> gracefulShutdown(');
      expect(i, greaterThanOrEqualTo(0));
      expect(src.substring(i, i + 900).contains('_hotkeyService?.stop()'), isTrue,
          reason: 'GUI 退出不能把监听器留在后台');
    });

    test('热重载 / 热重启完成都发系统通知（按钮与热键两条入口）', () {
      final src = File('bin/ide_gui.dart').readAsStringSync();
      expect(src.contains("import 'src/notify/system_notifier.dart';"), isTrue);
      expect(src.contains('void notifyHotDone('), isTrue);
      expect(src.contains('showSystemNotice('), isTrue);
      expect(src.contains('readHotkeysConfig(_home).notify'), isTrue,
          reason: '通知开关要读 hotkeys.json');
      // 页面按钮 / 其他 op 走 /api/debug/op，热键走 /api/hotkey/action：两处都要接
      expect(src.contains("if (op == 'hot') notifyHotDone(result);"), isTrue);
      final kh = src.indexOf("path == '/api/hotkey/action'");
      expect(kh, greaterThanOrEqualTo(0));
      expect(src.substring(kh, kh + 900).contains('notifyHotDone(result);'),
          isTrue,
          reason: '快捷键触发的那条路也要发通知');
    });
  });

  group('/api/hotkeys HTTP', () {
    const token = 'test-token-hotkey-0123456789';
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

    Future<Map<String, Object?>> call(String method, String path,
        {String? body}) async {
      final client = HttpClient();
      try {
        final req = await client.open(method, '127.0.0.1', port, path);
        req.headers.set('x-xbume-token', token);
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(body);
        }
        final resp = await req.close();
        final text = await utf8.decoder.bind(resp).join();
        expect(resp.statusCode, 200, reason: '$method $path → $text');
        return jsonDecode(text) as Map<String, Object?>;
      } finally {
        client.close(force: true);
      }
    }

    test('GET 返回平台 / 启用态 / 配置与监听器状态（只读）', () async {
      final d = await call('GET', '/api/hotkeys');
      expect(d['ok'], isTrue);
      expect(d['platform'], Platform.operatingSystem);
      expect(d['supported'], isA<bool>());
      expect(d['config'], isA<Map>());
      for (final key in <String>[
        'enabled',
        'active',
        'running',
        'configError',
        'logPath',
        'statusFile',
      ]) {
        expect(d.containsKey(key), isTrue, reason: '少了 $key');
      }
    });

    test('非法组合被拒且不落盘（不会覆盖用户已有配置）', () async {
      // 只有 ⇧、没有 ⌘/⌃/⌥：校验应在写文件之前就失败
      final d = await call('POST', '/api/hotkeys',
          body: jsonEncode(<String, Object?>{
            'enabled': true,
            'reload': <String, Object?>{'key': 'KeyR', 'shift': true},
          }));
      expect(d['ok'], isFalse);
      expect('${d['error']}', contains('至少带一个'));
    });

    test('不支持的按键也被拒（不会注册成空组合）', () async {
      final d = await call('POST', '/api/hotkeys',
          body: jsonEncode(<String, Object?>{
            'enabled': true,
            'restart': <String, Object?>{'key': 'AudioVolumeUp', 'cmd': true},
          }));
      expect(d['ok'], isFalse);
      expect('${d['error']}', contains('不支持'));
    });
  });
}
