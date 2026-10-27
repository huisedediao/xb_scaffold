// GUI 里 MCP 服务的启停约束：卡片按钮 → /api/mcp/start|stop（detached 拉起
// 部署副本、按 PID 记录停止、重复启动幂等），「随工具箱启动」开关写
// config.json 的 mcpAutoStart 并在 GUI 启动时拉起。前后端都内联在
// ide_gui.dart，只能做源码级断言 —— 与 gui_timeline_clear_test.dart 同一套思路。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String fnBody(String src, String needle) {
  final start = src.indexOf(needle);
  expect(start, greaterThanOrEqualTo(0), reason: '未找到 $needle');
  final end = src.indexOf('\n}\n', start);
  expect(end, greaterThan(start), reason: '$needle 未闭合');
  return src.substring(start, end);
}

void main() {
  final gui = File('bin/ide_gui.dart').readAsStringSync();
  final mcp = File('bin/mcp.dart').readAsStringSync();

  test('启停与自动开关各有独立端点且只接受 POST', () {
    for (final p in <String>[
      '/api/mcp/start',
      '/api/mcp/stop',
      '/api/mcp/auto',
    ]) {
      expect(gui, contains("path == '$p' && req.method == 'POST'"),
          reason: '$p 未做方法校验');
    }
    // 状态探针把卡片需要的三个字段一起下发，前端才敢显示按钮/勾选框。
    final s = gui.indexOf("if (path == '/api/mcp')");
    final e = gui.indexOf("if (path == '/api/mcp/start'");
    expect(s, greaterThanOrEqualTo(0));
    expect(e, greaterThan(s));
    final route = gui.substring(s, e);
    for (final key in <String>['autoStart', 'launchable', 'managedPid']) {
      expect(route, contains("'$key'"), reason: '/api/mcp 少了 $key');
    }
  });

  test('启动：先探活（幂等）、只在 46140-46149 挑端口、detached 且开全部工具组', () {
    final body = fnBody(gui, 'Future<Map<String, Object?>> startMcp(');
    expect(body, contains('probeMcpStatus'), reason: '已经在跑就不能起第二个实例');
    expect(body, contains('已在运行'));
    expect(body, contains('kMcpDefaultPort + 10'),
        reason: '端口只在 46140-46149 里挑，不能乱占别的端口');
    expect(body, contains('ProcessStartMode.detached'),
        reason: 'GUI 退出后服务要能继续跑');
    for (final arg in <String>["'--http'", "'--tool-groups'", "'all'", "'--log-file'"]) {
      expect(body, contains(arg), reason: '启动参数少了 $arg');
    }
    expect(body, contains('_mcpPidFile.writeAsStringSync'),
        reason: '停止要靠 PID 记录定位');
    expect(body, contains('ensureMcpToken'),
        reason: '先建好 token，否则首次握手 401（两边生成的可能不是同一个）');
  });

  test('停止：只按 PID 记录杀自己拉起的进程', () {
    final body = fnBody(gui, 'Future<Map<String, Object?>> stopMcp(');
    expect(body, contains('readMcpPidRecord'));
    expect(body, contains('ProcessSignal.sigterm'));
    expect(body, contains('不是工具箱启动的'),
        reason: '没有 PID 记录时不能按端口去杀别人的进程');
    expect(body, contains('_mcpPidFile.deleteSync'));
  });

  test('「随工具箱启动」写 config.json 且随 GUI 启动拉起', () {
    final write = fnBody(gui, 'Future<void> writeMcpAutoStart(');
    expect(write, contains("cfg['mcpAutoStart'] = on"));
    expect(write, contains('_guiReadConfigRaw'),
        reason: '改一个键不能把 ideOrder 等其它配置冲掉');
    expect(gui, contains("_guiReadConfigRaw()['mcpAutoStart'] == true"),
        reason: '默认必须是关');
    expect(gui, contains('if (readMcpAutoStart())'),
        reason: '_mainImpl 启动时要按开关拉起');
    final mainImpl = gui.substring(gui.indexOf('Future<void> _mainImpl('));
    expect(mainImpl, contains('unawaited(startMcp()'),
        reason: '自动启动不能阻塞 HTTP 服务');
  });

  test('卡片按钮/勾选框与状态刷新联动', () {
    expect(gui, contains('id="mcp-toggle"'));
    expect(gui, contains('id="mcp-auto"'));
    final apply = fnBody(gui, 'function mcpApplyStatus(');
    expect(apply, contains("btn.textContent = '停止'"));
    expect(apply, contains("btn.textContent = '启动'"));
    expect(apply, contains('mcpConfigShown'),
        reason: '复制出来的配置不能被 5 秒轮询冲掉');
    final toggle = fnBody(gui, 'function toggleMcp(');
    expect(toggle, contains("'/api/mcp/stop'"));
    expect(toggle, contains("'/api/mcp/start'"));
    final auto = fnBody(gui, 'function setMcpAuto(');
    expect(auto, contains("'/api/mcp/auto?on='"));
    expect(auto, contains('toggleMcp('),
        reason: '勾上时服务没跑要立即拉起，否则开关看起来没生效');
  });

  test('mcp.dart 支持 --log-file，部署副本能报出版本号', () {
    expect(mcp, contains("'--log-file'"));
    expect(mcp, contains('_logSink'));
    expect(fnBody(mcp, 'String _readVersion('), contains('version.txt'),
        reason: '部署目录没有 pubspec.yaml，要有版本回退');
  });
}
