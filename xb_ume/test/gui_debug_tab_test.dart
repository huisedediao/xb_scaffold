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

    test('调试页是 VS Code 式一屏三栏 + 底部输出（不再上下堆卡片）', () {
      const html = gui.guiHtml;
      // 一屏 flex 布局：工具条 + 三栏 + 底部面板，整页不滚
      expect(html.contains('#page-debug.active { display:flex; flex-direction:column;'), isTrue);
      expect(html.contains('.dbg-main { flex:1 1 auto; display:flex;'), isTrue);
      expect(html.contains('.dbg-side {'), isTrue);
      // 窗口不够高时左栏自己滚（否则断点输入区被压没、列表看不见）
      expect(html.contains('.dbg-side { flex:0 0 300px; gap:10px; overflow:auto; }'), isTrue);
      expect(html.contains('.dbg-side > .dbg-bpcard { flex:1 1 auto; min-height:190px; }'), isTrue);
      expect(html.contains('.dbg-varcol {'), isTrue);
      expect(html.contains('class="card dbg-outcard"'), isTrue);
      // 运行输出高度可拖（拖上沿 / 双击复位），默认比原来高
      expect(html.contains('id="dbg-outgrip"'), isTrue);
      expect(html.contains('height:var(--dbg-out-h, clamp(170px,26vh,300px))'), isTrue);
      expect(html.contains('.dbg-outgrip {'), isTrue);
      for (final fn in <String>[
        'function dbgOutHDrag(',
        'function dbgOutHReset(',
        'function dbgOutHClamp(',
        'function dbgOutHApply(',
        "var dbgOutHKey = 'xbume_dbg_out_h';",
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
      // 运行输出的查找 / 筛选（对齐「文件查看」页：查找高亮不过滤、筛选只留匹配行）
      expect(html.contains('id="dbg-out-search"'), isTrue);
      expect(html.contains('id="dbg-out-filter"'), isTrue);
      expect(html.contains('.dbg-outq {'), isTrue);
      for (final fn in <String>[
        'function dbgOutQuery(',
        'function dbgOutHlLine(',
        'function dbgOutEsc(',
        "var dbgOutQ = { s: '', f: '' }",
        '#dbg-out mark.mf {',
        '#dbg-out mark.mb {',
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
      // 没关键词走 textContent 快速路径，有关键词才 innerHTML 高亮
      expect(html.contains('if (!s && !f) {'), isTrue);
      expect(html.contains('el.innerHTML = parts.length ?'), isTrue);
      // 复制：有筛选只复制筛选后的行（渲染与复制共用 dbgOutShown，避免判定漂移）
      expect(html.contains('onclick="dbgOutCopy(this)"'), isTrue);
      for (final fn in <String>[
        'function dbgOutCopy(',
        'function dbgOutShown(',
        'var rows = dbgOutShown(), hits = 0, parts = [];',
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
      // 旧的上下双列容器已经不用了，再回来就会变成「一屏看不到变量 / 输出」
      expect(html.contains('dbg-cols'), isFalse);
      // 源码面板是三栏里的右栏：默认隐藏，关掉时中栏自动变宽
      expect(html.contains('<div class="card dbg-col" id="dbg-src-card" style="display:none">'), isTrue);
      // 换了外层容器，面板 id 一个不能少（JS 全靠它们）
      for (final id in <String>[
        'dbg-bps',
        'dbg-routes',
        'dbg-saved',
        'dbg-stack',
        'dbg-vars',
        'dbg-eval-out',
        'dbg-src-code',
        'dbg-out',
      ]) {
        expect(html.contains('id="$id"'), isTrue, reason: id);
      }
      // 固定 max-height 改由 flex 分配（面板自己滚），矮窗口另有回退
      expect(html.contains('id="dbg-vars" class="dbg-list" style="max-height'), isFalse);
      expect(html.contains('id="dbg-stack" class="dbg-list" style="max-height'), isFalse);
      expect(html.contains('@media (max-height:840px)'), isTrue);
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

    test('断点卡片接上当前会话的路由栈（文件 → 源码面板 / IDE 跳转）', () {
      const html = gui.guiHtml;
      for (final fn in <String>[
        'id="dbg-routes"',
        'id="dbg-rt-n"',
        'function dbgRtLoad(',
        'function dbgRtLocate(',
        '/api/routestack?uri=',
        '/api/routelocate?uri=',
        'function dbgSrcOpenAt(',
        'dbgIdeJump(j, file, line)',
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
      // 行尾只留「跳转」：原先那个「断点」按钮已去掉（用户要求），
      // 要下断点就点文件名开下方源码面板再点行号。
      expect(html.contains('id="dbg-rtb-'), isFalse);
      expect(html.contains('dbgQuickBp(file, line, dbgSt.wsUri)'), isFalse);
      // 函数本身还要留着：异常 / 网络 Tab 的「一键下断点」在用。
      expect(html.contains('function dbgQuickBp('), isTrue);
      // 只认当前调试会话：没连会话时不能去拿页头 VM 下拉的 uri。
      expect(html.contains('先连上调试会话（启动 / 接入），再点刷新'), isTrue);
      // dbgSt.wsUri 是 flutter run 输出的 http 形态，直连 VM 的接口入口必须归一，
      // 否则点刷新会报 WebSocketException: Unsupported URL scheme 'http'。
      // 归一在后端 _SandboxRpc（不在 guiHtml 里），所以读源码断言。
      final src = File('bin/ide_gui.dart').readAsStringSync();
      expect(src.contains('uri = normalizeVmUri(uri)'), isTrue);
    });

    test('断点 / 路由栈 / 已记住三处文件后面接上 IDE 跳转', () {
      const html = gui.guiHtml;
      for (final fn in <String>[
        'function dbgIdeJump(',
        'function dbgIdeJumpEl(',
        'function escAttr(',
        '/api/openide?file=',
        // 定位成功才知道路径，占位链接先隐藏。
        "id=\"dbg-rtj-' + k + '\"",
        'dbgIdeJump(j, file, line)',
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
      // 断点列表 / 已记住 / 全部项目三处走同一个行内入口。
      expect('dbgIdeJumpEl(this)'.allMatches(html).length, greaterThanOrEqualTo(3));
      // 落盘清单存的是相对项目根的 path，IDE 要绝对路径。
      expect(html.contains('b.absPath || p'), isTrue);
      expect(html.contains('b.absPath || bp'), isTrue);
      // 打开通道复用既有后端（按 ideOrder 走），所以读源码确认。
      final src = File('bin/ide_gui.dart').readAsStringSync();
      expect(src.contains("path == '/api/openide'"), isTrue);
      expect(src.contains('for (final ide in _guiIdeOrder())'), isTrue);
    });

    test('已记住的断点能启用 / 停用（不是只标一个「停用」）', () {
      const html = gui.guiHtml;
      for (final fn in <String>[
        'function dbgSavedBpToggleHtml(',
        'function dbgSavedBpToggle(',
        "dbgOp('enableSavedBreakpoint'",
        'onclick="dbgSavedBpToggle(this)"',
        // 停用态给的是「启用」；启用态给的是「停用」。
        "(off ? '启用' : '停用')",
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
      // 当前项目清单与「全部项目」总览各要带自己的项目根（没连会话也能改）。
      expect(html.contains('dbgSavedBpToggleHtml(dir, abs, b)'), isTrue);
      expect(html.contains('dbgSavedBpToggleHtml(dir, babs, b)'), isTrue);
      // 两种视图改完各重拉各的。
      expect(html.contains('if (dbgSavedAllMode) dbgShowAllSaved(null); else dbgLoadSaved();'),
          isTrue);
      // 后端得真的支持这个 op，否则点了只会报「未知操作」。
      final hub = File('bin/src/debug/debug_hub.dart').readAsStringSync();
      expect(hub.contains("case 'enableSavedBreakpoint':"), isTrue);
      expect(hub.contains('store.setEnabled(root, rel, line, want'), isTrue);
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

    test('变量行能展开看实例字段（懒加载 getObject）', () {
      const html = gui.guiHtml;
      for (final fn in <String>[
        'function dbgVarHtml(',
        'function dbgVarRowsHtml(',
        'function dbgVarToggle(',
        "dbgOp('getObject'",
        'id="dbg-kids-',
        '没有可见字段（对象可能已被回收，或只有 getter）',
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
      // 换帧 / 刷新调用栈必须重置展开态：objectId 属于上一次暂停。
      expect(html.contains('dbgVarKids = {}; dbgVarOpen = {}; dbgVarObj = {};'),
          isTrue);
      // 后端得真的支持这个 op，否则点箭头只会报「未知操作」。
      final hub = File('bin/src/debug/debug_hub.dart').readAsStringSync();
      expect(hub.contains("case 'getObject':"), isTrue);
    });

    test('求值报错压成一句话，并给拼写 / 对象候选', () {
      const html = gui.guiHtml;
      for (final fn in <String>[
        'function dbgEvalErrHint(',
        'function dbgVarFindMember(',
        'function dbgVarPathExpr(',
        'var h = dbgEvalErrHint(d, expr);',
        // 原文不丢：压成一句后仍能悬停看完整错误。
        'out.title = h.raw;',
        // 两种提示：变量树里反查到的完整表达式 / 后端算的拼写候选。
        'dbgVarFindMember(member)',
        // 提示里的「；试试 …」用全角分号（源码就是这么写的）。
        "'；试试 '",
        "' 没有成员 '",
        // 私有成员（`_count`）不是写错，是表达式读不到；反查出的同名路径正是刚输的。
        "member.charAt(0) === '_'",
        "' 的私有成员 '",
        "sug[i].charAt(0) === '_'",
        // 等于用户输入的建议要丢掉，否则提示自指（「试试 this.controller._count」）。
        'function dbgNormExpr(',
        'dbgNormExpr(alt) !== typed',
        // 后端给的是成员名，要拼回用户那一行才能直接粘（controller.x → controller.y）。
        'function dbgFixTail(',
        'dbgFixTail(expr, member, sug[i])',
        'dbgNormExpr(fixed) === typed',
      ]) {
        expect(html.contains(fn), isTrue, reason: fn);
      }
      // 不再把 VM 那一大段原文直接铺在红字里。
      expect(html.contains('out.textContent = d.error'), isFalse);

      final hub = File('bin/src/debug/debug_hub.dart').readAsStringSync();
      for (final fn in <String>[
        'List<String> evalMemberSuggestions(String error, String? projectRoot)',
        'evalMemberSuggestions(debugErrorText(e), _projectRoot)',
        // 只给 eval：其余 op 的失败不需要拼写候选。
        "final suggest = op == 'eval'",
        "if (suggest.isNotEmpty) 'suggest': suggest,",
        'const _commonMembers = <String>[',
      ]) {
        expect(hub.contains(fn), isTrue, reason: fn);
      }
    });

    test('变量可以按名字筛选（模糊匹配、忽略大小写，未展开的层自动补扫）', () {
      const html = gui.guiHtml;
      for (final s in <String>[
        'id="dbg-var-filter"',
        'id="dbg-var-fstat"',
        'function dbgVarPaint(',
        'function dbgVarFilterOnInput(',
        'function dbgVarFilterClear(',
        // 筛选模式自己的渲染：只留命中项 + 通往它的祖先。
        'function dbgVarMatchHtml(',
        'function dbgVarMark(',
        'dbgVarFilterOnInput()',
        // 筛选态下点 ▶ 才拉一层（用户点才发请求），拉完就地重画。
        'function dbgVarFilterLoad(',
        "onclick=\"dbgVarFilterLoad(\\'",
        'gen !== dbgVarGen',
        'var dbgVarGen = 0;',
        'dbgVarGen++;',
        // 拉过但没有命中项时要说清楚。
        '下面没有名字含',
        // 没展开过的层也要能筛到：输入停下后按 BFS 把整棵树拉下来补扫，
        // 对象数与深度都有上限，到顶要说清楚（否则「0 条」会被当成真没有）。
        'function dbgVarScanStart(',
        'dbgVarScanObjCap',
        'dbgVarScanDepCap',
        'function dbgVarScanAbort(',
        'dbgVarScanSeq++',
        '正在把变量树拉下来',
        "筛选中… 已查 '",
        '达到扫描上限',
        '}, 300);',
        // 只留自己项目里声明的字段：框架 / 依赖库的字段收起计数
        // （`ChangeNotifier._count` 和业务字段同名，不藏就是一片噪音）。
        'id="dbg-var-mine"',
        'function dbgVarMineToggle(',
        'dbgVarMine && v.own === false',
        "' · 隐藏 ' + cnt.hid",
        // 扫描不往框架对象（Element / RenderObject 子树）里钻。
        'dbgVarMine && c.fw',
        'dbgVarMine && v.fw',
        // 筛选结果也要能收起：一份独立的折叠表，不碰普通树的展开态；
        // 收起只影响渲染，命中数仍按整棵算（否则会看到「3 条」变「1 条」）。
        'var dbgVarFold = {};',
        'function dbgVarFoldToggle(',
        'dbgVarFold[path] = dbgVarFold[path] === false;',
        'var folded = dbgVarFold[path] === false;',
        "var shown = folded ? '' : kids;",
        // 命中片段高亮。
        '#dbg-vars mark {',
      ]) {
        expect(html.contains(s), isTrue, reason: s);
      }
      // 顺序：调用栈 → 筛选框 → 变量区。
      final stackAt = html.indexOf('id="dbg-stack"');
      final filterAt = html.indexOf('id="dbg-var-filter"');
      final varsAt = html.indexOf('id="dbg-vars"');
      expect(stackAt, greaterThan(0));
      expect(filterAt, greaterThan(stackAt));
      expect(varsAt, greaterThan(filterAt));
      // 输入筛选词只是重画：防抖窗口里一个请求都不发（否则每敲一个字就
      // getObject 一整棵树）；拉子层只走用户点 ▶ 的 dbgVarFilterLoad，
      // 批量补扫只走防抖后调用的 dbgVarScanStart。
      final paintFrom = html.indexOf('function dbgVarPaint(');
      final paintTo = html.indexOf('function dbgVarFilterLoad(', paintFrom);
      expect(paintFrom, greaterThan(0));
      expect(paintTo, greaterThan(paintFrom));
      final paint = html.substring(paintFrom, paintTo);
      expect(paint.contains('dbgOp('), isFalse);
      // 换帧 / 刷栈要作废在跑的扫描（objectId 属于上一次暂停），顺手清折叠表。
      final renderFrom = html.indexOf('function dbgRenderVars(');
      final render = html.substring(renderFrom, html.indexOf('function dbgVarPaint(', renderFrom));
      expect(render.contains('dbgVarScanAbort()'), isTrue);
      expect(render.contains('dbgVarFold = {};'), isTrue);
      // 后端得把「字段声明在谁的库」「值是不是框架对象」传上来，否则前端分不清噪音。
      final hub = File('bin/src/debug/debug_hub.dart').readAsStringSync();
      expect(hub.contains("if (!v.own) 'own': false,"), isTrue);
      expect(hub.contains("if (v.fw) 'fw': true,"), isTrue);
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

    test('路由栈小节显示 Widget / State / VM / Notifier，点名字开源码面板', () {
      const html = gui.guiHtml;
      for (final s in <String>[
        // 第二行的容器（单独一行，第一行的 文件:行 / 跳转 不动）。
        "+ '<div id=\"dbg-rtc-' + k + '\"",
        'function dbgRtInfo(',
        'function dbgSrcOpenAtEl(',
        '/api/routeinfo?class=',
        'if (d.className) dbgRtInfo(',
        // 名字可点：data-* 带位置，点了就开下面源码面板（与 dbgIdeJumpEl 同一套）。
        'onclick="dbgSrcOpenAtEl(this)"',
        // 名字后的小 ◎ 跳实例 Tab 查对象（复用路由栈 Tab 的入口）。
        // 源码里是拼接出来的 onclick="rtToInstances(\'…\')"，故带反斜杠。
        "onclick=\"rtToInstances(\\'",
        // 找不到源码的降级为灰字，不误报可点。
        '本机项目里没找到',
      ]) {
        expect(html.contains(s), isTrue, reason: s);
      }
      // 位置由 /api/routeinfo 的 loc 提供（只有名字没法开文件）。
      final src = File('bin/ide_gui.dart').readAsStringSync();
      expect(src.contains("'loc': loc,"), isTrue);
      expect(src.contains('Map<String, Map<String, Object?>> _classLocations('),
          isTrue);
      expect(src.contains('int? _classLineOf('), isTrue);
    });

    test('实例 Tab 上部操作区固定在顶部（不随字段树滚动）', () {
      const html = gui.guiHtml;
      for (final s in <String>[
        'id="in-sticky"',
        // main 才是滚动容器，所以用 sticky 而非 fixed；背景要遮住下面的内容。
        '#in-sticky { position:sticky; top:0; z-index:6; background:var(--bg)',
        // 16px 留白从 .page 挪到 sticky 自己身上：否则滚动头 16px 它会先往上挪一下。
        '#page-instances { padding-top:0; }',
        'padding:16px 0 2px;',
        // 两个列表各自限高内滚，多命中 / 多条监听时不会把固定区撑满屏幕。
        '#in-sticky #in-list { max-height:24vh; overflow:auto; }',
        '#in-sticky .inwatch-list { max-height:18vh; overflow:auto; }',
      ]) {
        expect(html.contains(s), isTrue, reason: s);
      }
      // 查找区 / Watch / 实例列表在 sticky 块里，字段树必须在块外（要跟着滚）。
      final stickyAt = html.indexOf('id="in-sticky"');
      final watchAt = html.indexOf('id="in-watch-list"');
      final listAt = html.indexOf('id="in-list"');
      final treeAt = html.indexOf('id="in-tree"');
      expect(stickyAt, greaterThan(0));
      expect(watchAt, greaterThan(stickyAt));
      expect(listAt, greaterThan(watchAt));
      expect(treeAt, greaterThan(listAt));
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

    test('/api/routeinfo 带 loc：类名 → 文件:行（点名字才开得了文件）', () async {
      final dir = Directory.systemTemp.createTempSync('xbume_rtinfo_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/pubspec.yaml').writeAsStringSync('name: demo\n');
      Directory('${dir.path}/lib').createSync();
      final home = '${dir.path}/lib/home_page.dart';
      final ctrls = '${dir.path}/lib/controllers.dart';
      // 可断行的源：HomePage 在 1 行，_HomePageState 在 6 行；
      // Controller 故意放另一个文件（第 3 行），验证会走项目类索引。
      File(home).writeAsStringSync(
        'class HomePage extends XBPage<HomeController> {\n'
        '  @override\n'
        '  State<HomePage> createState() => _HomePageState();\n'
        '}\n'
        '\n'
        'class _HomePageState extends State<HomePage> {\n'
        '  @override\n'
        '  Widget build(BuildContext context) => const SizedBox();\n'
        '}\n',
      );
      File(ctrls).writeAsStringSync(
        '// controllers\n'
        '\n'
        'class HomeController extends ChangeNotifier {}\n',
      );

      final client = HttpClient();
      final Map<String, Object?> d;
      try {
        final req = await client.getUrl(Uri.parse(
          'http://127.0.0.1:$port/api/routeinfo'
          '?class=HomePage&file=${Uri.encodeQueryComponent(home)}',
        ));
        req.headers.set('x-xbume-token', token);
        final resp = await req.close();
        final text = await utf8.decoder.bind(resp).join();
        expect(resp.statusCode, 200, reason: text);
        d = jsonDecode(text) as Map<String, Object?>;
      } finally {
        client.close(force: true);
      }

      expect(d['ok'], isTrue);
      expect(d['state'], '_HomePageState');
      expect(d['cn'], contains('HomeController'));
      // 既有字段一个不少（路由栈 Tab 还在用）。
      expect(d['widget'], 'HomePage');
      expect(d['vm'], isA<List<Object?>>());

      final loc = (d['loc'] as Map).cast<String, Object?>();
      expect(loc.keys,
          containsAll(<String>['HomePage', '_HomePageState', 'HomeController']));
      final w = (loc['HomePage'] as Map).cast<String, Object?>();
      expect(w['file'], home);
      expect(w['line'], 1);
      final st = (loc['_HomePageState'] as Map).cast<String, Object?>();
      expect(st['file'], home);
      expect(st['line'], 6);
      final cn = (loc['HomeController'] as Map).cast<String, Object?>();
      expect(cn['file'], ctrls);
      expect(cn['line'], 3);
    });
  });
}
