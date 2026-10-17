// xb_ume 电脑端 GUI 工具箱（本机 Web GUI）。
//
// 由 `dart run xb_ume:ide --install` 部署到 ~/.xb_ume_ide/ide_gui.dart，
// 与守护脚本 ide.dart 一样零新增依赖、单文件自包含。双击启动器
// （Windows: XBumeGui.bat / macOS: xb_ume_gui.command）或
// `dart run xb_ume:ide --gui` 启动后，本机 HTTP 服务自动打开浏览器页面。
//
// 模块划分（页面 Tab 切换）：
//   1. 设备管理：识别 adb（Android）/ hdc（鸿蒙）/ Xcode 模拟器（iOS 模拟器）
//      / idevice_id（iOS 真机，需 libimobiledevice）连接的设备，可选择；
//   2. 守护进程：状态查询（经 ide.dart 互斥端口 status 协议）、重启、IDE 优先级；
//   3. 日志：选中设备的全量设备日志（logcat / hilog / iOS log stream /
//      idevicesyslog）+ 全部调试会话的 stdout/stderr（flutter run 控制台
//      中 app 输出部分），实时推送、过滤、暂停、清屏、导出。
//
// 后续扩展预留：页面与服务端经 WebSocket 双向通信，消息按 type 区分，
// 可增加 App 消息/文件展示与反向控制（VM service callServiceExtension）。
//
// 用法：
//   dart run xb_ume:ide --install   # 部署本文件并生成启动器
//   dart run xb_ume:ide --gui       # 启动 GUI（等同双击启动器）
//   dart ~/.xb_ume_ide/ide_gui.dart # 直接运行
// ignore_for_file: avoid_print

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// ide.dart 守护进程的互斥端口与协议令牌（双端约定一致）。
const int kDaemonLockPort = 46128;
const String kDaemonStatusToken = 'xbume-ide-status';

/// 与 daemon（bin/ide.dart）约定的安装目录与配置文件名。
const String kInstallDirName = '.xb_ume_ide';
const String kConfigName = 'config.json';

/// GUI 服务端口基数（被占用时向后顺延最多 10 个）。
const int kGuiPortBase = 46129;

/// 容错 UTF-8 解码：logcat 输出、外部 HTTP 响应可能含非法字节序列，
/// 默认 utf8.decoder 遇到会抛 FormatException——且流回调里的异常
/// 不会被 handler 的 try/catch 捕获，直接杀死整个 GUI 进程（曾致闪退）。
const Utf8Codec _lenientUtf8 = Utf8Codec(allowMalformed: true);

/// 日志环形缓冲上限（内存保护）。
const int kMaxBufferLines = 5000;

/// GUI 日志缓冲的存活引用（main 启动时注入）。GuiState 实例是 main 内局部
/// 变量，而自动化断言（assertLog）与 AI 上下文收集是顶层函数，够不到它。
List<Map<String, Object?>> _guiLogBuffer = const [];

final String _home =
    Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';

Future<void> main(List<String> args) async {
  // 兜底：任何流回调/事件循环里的未捕获异常只记日志，不杀进程。
  return runZonedGuarded(() => _mainImpl(args), (e, st) {
    stderr.writeln('[uncaught] $e\n$st');
  });
}

Future<void> _mainImpl(List<String> args) async {
  HttpServer? server;
  var port = kGuiPortBase;
  for (; port < kGuiPortBase + 10; port++) {
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      break;
    } on SocketException {
      // 端口被占用：若是已有 GUI 实例，打开浏览器后退出（单实例语义）。
      if (await pingGui(port)) {
        print('[xbume-gui] 已有实例运行于端口 $port，打开页面后退出。');
        await openBrowser(port);
        return;
      }
    }
  }
  if (server == null) {
    print('[xbume-gui] 端口 $kGuiPortBase 起 10 个均不可用，退出。');
    exitCode = 1;
    return;
  }
  print('[xbume-gui] GUI 服务已启动: http://127.0.0.1:$port （Ctrl-C 退出）');
  await openBrowser(port);
  final state = GuiState();
  state.start();
  // 顶层自动化函数（assertLog / AI 增量日志上下文）共享同一份日志缓冲
  _guiLogBuffer = state.buffer;
  // 优雅退出：kill（SIGTERM）/Ctrl-C（SIGINT）时先关闭全部 VM 会话连接
  // 再退出。实测：持有流订阅（Stdout/Extension）的连接被硬切断后，
  // DDS 会永久死锁（该会话此后对所有客户端无响应），必须主动 close
  // 让 DDS 清理订阅状态；dispose 加超时兑底，避免 close 握手卡死退出。
  ProcessSignal.sigterm.watch().first.then((_) async {
    try {
      await state.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {}
    exit(0);
  });
  ProcessSignal.sigint.watch().first.then((_) async {
    try {
      await state.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {}
    exit(0);
  });
  try {
    await for (final req in server) {
      unawaited(handleRequest(state, req));
    }
  } finally {
    await state.dispose();
  }
}

// ---------------------------------------------------------------------------
// HTTP / WebSocket 路由
// ---------------------------------------------------------------------------

Future<void> handleRequest(GuiState state, HttpRequest req) async {
  final path = req.uri.path;
  try {
    if (path == '/ping') {
      req.response.write('xbume-gui');
      await req.response.close();
      return;
    }
    if (path == '/') {
      // 页面禁缓存：GUI 迭代频繁，避免浏览器磁盘缓存拿到旧版 HTML/JS
      req.response.headers.set('Cache-Control', 'no-store');
      req.response.headers.contentType = ContentType.html;
      req.response.write(guiHtml);
      await req.response.close();
      return;
    }
    if (path == '/view' || path == '/tail') {
      // 文件查看/监听独立页（新标签页打开，见沙盒 Tab 的「查看」「监听」按钮）。
      req.response.headers.contentType = ContentType.html;
      req.response.write(fileViewerPageHtml(path == '/tail' ? 'tail' : 'view'));
      await req.response.close();
      return;
    }
    if (path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      state.addClient(ws);
      return;
    }
    if (path == '/api/daemon') {
      final status = await queryDaemonStatus();
      // 合并 GUI 侧解析的应用包名（daemon 只知道 uri/source，不知道应用名）。
      final sessions = ((status?['sessions'] as List?) ?? <Object?>[]).map((s) {
        if (s is Map) {
          final uri = s['uri']?.toString();
          final app = uri == null ? null : state.appNameFor(uri);
          if (app != null && app.isNotEmpty) {
            return <String, Object?>{...s, 'app': app};
          }
        }
        return s;
      }).toList();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{
        'running': status != null,
        'pid': status?['pid'],
        'uptimeSec': status?['uptimeSec'],
        'sessions': sessions,
        'config': readGuiIdeOrder(),
      }));
      await req.response.close();
      return;
    }
    if (path == '/api/daemon/restart' && req.method == 'POST') {
      final result = await restartDaemon();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(result));
      await req.response.close();
      return;
    }
    if (path == '/api/openconfig' && req.method == 'POST') {
      await openWithSystemApp('$_home/.xb_ume_ide/config.json');
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();
      return;
    }
    if (path == '/api/ideorder' && req.method == 'GET') {
      // 进入「守护进程」页时调用：扫描已安装 IDE，新装的自动追加到配置
      // 末尾并写回（只追加，不删已卸载的，daemon 唤起时自会跳过）。
      try {
        final installed = await scanInstalledIdes();
        final merged = readGuiIdeOrderList();
        final added = <String>[];
        for (final ide in installed) {
          if (merged.contains(ide)) continue;
          // 等价别名：规范名（或别名）已在配置中则不追加，避免同一
          // 应用以两个 CLI 名重复出现。
          final canonical = _guiEquivalentIdes[ide];
          final aliasOf = _guiEquivalentIdes.entries
              .where((e) => e.value == ide)
              .map((e) => e.key)
              .toSet();
          if ((canonical != null && merged.contains(canonical)) ||
              aliasOf.any(merged.contains)) {
            continue;
          }
          merged.add(ide);
          added.add(ide);
        }
        // 清理与规范名共存的别名（同一应用重复出现，如旧配置或早前
        // 版本扫描写入的）。
        final removed = merged
            .where((ide) =>
                _guiEquivalentIdes[ide] != null &&
                merged.contains(_guiEquivalentIdes[ide]!))
            .toList();
        if (removed.isNotEmpty) {
          merged.removeWhere((ide) => removed.contains(ide));
        }
        if (added.isNotEmpty || removed.isNotEmpty) {
          await writeGuiIdeOrder(merged);
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{
            'ok': true,
            'order': merged,
            'installed': installed,
            'added': added,
            'removed': removed,
          }),
        );
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': false, 'message': '$e'}),
        );
      }
      await req.response.close();
      return;
    }
    if (path == '/api/ideorder' && req.method == 'POST') {
      try {
        // HttpRequest 是 Stream<Uint8List>，与 Utf8Decoder（List<int>）
        // 泛型不兼容，先收集字节再容错解码。
        final bodyBytes = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        final body = _lenientUtf8.decode(bodyBytes);
        final decoded = jsonDecode(body);
        final raw = decoded is Map ? decoded['ideOrder'] : null;
        final order = (raw is List ? raw : <Object?>[])
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (order.isEmpty) throw 'ideOrder 不能为空';
        // 名单内的名字可直接写；不在名单但原配置已有的（用户手动编辑过
        // config.json）也保留，避免覆盖丢失。
        final existing = readGuiIdeOrderList().toSet();
        final invalid = order
            .where((e) =>
                !_guiDefaultIdeOrder.contains(e) && !existing.contains(e))
            .toList();
        if (invalid.isNotEmpty) {
          throw '不支持的 IDE 名称：${invalid.join(', ')}'
              '（可用：${_guiDefaultIdeOrder.join(', ')}）';
        }
        await writeGuiIdeOrder(order);
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': true, 'ideOrder': order}),
        );
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': false, 'message': '$e'}),
        );
      }
      await req.response.close();
      return;
    }
    if (path == '/api/logs.txt') {
      req.response.headers.contentType = ContentType.text;
      req.response.headers.set(
        'Content-Disposition',
        'attachment; filename="xbume-logs.txt"',
      );
      for (final entry in state.buffer) {
        final ts = entry['ts'];
        final time = (ts is String && ts.isNotEmpty) ? ts : entry['rcv'];
        req.response.write(
          '$time [${entry['source']}] '
          '${entry['level']}/${entry['app'] ?? entry['tag']}: ${entry['msg']}\n',
        );
      }
      await req.response.close();
      return;
    }
    // -- 路由栈 -------------------------------------------------------------
    // 经 VM service evaluate 在 app 进程内读取 Navigator 路由栈（debug 模式可用）。
    if (path == '/api/routestack') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      if (uri.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        // 单行 IIFE（VM eval 对多行 IIFE 会返回未调用的 Closure）。
        // 在 navigator.dart 库上下文执行：可访问 NavigatorState 的私有 _history。
        // Widget/State/ChangeNotifier 名由 /api/routeinfo 静态解析
        // （State 字段 + 同文件 ConsumerN 泛型参数，全部收集）。
        final raw = await rpc.evalStringOn(
          'package:flutter/src/widgets/navigator.dart',
          "(() { final root = WidgetsBinding.instance.renderViewElement; "
          "if (root == null) return 'NO_ROOT'; "
          "final navigators = <NavigatorState>[]; "
          "void walk(Element e) { final w = e.widget; "
          "if (w is Navigator && e is StatefulElement && e.state is NavigatorState) { navigators.add(e.state as NavigatorState); } "
          "e.visitChildren(walk); } "
          "root.visitChildren(walk); "
          "final sb = StringBuffer()..write(navigators.length); "
          "for (var i = 0; i < navigators.length; i++) { "
          "for (final entry in navigators[i]._history) { "
          "final r = entry.route; "
          "final args = r.settings.arguments; "
          "sb..writeln()..write(i)..write('\\t')..write(r.runtimeType.toString())..write('\\t')..write(r.settings.name ?? '')..write('\\t')..write(r.isCurrent ? '1' : '0')..write('\\t')..write(args?.runtimeType.toString() ?? '')..write('\\t')..write(args?.toString().replaceAll('\\t', ' ').replaceAll('\\n', ' ') ?? ''); } } "
          "return sb.toString(); })()",
        );
        final navigators = <Map<String, Object?>>[];
        if (raw != 'NO_ROOT') {
          final lines = raw.split('\n');
          final navCount = int.tryParse(lines.first.trim()) ?? 0;
          for (var i = 0; i < navCount; i++) {
            navigators
                .add(<String, Object?>{'index': i, 'routes': <Object?>[]});
          }
          for (final line in lines.skip(1)) {
            if (line.isEmpty) continue;
            final parts = line.split('\t');
            if (parts.length < 6) continue;
            final navIndex = int.tryParse(parts[0]) ?? -1;
            if (navIndex < 0 || navIndex >= navCount) continue;
            (navigators[navIndex]['routes'] as List).add(<String, Object?>{
              // 栈内顺序即 _history 顺序：首条为栈底，末条为栈顶。
              'type': parts[1].replaceFirst(RegExp(r'<[^>]*>$'), ''),
              'name': parts[2],
              'current': parts[3] == '1',
              'argsType': parts[4],
              'args': parts.sublist(5).join('\t'),
            });
          }
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'navigators': navigators}),
        );
        await req.response.close();
      } catch (e) {
        req.response.statusCode = HttpStatus.badGateway;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      } finally {
        await rpc.close();
      }
      return;
    }
    // -- 路由操作 -------------------------------------------------------------
    // 经 VM service evaluate 在 app 进程内执行 Navigator 操作（debug 可用）：
    // pop 仅限栈顶（走转场）；remove 任意非唯一路由（无转场直接出栈）；
    // push 先经私有 _routeNamed 校验路由名再 push 生成的 Route 对象——
    // 同步完成，名字解析不出立刻返回 UNKNOWN，不会产生悬挂 Future。
    if (path == '/api/routeop' && req.method == 'POST') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final op = req.uri.queryParameters['op'] ?? '';
      final nav = int.tryParse(req.uri.queryParameters['nav'] ?? '0') ?? 0;
      final idx = int.tryParse(req.uri.queryParameters['idx'] ?? '-1') ?? -1;
      final name = req.uri.queryParameters['name'] ?? '';
      if (uri.isEmpty ||
          (op != 'pop' && op != 'remove' && op != 'push') ||
          (op == 'push' && name.isEmpty)) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        // Navigator 收集逻辑与 /api/routestack 一致（单行 IIFE，
        // navigator.dart 库上下文可访问私有 _history）。
        const walk = "final root = WidgetsBinding.instance.renderViewElement; "
            "if (root == null) return 'NO_ROOT'; "
            "final navigators = <NavigatorState>[]; "
            "void walk(Element e) { final w = e.widget; "
            "if (w is Navigator && e is StatefulElement && e.state is NavigatorState) { navigators.add(e.state as NavigatorState); } "
            "e.visitChildren(walk); } "
            "root.visitChildren(walk); ";
        String expr;
        switch (op) {
          case 'pop':
            expr = "(() { $walk"
                "if ($nav < 0 || $nav >= navigators.length) return 'BAD_NAV'; "
                "final h = navigators[$nav]._history; "
                "if ($idx < 0 || $idx >= h.length) return 'BAD_IDX'; "
                "if ($idx != h.length - 1) return 'NOT_TOP'; "
                "navigators[$nav].pop(); return 'OK'; })()";
          case 'remove':
            expr = "(() { $walk"
                "if ($nav < 0 || $nav >= navigators.length) return 'BAD_NAV'; "
                "final h = navigators[$nav]._history; "
                "if ($idx < 0 || $idx >= h.length) return 'BAD_IDX'; "
                // 栈里只剩一条（初始路由）时不允许移除，避免整窗白屏。
                "if (h.length <= 1) return 'LAST_ROUTE'; "
                "navigators[$nav].removeRoute(h[$idx].route); return 'OK'; })()";
          default: // push（入口已校验 name 非空）
            final escName = _escEvalString(name);
            expr = "(() { $walk"
                "if ($nav < 0 || $nav >= navigators.length) return 'BAD_NAV'; "
                // 未配置路由表的 Navigator（如纯面板容器）不支持命名路由。
                "if (navigators[$nav].widget.onGenerateRoute == null) return 'NO_ROUTE_TABLE'; "
                "try { final r = navigators[$nav]._routeNamed('$escName', arguments: null); "
                "if (r == null) return 'UNKNOWN'; "
                "navigators[$nav].push(r); return 'OK'; "
                "} catch (e) { return 'ERR:' + e.runtimeType.toString(); } })()";
        }
        final reply = await rpc.evalStringOn(
          'package:flutter/src/widgets/navigator.dart',
          expr,
        );
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': true, 'result': reply}),
        );
        await req.response.close();
      } catch (e) {
        req.response.statusCode = HttpStatus.badGateway;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      } finally {
        await rpc.close();
      }
      return;
    }
    // ── 内存泄漏检测：退出页 State → GC → 树上/堆上双计数 ──
    // 判定在 app 进程外做：不在路由栈中但堆上仍有实例的 State 即疑似泄漏
    //（静态变量/监听器/动画/全局 key 等持有）。树上计数与堆计数分开，
    // 供前端区分「栈中正常存活」与「疑似泄漏」。
    if (path == '/api/leakcheck' && req.method == 'POST') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final classes = (req.uri.queryParameters['classes'] ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet();
      if (uri.isEmpty || classes.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        final iso = await rpc.isolateId();
        // 先 GC：清掉退出页面短暂残留的待回收实例，避免误报。
        try {
          await rpc.rawRpc('_collectAllGarbage', {'isolateId': iso});
        } catch (_) {}
        // 树上计数：树上存活的 State（在栈中页面的正常存活形态）。
        // 返回数字字符串；NO_ROOT 表示 app 尚未首帧。
        Future<int> treeCount(String cls) async {
          final walkExpr = "(() { final root = WidgetsBinding.instance"
              ".renderViewElement; if (root == null) return 'NO_ROOT'; "
              "var n = 0; void walk(Element e) { "
              "final s = e is StatefulElement ? e.state : null; "
              "if (s != null && s.runtimeType.toString() == '$cls') { n++; } "
              "e.visitChildren(walk); } root.visitChildren(walk); "
              "return n.toString(); })()";
          final r = await rpc.evalStringOn(
              'package:flutter/src/widgets/navigator.dart', walkExpr);
          if (r == 'NO_ROOT') return 0;
          return int.tryParse(r) ?? 0;
        }
        // 一次 getClassList：类名 → classId 列表（与实例 Tab 堆扫描同款匹配，
        // 含 '.类名' 后缀的同类变体）。注意 getClassList 返回的类名不带泛型
        // 实参（泛型类是 _FooState 而实例 runtimeType 是 _FooState<T>），
        // 而前端传来的类名来自静态解析，可能带泛型后缀 → 剥掉再匹配。
        String stripGenerics(String cls) {
          final lt = cls.indexOf('<');
          return lt > 0 ? cls.substring(0, lt) : cls;
        }
        final classList = await rpc.rawRpc('getClassList', {'isolateId': iso});
        final idsByCls = <String, List<String>>{};
        for (final c in (classList['classes'] as List? ?? <Object?>[])) {
          if (c is! Map) continue;
          final name = c['name']?.toString() ?? '';
          for (final cls in classes) {
            final bare = stripGenerics(cls);
            if (name == bare || name.endsWith('.$bare')) {
              (idsByCls[cls] ??= <String>[]).add(c['id']?.toString() ?? '');
            }
          }
        }
        final items = <Map<String, Object?>>[];
        for (final cls in classes) {
          var tree = 0;
          try {
            tree = await treeCount(cls);
          } catch (_) {}
          var heap = 0;
          for (final classId in (idsByCls[cls] ?? const <String>[])) {
            if (classId.isEmpty) continue;
            try {
              // 只计数量不摊实例：limit=1 + totalCount（total 是堆上全部存活数）。
              final set = await rpc.rawRpc('getInstances', {
                'isolateId': iso,
                'objectId': classId,
                'limit': 1,
              });
              final tc = set['totalCount'];
              heap += tc is int
                  ? tc
                  : (set['instances'] as List? ?? const <Object?>[]).length;
            } catch (_) {}
          }
          items.add(<String, Object?>{'cls': cls, 'tree': tree, 'heap': heap});
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': true, 'items': items}),
        );
        await req.response.close();
      } catch (e) {
        req.response.statusCode = HttpStatus.badGateway;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      } finally {
        await rpc.close();
      }
      return;
    }
    // ── 状态面板：ChangeNotifier 类聚合（实例数/监听者数/字段摘要/跳实例）──
    // 候选类来源：① Element 树上挂着的 CN（State 本身是 ChangeNotifier 的）
    // ② 手动输入类名。对每个类：堆扫描计实例数（totalCount），取第一个实例
    // getObject 解析 _listeners（实际监听者 = 非 Null 元素数，老实现用 _count）
    // 与字段摘要。
    if (path == '/api/status/cn') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final manual = (req.uri.queryParameters['classes'] ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet();
      if (uri.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        final iso = await rpc.isolateId();
        final candidates = <String>{...manual};
        // ① 树上候选（显式栈，递归闭包在 VM eval 中不可靠）：
        //    - State 本身是 ChangeNotifier（直接入选）；
        //    - runtimeType 带泛型实参的（如 XBWidgetState<ChoosePageVM>，
        //      CN 藏在泛型实参里是常见持有形态）→ 提取实参名，后面统一校验。
        final toVerify = <String>{};
        try {
          const cnExpr = "(() { final root = WidgetsBinding.instance"
              ".renderViewElement; if (root == null) return 'NO_ROOT'; "
              "final stack = <Element>[root]; final names = <String>[]; "
              "while (stack.isNotEmpty && names.length < 80) { final e = stack.removeLast(); "
              "final s = e is StatefulElement ? e.state : null; "
              "if (s != null && (s is ChangeNotifier || "
              "s.runtimeType.toString().contains('<'))) { "
              "names.add(s.runtimeType.toString()); } "
              "e.visitChildren(stack.add); } "
              "return names.join('|'); })()";
          final r = await rpc.evalStringOn(
              'package:flutter/src/widgets/navigator.dart', cnExpr);
          if (r != 'NO_ROOT') {
            for (final n in r.split('|')) {
              if (n.isEmpty) continue;
              if (n.contains('<')) {
                final inner = n.substring(n.indexOf('<') + 1, n.lastIndexOf('>'));
                for (final part in inner.split(',')) {
                  final p = part.trim();
                  if (p.isNotEmpty &&
                      !p.contains('<') &&
                      RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(p)) {
                    toVerify.add(p);
                  }
                }
              } else {
                candidates.add(n);
              }
            }
          }
        } catch (_) {}
        String stripGenerics(String cls) {
          final lt = cls.indexOf('<');
          return lt > 0 ? cls.substring(0, lt) : cls;
        }
        final items = <Map<String, Object?>>[];
        if (candidates.isNotEmpty || toVerify.isNotEmpty) {
          final classList =
              await rpc.rawRpc('getClassList', {'isolateId': iso});
          // ChangeNotifier 基类 id：泛型实参候选沿 super 链校验是否真为 CN
          //（GetBuilderState<GetMaterialController> 之类的非 CN 实参要拦掉）。
          String? cnBaseId;
          final idByCls = <String, String>{};
          for (final c in (classList['classes'] as List? ?? <Object?>[])) {
            if (c is! Map) continue;
            final name = c['name']?.toString() ?? '';
            idByCls[name] = c['id']?.toString() ?? '';
            if (name == 'ChangeNotifier') cnBaseId = c['id']?.toString();
          }
          if (cnBaseId != null && cnBaseId.isNotEmpty) {
            for (final cls in toVerify) {
              var id = idByCls[stripGenerics(cls)];
              var hops = 0;
              while (id != null && id.isNotEmpty && hops < 12) {
                if (id == cnBaseId) {
                  candidates.add(cls);
                  break;
                }
                try {
                  final c = await rpc.rawRpc('getObject', {
                    'isolateId': iso,
                    'objectId': id,
                  });
                  final sup = c['super'] as Map?;
                  id = sup?['id']?.toString();
                } catch (_) {
                  break;
                }
                hops++;
              }
            }
          }
          final idsByCls = <String, List<String>>{};
          for (final c in (classList['classes'] as List? ?? <Object?>[])) {
            if (c is! Map) continue;
            final name = c['name']?.toString() ?? '';
            for (final cls in candidates) {
              final bare = stripGenerics(cls);
              if (name == bare || name.endsWith('.$bare')) {
                (idsByCls[cls] ??= <String>[]).add(c['id']?.toString() ?? '');
              }
            }
          }
          for (final cls in candidates) {
            var count = 0;
            var instId = '';
            for (final classId in (idsByCls[cls] ?? const <String>[])) {
              if (classId.isEmpty) continue;
              try {
                final set = await rpc.rawRpc('getInstances', {
                  'isolateId': iso,
                  'objectId': classId,
                  'limit': 1,
                });
                final tc = set['totalCount'];
                count += tc is int
                    ? tc
                    : (set['instances'] as List? ?? const <Object?>[]).length;
                if (instId.isEmpty &&
                    (set['instances'] as List? ?? const <Object?>[]).isNotEmpty) {
                  instId =
                      ((set['instances'] as List).first as Map)['id']?.toString() ?? '';
                }
              } catch (_) {}
            }
            // 代表性实例（第一个）：监听者数 + 字段摘要。同类的多实例状态可能
            // 不同，此处取首个供快速诊断，展开看全量请跳「实例」Tab。
            var listeners = -1;
            final fieldsPreview = <String>[];
            if (instId.isNotEmpty) {
              try {
                final obj = await rpc.rawRpc('getObject', {
                  'isolateId': iso,
                  'objectId': instId,
                });
                for (final f in (obj['fields'] as List? ?? <Object?>[])) {
                  if (f is! Map) continue;
                  final fname =
                      ((f['decl'] as Map?)?['name'] ?? '').toString();
                  final v = f['value'];
                  if (v is! Map) continue;
                  if (fname == '_listeners') {
                    // 实际监听者 = 非 Null 元素数（老实现 _listeners 定长槽填充 null）。
                    try {
                      final l = await rpc.rawRpc('getObject', {
                        'isolateId': iso,
                        'objectId': v['id']?.toString() ?? '',
                      });
                      listeners = (l['elements'] as List? ?? <Object?>[])
                          .where((e) =>
                              e is Map &&
                              (e['class'] as Map?)?['name']?.toString() != 'Null')
                          .length;
                    } catch (_) {
                      listeners = -1;
                    }
                  } else if (fname == '_count') {
                    final n = int.tryParse(v['valueAsString']?.toString() ?? '');
                    if (n != null && listeners < 0) listeners = n;
                  }
                  if (fieldsPreview.length < 8 &&
                      fname != '_listeners' &&
                      fname != '_count' &&
                      // ChangeNotifier 内部机制字段对诊断无信息量，不入摘要。
                      !const {
                        '_notificationCallStackDepth',
                        '_reentrantlyRemovedListeners',
                        '_debugDisposed',
                        '_creationDispatched',
                        '_debugCreator',
                      }.contains(fname)) {
                    var preview = v['valueAsString']?.toString() ??
                        (v['class'] as Map?)?['name']?.toString() ?? '?';
                    if (preview.length > 48) preview = preview.substring(0, 48);
                    fieldsPreview.add('$fname=$preview');
                  }
                }
              } catch (_) {}
            }
            items.add(<String, Object?>{
              'cls': cls,
              'count': count,
              'listeners': listeners,
              'fields': fieldsPreview,
              'instId': instId,
              'src': manual.contains(cls) ? '手动' : '树上',
            });
          }
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': true, 'items': items}),
        );
        await req.response.close();
      } catch (e) {
        req.response.statusCode = HttpStatus.badGateway;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      } finally {
        await rpc.close();
      }
      return;
    }
    // -- 路由的 State / ChangeNotifier 解析 ---------------------------------
    // 纯静态解析（不再连 VM）：routelocate 已定位到路由子树中第一个用户
    // widget 类的源文件，State 名取该类 createState() 的返回类型；
    // ChangeNotifier 名取 State 字段里第一个沿 extends 链能到
    // ChangeNotifier 的类型（仅搜本机项目源码，框架类型自然跳过）。
    if (path == '/api/routeinfo') {
      final file = req.uri.queryParameters['file'] ?? '';
      final cls = req.uri.queryParameters['class']?.trim() ?? '';
      if (file.isEmpty ||
          cls.isEmpty ||
          !File(file).existsSync()) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      String state = '';
      List<String> cnList = const <String>[];
      try {
        (state, cnList) = _routeStateAndNotifier(file, cls);
      } catch (_) {}
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{
        'ok': true,
        'widget': cls,
        'state': state,
        'cn': cnList,
      }));
      await req.response.close();
      return;
    }
    // -- 路由跳转定位 -------------------------------------------------------
    // 点击路由栈条目 → 找到该路由子树中第一个用户代码 Widget 类 → 解析
    // 本机源文件 → 用配置的 IDE 打开（优先级与 daemon 的 IDE 跳转一致）。
    if (path == '/api/routelocate') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final nav = int.tryParse(req.uri.queryParameters['nav'] ?? '') ?? -1;
      final idx = int.tryParse(req.uri.queryParameters['idx'] ?? '') ?? -1;
      // open=0：仅解析文件（路由栈「文件」列预填用），不唤起 IDE。
      final open = req.uri.queryParameters['open'] != '0';
      if (uri.isEmpty || nav < 0 || idx < 0) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      Future<void> fail(Object e, {int code = HttpStatus.badGateway}) async {
        req.response.statusCode = code;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      }

      final rpc = _SandboxRpc(uri);
      try {
        // 第 1 步：收集该路由子树的候选 widget（浅→深；单行 IIFE）。
        final expr =
            "(() { final root = WidgetsBinding.instance.renderViewElement; "
            "if (root == null) return 'NO_ROOT'; "
            "final navigators = <NavigatorState>[]; "
            "void walkN(Element e) { final w = e.widget; "
            "if (w is Navigator && e is StatefulElement && e.state is NavigatorState) { navigators.add(e.state as NavigatorState); } "
            "e.visitChildren(walkN); } "
            "root.visitChildren(walkN); "
            "if ($nav < 0 || $nav >= navigators.length) return 'BAD_NAV'; "
            "if ($idx < 0 || $idx >= navigators[$nav]._history.length) return 'BAD_IDX'; "
            "final route = navigators[$nav]._history[$idx].route; "
            "final cands = <Widget>[]; "
            "void walk(Element e) { if (identical(ModalRoute.of(e), route)) cands.add(e.widget); "
            "e.visitChildren(walk); } "
            "root.visitChildren(walk); "
            "return cands.length > 250 ? cands.sublist(0, 250) : cands; })()";
        final libId = await rpc
            .libraryId('package:flutter/src/widgets/navigator.dart');
        final isoId = await rpc.isolateId();
        final listRes = await rpc.rawRpc('evaluate', {
          'isolateId': isoId,
          'targetId': libId,
          'expression': expr,
        });
        final listKind = listRes['kind']?.toString();
        if (listKind == 'String') {
          // NO_ROOT / BAD_NAV / BAD_IDX：直接作为错误提示。
          throw listRes['valueAsString']?.toString() ?? '定位失败';
        }
        if (listKind != 'List') {
          throw '候选收集失败（kind=$listKind）';
        }
        final listId = listRes['id']?.toString();
        if (listId == null || listId.isEmpty) {
          throw '候选列表引用无效';
        }

        // 第 2 步：从 isolate 的 file:/// 库提取项目根，预加载包路径表。
        final iso = await rpc.rawRpc('getIsolate', {'isolateId': isoId});
        final fileUris = ((iso['libraries'] as List? ?? <Object?>[])
                .whereType<Map>()
                .map((l) => l['uri']?.toString() ?? '')
                .where((u) => u.startsWith('file:///'))
                .toList())
            .cast<String>();
        final projectRoot = _projectRootFor(fileUris);
        if (projectRoot != null) {
          _pkgRootsFor(projectRoot);
        }

        // 第 3 步：逐个候选查类定义库，取第一个能解析到本机文件的用户类。
        final listObj = await rpc.rawRpc('getObject', {
          'isolateId': isoId,
          'objectId': listId,
        });
        final elements =
            (listObj['elements'] as List? ?? <Object?>[]).whereType<Map>();
        var scanned = 0;
        var framework = 0;
        for (final el in elements) {
          if (scanned >= 250) break;
          scanned++;
          final cls = el['class'];
          final clsId = cls is Map ? cls['id']?.toString() : null;
          final clsName = cls is Map ? cls['name']?.toString() ?? '' : '';
          if (clsId == null || clsId.isEmpty) continue;
          Map<String, Object?>? classObj;
          try {
            final res = await rpc.rawRpc('getObject', {
              'isolateId': isoId,
              'objectId': clsId,
            });
            classObj = res;
          } catch (_) {
            continue; // 类可能已被回收（Sentinel）。
          }
          final libUri =
              ((classObj['library'] as Map?)?['uri'] ?? '').toString();
          if (libUri.startsWith('dart:') ||
              libUri.startsWith('package:flutter/')) {
            framework++;
            continue;
          }
          final file = _resolveLibraryFile(libUri);
          if (file == null) continue; // 该用户库不在本机（如仅发布包），试下一个。
          final line = _findClassDeclLine(file, clsName);
          String? ideError;
          if (open) ideError = await _guiLaunchIde(file, line);
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, Object?>{
              'file': file,
              'line': line,
              'className': clsName,
              if (ideError != null) 'message': ideError,
            }),
          );
          await req.response.close();
          return;
        }
        throw scanned == 0
            ? '未找到该路由的页面元素（路由可能尚未构建完成）'
            : '无法定位：${scanned - framework} 个用户类均未解析到本机文件（依赖包可能不在本机）';
      } catch (e, st) {
        stderr.writeln('[routelocate] $e\n$st');
        await fail(e);
      } finally {
        await rpc.close();
      }
      return;
    }
    // -- Network（手机端 ume Network 模块同源数据）---------------------------
    // 在 xb_ume core 库上下文 eval 读 XBUme.controller.network（同步 getter）。
    // 结构化串约定：字段间 \u0001，键值间 \u0003，条目间 \u0004。
    if (path == '/api/network' ||
        path == '/api/network/detail' ||
        path == '/api/network/clear' ||
        path == '/api/network/replay') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final id = req.uri.queryParameters['id'] ?? '';
      if (uri.isEmpty ||
          (path != '/api/network' && path != '/api/network/clear' && id.isEmpty)) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      Future<void> fail(Object e, {int code = HttpStatus.badGateway}) async {
        req.response.statusCode = code;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      }

      final rpc = _SandboxRpc(uri);
      try {
        // 校验 xb_ume core 库可达（未接入 xb_ume 的 app 会在此报错）。
        await rpc.libraryId('package:xb_ume/src/core/xb_ume.dart');
        Future<String> evalNet(String inner) => rpc.evalStringOn(
          'package:xb_ume/src/core/xb_ume.dart',
          "(() { $inner })()",
        );

        if (path == '/api/network') {
          final raw = await evalNet(
            "final n = XBUme.controller.network; "
            "return n.map((e) => [e.id, e.time.toIso8601String(), e.method, e.url, "
            "(e.statusCode ?? '').toString(), (e.durationMs ?? '').toString(), "
            "e.status.name, e.error ?? ''].join('\\u0001')).join('\\u0002'); ",
          );
          final items = <Map<String, Object?>>[];
          for (final line in raw.split('\u0002')) {
            if (line.isEmpty) continue;
            final p = line.split('\u0001');
            if (p.length < 8) continue;
            items.add(<String, Object?>{
              'id': p[0], 'time': p[1], 'method': p[2], 'url': p[3],
              'statusCode': p[4], 'durationMs': p[5], 'status': p[6], 'error': p[7],
            });
          }
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'items': items.reversed.toList()}));
          await req.response.close();
          return;
        }
        if (path == '/api/network/clear') {
          await evalNet('XBUme.controller.clearNetwork(); return \'ok\'; ');
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'ok': true}));
          await req.response.close();
          return;
        }
        // detail / replay 共用：结构化拉取单条请求的全部字段。
        // 库上下文必须是 core/xb_ume.dart（XBUme 可见）。Map/List 不能用
        // Dart Map.toString()（键无引号非 JSON，前端 diff/预览解析不了），
        // 又不能 jsonEncode（该库没 import dart:convert，而 XBUme 只在此库
        // 可见）→ 表达式内手写最小 JSON 序列化（q/js，用 fromCharCode 避免
        // 三层转义地狱）。
        Future<Map<String, Object?>?> fetchItem() async {
          const jsHelpers = "String q(String s) { final dq = "
              "String.fromCharCode(34); final bs = String.fromCharCode(92); "
              "final out = StringBuffer(dq); "
              "for (final c in s.codeUnits) { "
              "if (c == 34) { out.write(bs + dq); } "
              "else if (c == 92) { out.write(bs + bs); } "
              "else if (c == 10) { out.write(bs + 'n'); } "
              "else if (c == 13) { out.write(bs + 'r'); } "
              "else if (c == 9) { out.write(bs + 't'); } "
              "else if (c < 32) { out.write(bs + 'u00' + c.toRadixString(16).padLeft(2, '0')); } "
              "else { out.writeCharCode(c); } } "
              "out.write(dq); return out.toString(); } "
              "String js(Object? v) { if (v == null) return 'null'; "
              "if (v is num || v is bool) return v.toString(); "
              "if (v is String) return q(v); "
              "if (v is Map) { return '{' + v.entries.map((en) => q(en.key.toString()) + ':' + js(en.value)).join(',') + '}'; } "
              "if (v is Iterable) { return '[' + v.map(js).join(',') + ']'; } "
              "return q(v.toString()); } "
              "String toS(Object? v) => v == null ? '' : "
              "(v is Map || v is List ? js(v) : v.toString()); ";
          final raw = await evalNet(
            "$jsHelpers"
            "XBUmeNetworkItem? e; "
            "for (final it in XBUme.controller.network) { if (it.id == '$id') { e = it; break; } } "
            "if (e == null) return 'NOT_FOUND'; "
            "String kv(Map<String, dynamic>? m) => m == null ? '' : "
            "m.entries.map((en) => en.key + '\u0003' + en.value.toString()).join('\u0004'); "
            "return [kv(e.queryParameters), kv(e.requestHeaders), toS(e.requestBody), "
            "kv(e.responseHeaders), toS(e.responseBody), e.stack ?? ''].join('\u0001'); ",
          );
          if (raw == 'NOT_FOUND') return null;
          final p = raw.split('\u0001');
          List<Map<String, String>> parseKv(String s) => s.isEmpty
              ? <Map<String, String>>[]
              : s
                  .split('\u0004')
                  .map((e) {
                    final i = e.indexOf('\u0003');
                    return <String, String>{
                      'k': i < 0 ? e : e.substring(0, i),
                      'v': i < 0 ? '' : e.substring(i + 1),
                    };
                  })
                  .toList();
          return <String, Object?>{
            'query': parseKv(p.isNotEmpty ? p[0] : ''),
            'requestHeaders': parseKv(p.length > 1 ? p[1] : ''),
            'requestBody': p.length > 2 ? p[2] : '',
            'responseHeaders': parseKv(p.length > 3 ? p[3] : ''),
            'responseBody': p.length > 4 ? p[4] : '',
            'stack': p.length > 5 ? p[5] : '',
          };
        }
        if (path == '/api/network/detail') {
          final item = await fetchItem();
          if (item == null) throw '请求不存在（可能已被清除）';
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(item));
          await req.response.close();
          return;
        }
        // replay：GUI 端直接按原 method/url/headers/body 发起 HTTP 请求。
        // 先拿 method 与 url（列表里没带，单独 eval）。
        // POST JSON body 可覆盖 url/headers/body（详情页「编辑重放」）；
        // GET query（原「重发」）不含 body，保持原样。
        Map<String, Object?>? edit;
        if (req.method == 'POST') {
          final raw = await utf8.decoder.bind(req).join();
          if (raw.isNotEmpty) edit = jsonDecode(raw) as Map<String, Object?>;
        }
        final mu = await evalNet(
          "XBUmeNetworkItem? e; "
          "for (final it in XBUme.controller.network) { if (it.id == '$id') { e = it; break; } } "
          "if (e == null) return 'NOT_FOUND'; "
          "return e.method + '\u0001' + e.url; ",
        );
        if (mu == 'NOT_FOUND') throw '请求不存在（可能已被清除）';
        final sep = mu.indexOf('\u0001');
        final method = sep < 0 ? 'GET' : mu.substring(0, sep);
        var url = sep < 0 ? mu : mu.substring(sep + 1);
        final item = await fetchItem();
        var headers = <String, String>{
          for (final h in (item?['requestHeaders'] as List? ?? <Map<String, String>>[]))
            if ((h['k'] ?? '').toString().isNotEmpty)
              h['k']!.toString(): h['v']?.toString() ?? '',
        };
        var body = (item?['requestBody'] as String? ?? '');
        if (edit != null) {
          final eu = edit['url']?.toString() ?? '';
          if (eu.isNotEmpty) url = eu;
          final eh = edit['headers'];
          if (eh is Map) {
            headers = {
              for (final e in eh.entries) e.key.toString(): e.value?.toString() ?? '',
            };
          }
          final eb = edit['body'];
          if (eb != null) body = eb.toString();
        }
        final client = HttpClient();
        try {
          final rq = await client.openUrl(method, Uri.parse(url));
          headers.forEach(rq.headers.set);
          if (body.isNotEmpty && method != 'GET' && method != 'HEAD') {
            // 显式设 content-length：否则 dart:io 走 chunked，部分简易服务端
            //（及与原始请求行为不一致）会解析不到 body。
            rq.headers.set(
                'content-length', utf8.encode(body).length.toString());
            rq.add(utf8.encode(body));
          }
          final rs = await rq.close();
          final respBody = await rs.transform(_lenientUtf8.decoder).join();
          // HttpHeaders 不能直接 jsonEncode，手动拍平。
          final respHeaders = <String, List<String>>{};
          rs.headers.forEach((k, v) => respHeaders[k] = v);
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, Object?>{
            'statusCode': rs.statusCode,
            'url': url,
            'headers': respHeaders,
            'body': respBody.length > 200 * 1024
                ? respBody.substring(0, 200 * 1024)
                : respBody,
          }));
          await req.response.close();
          return;
        } finally {
          client.close(force: true);
        }
      } catch (e, st) {
        stderr.writeln('[$path] $e\n$st');
        await fail(e);
      } finally {
        await rpc.close();
      }
      return;
    }
    // -- Storage（shared_prefs XML 直读直写，重启 app 后生效）----------------
    if (path == '/api/storage/list' || path == '/api/storage/read' || path == '/api/storage/write') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      if (uri.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      Future<void> fail(Object e, {int code = HttpStatus.badGateway}) async {
        req.response.statusCode = code;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      }

      final rpc = _SandboxRpc(uri);
      try {
        // 包名与 preferences 目录探测。
        // Android：shared_prefs 下 *.xml；鸿蒙：app 沙盒 preferences 目录
        // （el2/el1 base，文件无扩展名，如 FlutterSharedPreferences）。
        final pkg = (await rpc.evalString(
          "(() { try { return File('/proc/self/cmdline')"
          ".readAsStringSync().split(String.fromCharCode(0))[0].trim(); } "
          "catch (_) { return ''; } })()",
        )).trim();
        final os = (await rpc.evalString('Platform.operatingSystem')).trim();
        if (os != 'ohos' && os != 'ios' && pkg.isEmpty) {
          throw '无法获取应用包名（/proc/self/cmdline）';
        }
        String home = '';
        final List<String> prefsDirs;
        final String ext;
        if (os == 'ohos') {
          prefsDirs = const <String>[
            '/data/storage/el2/base/preferences',
            '/data/storage/el1/base/preferences',
          ];
          ext = '';
        } else if (os == 'ios') {
          // iOS：NSUserDefaults 落盘在沙盒 Library/Preferences/<bundleId>.plist。
          home = (await rpc.evalString("Platform.environment['HOME'] ?? ''"))
              .trim();
          if (home.isEmpty) throw '无法获取 app 沙盒 HOME（iOS）';
          prefsDirs = <String>['$home/Library/Preferences'];
          ext = '.plist';
        } else {
          prefsDirs = <String>['/data/data/$pkg/shared_prefs'];
          ext = '.xml';
        }
        final dirList =
            prefsDirs.map((d) => "'${_escPath(d)}'").join(',');
        final listXml = await rpc.evalString(
          "(() { final out = <String>[]; "
          "for (final d in const <String>[$dirList]) { "
          "try { for (final e in Directory(d).listSync()) { "
          "if (e is File && e.path.endsWith('$ext')) out.add(e.path); } } "
          "catch (_) {} } return out.join('\\n'); })()",
        );
        var files = listXml.split('\n').where((l) => l.isNotEmpty).toList();
        // 鸿蒙 preferences 目录下的 .lock 文件不是数据，排除。
        if (os == 'ohos') {
          files = files.where((f) => !f.endsWith('.lock')).toList();
        }
        if (path == '/api/storage/list') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, Object?>{
            'pkg': pkg,
            'os': os,
            'prefsDir': prefsDirs.first,
            'files': files,
          }));
          await req.response.close();
          return;
        }
        final file = req.uri.queryParameters['file'] ??
            (files.isEmpty ? '' : files.first);
        if (file.isEmpty) {
          throw '未找到 shared_prefs（app 可能尚未写入过 preferences，或平台存储格式不同）';
        }
        if (path == '/api/storage/read') {
          if (os == 'ios') {
            // binary plist：读回字节，本机 plutil 转 XML 再交给前端。
            final dataRaw = await rpc.evalString(
              "gzip.encode(File('${_escPath(file)}')"
              ".readAsBytesSync()).join(',')",
            );
            if (dataRaw.isEmpty) throw '读取失败：文件为空？';
            final bytes = gzip.decode(
              dataRaw.split(',').map(int.parse).toList(),
            );
            final tmpBin = File(
              '${Directory.systemTemp.path}/xbume_pref_'
              '${DateTime.now().microsecondsSinceEpoch}.plist',
            );
            final tmpXml = '${tmpBin.path}.xml';
            try {
              await tmpBin.writeAsBytes(bytes);
              final pr = await Process.run('plutil', <String>[
                '-convert', 'xml1', '-o', tmpXml, tmpBin.path,
              ]);
              if (pr.exitCode != 0) {
                throw 'plutil 转换失败：${pr.stderr}';
              }
              final xml = await File(tmpXml).readAsString();
              req.response.headers.contentType = ContentType.json;
              req.response.write(jsonEncode(<String, Object?>{
                'file': file,
                'xml': xml,
              }));
              await req.response.close();
              return;
            } finally {
              try { await tmpBin.delete(); } catch (_) {}
              try { await File(tmpXml).delete(); } catch (_) {}
            }
          }
          final xml = await rpc.evalString(
            "File('${_escPath(file)}').readAsStringSync()",
          );
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, Object?>{
            'file': file,
            'xml': xml,
          }));
          await req.response.close();
          return;
        }
        // write：POST body 为新存储文件全文（Android/鸿蒙 XML、iOS 为 XML plist）。
        final xml = await _lenientUtf8.decoder.bind(req).join();
        if (os == 'ios') {
          // XML plist → 本机 plutil 转 binary plist → 写回手机。
          final tmpXml = File(
            '${Directory.systemTemp.path}/xbume_pref_'
            '${DateTime.now().microsecondsSinceEpoch}.xml',
          );
          final tmpBin = '${tmpXml.path}.bplist';
          try {
            await tmpXml.writeAsString(xml);
            final pr = await Process.run('plutil', <String>[
              '-convert', 'binary1', '-o', tmpBin, tmpXml.path,
            ]);
            if (pr.exitCode != 0) {
              throw 'plutil 转换失败（XML plist 可能非法）：${pr.stderr}';
            }
            final csv = (await File(tmpBin).readAsBytes()).join(',');
            await rpc.evalString(
              "File('${_escPath(file)}')"
              ".writeAsBytesSync(<int>[$csv])",
            );
          } finally {
            try { await tmpXml.delete(); } catch (_) {}
            try { await File(tmpBin).delete(); } catch (_) {}
          }
        } else {
          await rpc.evalString(
            "File('${_escPath(file)}').writeAsStringSync('${_escEvalString(xml)}'); "
            "return 'ok'; ",
          );
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'ok': true}));
        await req.response.close();
      } catch (e, st) {
        stderr.writeln('[$path] $e\n$st');
        await fail(e);
      } finally {
        await rpc.close();
      }
      return;
    }
    // -- 应用沙盒 -----------------------------------------------------------
    // 经 VM service evaluate 在 app 进程内读写文件系统（debug 模式可用）。
    if (path == '/api/sandbox/list') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final dir = req.uri.queryParameters['path'] ?? '';
      if (uri.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      Future<void> fail(Object e) async {
        req.response.statusCode = HttpStatus.badGateway;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      }

      final rpc = _SandboxRpc(uri);
      // 列目录的 app 端表达式（d 须为绝对路径）。
      String listExpr(String d) =>
          "(() { final sb = StringBuffer(); "
          "for (final e in Directory('${_escPath(d)}').listSync(followLinks: false)) { "
          "var size = -1; var mtime = 0; "
          "try { final st = e.statSync(); "
          "size = e is File ? st.size : -1; "
          "mtime = st.modified.millisecondsSinceEpoch; } catch (_) {} "
          "sb..write(e.path)..write('\\t')..write(e is Directory ? '1' : (e is Link ? '2' : '0'))..write('\\t')"
          "..write(size)..write('\\t')..write(mtime)..writeln(); } "
          "return sb.toString(); })()";

      try {
        final info = await rpc.evalString(
          "Platform.operatingSystem + '\\t' + "
          "(Platform.environment['HOME'] ?? Directory.current.path)",
        );
        final sep = info.indexOf('\t');
        final os = sep < 0 ? '' : info.substring(0, sep);
        final home = sep < 0 ? info : info.substring(sep + 1);

        // path 为空时探测可用起点：app 进程的 HOME 不一定可访问
        // （如鸿蒙真机 HOME=/storage/Users/currentUser 无权限），
        // 逐个尝试候选路径，收集能成功 listSync 的作为入口。
        // iOS：HOME 即 app 沙盒容器（真机 /var/mobile/Containers/Data/
        // Application/<UUID>，模拟器 CoreSimulator 对应目录），作为通用
        // 候选天然可用，无需平台特判；Android HOME='/' 被跳过，改用包名候选。
        var roots = <String>[];
        var listing = '';
        if (dir.isEmpty) {
          final candidates = <String>[
            // Android HOME 常为 '/'（无导航意义），跳过。
            if (home.isNotEmpty &&
                !(os == 'android' && (home == '/' || home == '')))
              home,
            // 鸿蒙应用沙箱映射路径（app 进程内可见）。
            if (os == 'ohos') '/data/storage/el2/base',
            if (os == 'ohos') '/data/storage/el1/base',
            if (os == 'ohos') '/data/app/el2/100/base',
            if (os == 'ohos') '/data/app/el1/100/base',
          ];
          final quoted =
              candidates.map((c) => "'${_escPath(c)}'").join(',');
          final quotedPart = quoted.isEmpty ? '' : '$quoted, ';
          // Android 11+ 分区存储：无法列出其他应用的目录（Android/data 顶层
          // 也是 errno=13），但本包名目录可访问；包名经 /proc/self/cmdline 取。
          final pkgProbe = os == 'android'
              ? "var pkg = ''; "
                  "try { pkg = File('/proc/self/cmdline')"
                  ".readAsStringSync().split(String.fromCharCode(0))[0].trim(); } "
                  "catch (_) {} "
                  "final cand = <String>[ ...(pkg.isNotEmpty ? <String>["
                  "'/data/data/' + pkg, '/data/user/0/' + pkg, "
                  "'/storage/emulated/0/Android/data/' + pkg + '/files', "
                  "'/storage/emulated/0/Android/data/' + pkg + '/cache'] : <String>[]), "
                  "$quotedPart Directory.systemTemp.path, '/']; "
              : "final cand = <String>[$quotedPart "
                  "Directory.systemTemp.path, '/']; ";
          final rootsRaw = await rpc.evalString(
            "(() { $pkgProbe"
            "final ok = <String>[]; "
            "for (final c in cand) { "
            "if (ok.contains(c)) continue; "
            "try { Directory(c).listSync(followLinks: false); ok.add(c); } "
            "catch (_) {} } return ok.join('\\n'); })()",
          );
          roots = rootsRaw
              .split('\n')
              .where((l) => l.isNotEmpty)
              .toList();
          if (roots.isNotEmpty) {
            listing = await rpc.evalString(listExpr(roots.first));
          }
        } else {
          listing = await rpc.evalString(listExpr(dir));
        }
        final actualRoot = dir.isEmpty ? (roots.isEmpty ? '' : roots.first) : dir;
        final entries = <Map<String, Object?>>[];
        for (final line in listing.split('\n')) {
          if (line.isEmpty) continue;
          final parts = line.split('\t');
          if (parts.length < 4) continue;
          entries.add(<String, Object?>{
            'name': _baseName(parts[0], os),
            'path': parts[0],
            // 1=目录，2=链接（不可进入，下载时按文件尝试），0=文件
            'dir': parts[1] == '1',
            'link': parts[1] == '2',
            'size': int.tryParse(parts[2]) ?? -1,
            'mtime': int.tryParse(parts[3]) ?? 0,
          });
        }
        entries.sort((a, b) {
          if ((a['dir'] as bool) != (b['dir'] as bool)) {
            return (a['dir'] as bool) ? -1 : 1;
          }
          return (a['name'] as String).toLowerCase().compareTo(
                (b['name'] as String).toLowerCase(),
              );
        });
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(
            <String, Object?>{
              'os': os,
              'home': home,
              'roots': roots,
              'root': actualRoot,
              'entries': entries,
            },
          ),
        );
        await req.response.close();
      } catch (e) {
        await fail(e);
      } finally {
        await rpc.close();
      }
      return;
    }
    if (path == '/api/sandbox/read') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final target = req.uri.queryParameters['path'] ?? '';
      final offset = int.tryParse(req.uri.queryParameters['offset'] ?? '0') ?? 0;
      final max = int.tryParse(req.uri.queryParameters['max'] ?? '0') ?? 0;
      if (uri.isEmpty ||
          target.isEmpty ||
          offset < 0 ||
          max < 0 ||
          max > (1 << 21)) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(
          <String, Object?>{'ok': false, 'error': 'bad request（参数不合法或单次请求超 1MB）'},
        ));
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        final sizeRaw = (await rpc.evalString(
          "(() { try { return File('${_escPath(target)}')"
          ".lengthSync().toString(); } catch (_) { return 'missing'; } })()",
        ))
            .trim();
        if (sizeRaw == 'missing' || int.tryParse(sizeRaw) == null) {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(
            <String, Object?>{'ok': false, 'error': 'missing'},
          ));
          await req.response.close();
          return;
        }
        final size = int.parse(sizeRaw);
        var text = '';
        int next = offset;
        if (next > size) next = size;
        if (max > 0 && offset < size) {
          final n = (size - offset) < max ? (size - offset) : max;
          final dataRaw = await rpc.evalString(
            "(() { final fh = File('${_escPath(target)}').openSync(); "
            "try { fh.setPositionSync($offset); final b = fh.readSync($n); "
            // base64 比 join(',') 减少 VM service 传输量（约 1.3x vs 2.5x）。
            "return base64.encode(gzip.encode(b)); } finally { fh.closeSync(); } })()",
          );
          final bytes = dataRaw.isEmpty ? <int>[] : gzip.decode(base64.decode(dataRaw));
          // 按 UTF-8 序列边界截尾，避免多字节字符被 max 切断产生替换符；
          // 截掉的部分由调用方以下一次请求的 offset 续读。
          final cut = _utf8CompleteBoundary(bytes);
          text = _lenientUtf8.decode(bytes.sublist(0, cut));
          next = offset + cut;
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{
            'ok': true,
            'text': text,
            'nextOffset': next,
            'fileSize': size,
            'truncated': next < size,
          }),
        );
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}),
        );
      }
      await req.response.close();
      return;
    }
    if (path == '/api/sandbox/delete' && req.method == 'POST') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final target = req.uri.queryParameters['path'] ?? '';
      if (uri.isEmpty || target.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      // 基本防护：拒绝删除文件系统根与无分隔符的浅路径。
      if (target == '/' || !target.contains('/')) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'error': '路径不合法，拒绝删除'}),
        );
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        final result = (await rpc.evalString(
          "(() { final p = '${_escPath(target)}'; "
          "final t = FileSystemEntity.typeSync(p); "
          "if (t == FileSystemEntityType.notFound) return 'missing'; "
          "try { if (t == FileSystemEntityType.directory) "
          "{ Directory(p).deleteSync(recursive: true); } "
          "else { File(p).deleteSync(); } return 'ok'; } "
          "catch (e) { return 'error: ' + e.toString(); } })()",
        ))
            .trim();
        final ok = result == 'ok';
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{
            'ok': ok,
            'result': result,
            'error': ok ? null : (result == 'missing' ? '目标不存在' : result),
          }),
        );
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      }
      await req.response.close();
      return;
    }
    // ── 沙盒上传：base64+path → app 内写文件，分块 append。
    // eval 库上下文用 xb_ume 持久化 io 实现库（条件导出在桌面/移动端必被
    // 编译进 app），它是唯一同时 import dart:io 与 dart:convert 的现成库。
    if (path == '/api/sandbox/upload' && req.method == 'POST') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final dir = req.uri.queryParameters['path'] ?? '';
      if (uri.isEmpty || dir.isEmpty || !dir.contains('/')) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': false, 'error': 'bad request（uri/path 必填）'}),
        );
        await req.response.close();
        return;
      }
      Map<String, Object?> body;
      try {
        final raw = await utf8.decoder.bind(req).join();
        body = (raw.isEmpty
            ? <String, Object?>{}
            : jsonDecode(raw) as Map<String, Object?>);
      } catch (_) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': false, 'error': '请求体不是合法 JSON'}),
        );
        await req.response.close();
        return;
      }
      final name = (body['name'] as String? ?? '').trim();
      final b64 = (body['b64'] as String? ?? '');
      // 文件名防护：禁止路径分隔符与目录穿越。
      if (name.isEmpty ||
          name.contains('/') ||
          name.contains('\\') ||
          name.contains('..')) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': false, 'error': '文件名不合法'}),
        );
        await req.response.close();
        return;
      }
      if (b64.length > (16 << 20)) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': false, 'error': '文件过大（上限 12MB）'}),
        );
        await req.response.close();
        return;
      }
      List<int> bytes;
      try {
        bytes = base64.decode(b64);
      } catch (_) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': false, 'error': 'b64 字段不是合法 base64'}),
        );
        await req.response.close();
        return;
      }
      final target = dir.endsWith('/') ? '$dir$name' : '$dir/$name';
      final rpc = _SandboxRpc(uri);
      try {
        const libCtx =
            'package:xb_ume/src/persistence/xb_ume_persistence_io.dart';
        const chunk = 1 << 19; // 512KB/块，b64 后约 700KB，控制 eval 表达式体积
        for (var off = 0;
            off < bytes.length || off == 0;
            off += chunk) {
          final end =
              (off + chunk) < bytes.length ? (off + chunk) : bytes.length;
          final part = base64.encode(bytes.sublist(off, end));
          final mode = off == 0 ? 'FileMode.write' : 'FileMode.append';
          final expr = "(() { final p = '${_escPath(target)}'; "
              'final f = File(p); '
              'if (!f.parent.existsSync()) '
              '{ f.parent.createSync(recursive: true); } '
              "f.writeAsBytesSync(base64.decode('$part'), mode: $mode); "
              "return 'ok:' + f.lengthSync().toString(); })()";
          final r = (await rpc.evalStringOn(libCtx, expr)).trim();
          if (!r.startsWith('ok:')) {
            throw StateError('eval 写入失败：$r');
          }
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{
            'ok': true,
            'path': target,
            'size': bytes.length,
          }),
        );
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      }
      await req.response.close();
      return;
    }
    // ── 实例查看：堆扫描/注册表定位实例，getObject 展开字段树，eval 写回 ──
    // ── 运行时操作：reassemble（UI 重建）/ GC（_collectAllGarbage）──
    if (path == '/api/runtime/op' && req.method == 'POST') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final op = req.uri.queryParameters['op'] ?? '';
      if (uri.isEmpty || op.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      try {
        final rpc = _SandboxRpc(uri);
        if (op == 'reassemble') {
          // service extension 线上协议：扩展名直接作 method（callServiceExtension
          // 不是 JSON-RPC 方法名，实测 Unknown method）。
          final iso = await rpc.isolateId();
          await rpc.rawRpc('ext.flutter.reassemble', <String, Object?>{
            'isolateId': iso,
          });
        } else if (op == 'gc') {
          // 真正可用的 GC：私有方法（ext.flutter.triggerGC 未注册，实测不存在）。
          final iso = await rpc.isolateId();
          await rpc.rawRpc('_collectAllGarbage', <String, Object?>{
            'isolateId': iso,
          });
        } else {
          throw '未知操作：$op';
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'ok': true}));
        await req.response.close();
      } catch (e) {
        req.response.statusCode = HttpStatus.badGateway;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}),
        );
        await req.response.close();
      }
      return;
    }
    // ── 实时截图：_flutter.screenshot 返回 base64 PNG（DDS 转发，debug 可用）──
    if (path == '/api/screenshot') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      if (uri.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      try {
        final rpc = _SandboxRpc(uri);
        final r = await rpc.rawRpc('_flutter.screenshot');
        final b64 = (r['data'] ?? r['screenshot'])?.toString() ?? '';
        if (b64.isEmpty) throw '截图响应为空（app 需 debug 模式且前台运行）';
        req.response.headers.contentType = ContentType('image', 'png');
        req.response.add(base64Decode(b64));
        await req.response.close();
      } catch (e) {
        req.response.statusCode = HttpStatus.badGateway;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}),
        );
        await req.response.close();
      }
      return;
    }
    // ── P9：Widget 树浏览。一次 eval 拉全 Element 树（含每节点 bounds），
    // 树节点 ↔ 截图 bounds 对应、点截图反查均由前端用同一份数据完成。
    if (path == '/api/wtree') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      if (uri.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        final s = (await rpc.evalStringOn(
          'package:flutter/src/widgets/binding.dart',
          _wtreeExpr,
        ))
            .trim();
        if (s == 'NO_ROOT') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': 'app 无渲染树（尚未运行首帧）'}),
          );
          await req.response.close();
          return;
        }
        final parts = s.split('\u0003');
        // 末两段为空行分隔与尾部元数据（dpr\u0001物理宽\u0001物理高）
        final meta = parts.length >= 2 ? parts[parts.length - 1].split('\u0001') : <String>[];
        final rows = parts.sublist(0, parts.length - 2);
        final nodes = <Map<String, Object?>>[];
        for (final r in rows) {
          final f = r.split('\u0001');
          if (f.length < 4) continue;
          final depth = int.tryParse(f[0]);
          if (depth == null) continue;
          final bs = f[3].split(',');
          nodes.add(<String, Object?>{
            'd': depth,
            't': f[1],
            'k': f[2],
            'b': f[3].isEmpty
                ? null
                : <int>[
                    int.tryParse(bs[0]) ?? 0,
                    int.tryParse(bs[1]) ?? 0,
                    int.tryParse(bs[2]) ?? 0,
                    int.tryParse(bs[3]) ?? 0,
                  ],
          });
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': true,
          'nodes': nodes,
          'dpr': double.tryParse(meta.isNotEmpty ? meta[0] : '1') ?? 1,
          'physW': int.tryParse(meta.length > 1 ? meta[1] : '0') ?? 0,
          'physH': int.tryParse(meta.length > 2 ? meta[2] : '0') ?? 0,
        }));
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      }
      await req.response.close();
      return;
    }
    // ── P9b：点截图反查业务组件（locator 同款 SDK 判定 + 四向间距）──
    if (path == '/api/wtree/pick' && req.method == 'POST') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final x = req.uri.queryParameters['x'] ?? '';
      final y = req.uri.queryParameters['y'] ?? '';
      if (uri.isEmpty || double.tryParse(x) == null || double.tryParse(y) == null) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        final expr = _wpickExprHead + x + _wpickExprMid + y + _wpickExprBody;
        final s = (await rpc.evalStringOn(
          'package:xb_ume/src/core/xb_ume_widget_spacing_calculator.dart',
          expr,
        ))
            .trim();
        req.response.headers.contentType = ContentType.json;
        if (s == 'NO_ROOT' || s == 'MISS' || s == 'NOBIZ') {
          req.response.write(jsonEncode(<String, Object?>{
            'ok': false,
            'error': s == 'NO_ROOT'
                ? 'app 无渲染树'
                : s == 'MISS'
                    ? '该位置无组件'
                    : '该位置没有非 Flutter SDK 组件',
          }));
          await req.response.close();
          return;
        }
        final parts = s.split('\u0003');
        if (parts.isEmpty || parts.first != 'PICK') {
          req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': '响应格式异常'}));
          await req.response.close();
          return;
        }
        String type = '', file = '', bounds = '';
        var line = 0, col = 0;
        if (parts.length > 1) {
          final f = parts[1].split('\u0001');
          if (f.length >= 5) {
            type = f[0];
            file = f[1];
            line = int.tryParse(f[2]) ?? 0;
            col = int.tryParse(f[3]) ?? 0;
            bounds = f[4];
          }
        }
        final spacing = <Map<String, Object?>>[];
        for (var i = 2; i < parts.length; i++) {
          if (parts[i].isEmpty) continue;
          final f = parts[i].split('\u0001');
          if (f.length < 5) continue;
          spacing.add(<String, Object?>{
            'dir': f[0],
            'dist': double.tryParse(f[1]) ?? 0,
            'type': f[2],
            'kind': f[3],
            'rect': f[4],
          });
        }
        req.response.write(jsonEncode(<String, Object?>{
          'ok': true,
          'type': type,
          'file': file,
          'line': line,
          'col': col,
          'bounds': bounds,
          'spacing': spacing,
        }));
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      }
      await req.response.close();
      return;
    }
    // ── P10 自动化路径：场景存取/执行/状态/截图 ──
    if (path == '/api/auto/list') {
      final dir = Directory(_autoScenariosDir);
      final items = <Map<String, Object?>>[];
      if (dir.existsSync()) {
        for (final f in dir.listSync()) {
          if (f is! File || !f.path.endsWith('.json')) continue;
          try {
            final j = jsonDecode(f.readAsStringSync());
            // save 落盘的是纯步骤数组（不带外层 Map），兼容两种格式。
            final steps = j is List
                ? j.length
                : (j is Map ? (j['steps'] as List? ?? <Object?>[]).length : 0);
            items.add(<String, Object?>{
              'name': f.uri.pathSegments.last.replaceAll(RegExp(r'\.json$'), ''),
              'steps': steps,
              'mtime': f.statSync().modified.toIso8601String(),
            });
          } catch (_) {}
        }
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': true, 'items': items}));
      await req.response.close();
      return;
    }
    if (path == '/api/auto/get' || path == '/api/auto/delete') {
      final name = (req.uri.queryParameters['name'] ?? '').trim();
      final file = _autoScenarioFile(name);
      if (file == null) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': _autoNameError}));
        await req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType.json;
      if (path == '/api/auto/get') {
        if (!file.existsSync()) {
          req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': '场景不存在'}));
        } else {
          req.response.write(jsonEncode(<String, Object?>{
            'ok': true,
            'name': name,
            'steps': jsonDecode(file.readAsStringSync()),
          }));
        }
      } else {
        if (file.existsSync()) file.deleteSync();
        req.response.write(jsonEncode(<String, Object?>{'ok': true}));
      }
      await req.response.close();
      return;
    }
    if (path == '/api/auto/save' && req.method == 'POST') {
      final body = await utf8.decoder.bind(req).join();
      try {
        final j = jsonDecode(body) as Map<String, dynamic>;
        final file = _autoScenarioFile((j['name'] ?? '').toString());
        if (file == null) {
          req.response.statusCode = HttpStatus.badRequest;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': _autoNameError}));
          await req.response.close();
          return;
        }
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(j['steps'] ?? []));
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'ok': true}));
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      }
      await req.response.close();
      return;
    }
    if (path == '/api/auto/run' && req.method == 'POST') {
      if (_auto.running) {
        req.response.statusCode = HttpStatus.conflict;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': '已有场景在执行'}));
        await req.response.close();
        return;
      }
      final uri = req.uri.queryParameters['uri'] ?? '';
      String name = req.uri.queryParameters['name'] ?? '';
      List steps;
      final body = await utf8.decoder.bind(req).join();
      try {
        if (body.isNotEmpty) {
          final j = jsonDecode(body);
          steps = j is List ? j : (j is Map ? (j['steps'] as List? ?? <Object?>[]) : <Object?>[]);
          if (j is Map && name.isEmpty) name = (j['name'] ?? '').toString();
        } else if (name.isNotEmpty) {
          final file = _autoScenarioFile(name);
          if (file == null || !file.existsSync()) {
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': '场景不存在'}));
            await req.response.close();
            return;
          }
          steps = jsonDecode(file.readAsStringSync()) as List;
        } else {
          steps = <Object?>[];
        }
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': '步骤解析失败: $e'}));
        await req.response.close();
        return;
      }
      if (uri.isEmpty || steps.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final cont = (req.uri.queryParameters['continue'] ?? '') == '1';
      unawaited(_autoRunSteps(uri, name, steps, continueOnFail: cont));
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': true, 'total': steps.length}));
      await req.response.close();
      return;
    }
    if (path == '/api/auto/status') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': true}..addAll(_auto.statusJson())));
      await req.response.close();
      return;
    }
    if (path == '/api/auto/stop' && req.method == 'POST') {
      _auto.stopReq = true;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': true}));
      await req.response.close();
      return;
    }
    if (path == '/api/auto/artifact') {
      final f = req.uri.queryParameters['f'] ?? '';
      // 文件名防穿越：只允许 run-<ts>-stepN.png / ai-<ts>-rN.png / ai-<ts>-stepN.png
      if (f.isEmpty ||
          f.contains('/') ||
          f.contains('\\') ||
          !RegExp(r'^(?:run|ai)-\d+-(?:step\d+|r\d+)\.png$').hasMatch(f)) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final file = File('$_autoArtifactsDir/$f');
      if (!file.existsSync()) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType('image', 'png');
      req.response.headers.set('Cache-Control', 'no-store');
      await file.openRead().pipe(req.response);
      return;
    }
    // ── P11 AI 驱动：自然语言目标 → 截图发给 AI → AI 返回步骤 → 执行循环 ──
    if (path == '/api/ai/config') {
      if (req.method == 'POST') {
        try {
          final body = await utf8.decoder.bind(req).join();
          final j = jsonDecode(body) as Map<String, dynamic>;
          final old = _aiConfig();
          final key = (j['apiKey'] ?? '').toString().trim();
          // apiKey 传空或仍是打码值（未修改）时保留原值
          final newKey = (key.isEmpty || key == _aiMaskKey(old['apiKey'] ?? ''))
              ? (old['apiKey'] ?? '')
              : key;
          final f = File(_aiConfigPath);
          f.parent.createSync(recursive: true);
          // ctx 上下文开关：请求未携带时保留旧值
          final cIn = j['ctx'];
          final oldCtx = _aiCtx();
          bool cv(Object? v, bool old) => v is bool ? v : old;
          f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(
              <String, Object?>{
                'baseUrl': (j['baseUrl'] ?? '').toString().trim(),
                'apiKey': newKey,
                'model': (j['model'] ?? '').toString().trim(),
                'ctx': <String, Object?>{
                  'routes': cv(
                      cIn is Map ? cIn['routes'] : null, oldCtx['routes'] ?? true),
                  'text': cv(
                      cIn is Map ? cIn['text'] : null, oldCtx['text'] ?? true),
                  'net': cv(
                      cIn is Map ? cIn['net'] : null, oldCtx['net'] ?? true),
                  'log': cv(
                      cIn is Map ? cIn['log'] : null, oldCtx['log'] ?? true),
                },
              }));
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, Object?>{'ok': true}));
        } catch (e) {
          req.response.headers.contentType = ContentType.json;
          req.response
              .write(jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
        }
        await req.response.close();
        return;
      }
      final c = _aiConfig();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{
        'ok': true,
        'baseUrl': c['baseUrl'],
        'model': c['model'],
        'apiKey': _aiMaskKey(c['apiKey'] ?? ''),
        'ctx': _aiCtx(),
      }));
      await req.response.close();
      return;
    }
    if (path == '/api/ai/run' && req.method == 'POST') {
      if (_ai.running || _auto.running) {
        req.response.statusCode = HttpStatus.conflict;
        req.response.headers.contentType = ContentType.json;
        req.response
            .write(jsonEncode(<String, Object?>{'ok': false, 'error': '已有任务在执行'}));
        await req.response.close();
        return;
      }
      final uri = req.uri.queryParameters['uri'] ?? '';
      final goal = (req.uri.queryParameters['goal'] ?? '').trim();
      if (uri.isEmpty || goal.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final cfg = _aiConfig();
      if ((cfg['baseUrl'] ?? '').isEmpty ||
          (cfg['apiKey'] ?? '').isEmpty ||
          (cfg['model'] ?? '').isEmpty) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': false,
          'error': '请先在「AI 设置」中配置接口地址、密钥与模型',
        }));
        await req.response.close();
        return;
      }
      unawaited(_aiLoop(uri, goal));
      _aiGoalsAdd(goal);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': true}));
      await req.response.close();
      return;
    }
    if (path == '/api/ai/goals' && req.method == 'GET') {
      req.response.headers.contentType = ContentType.json;
      req.response
          .write(jsonEncode(<String, Object?>{'ok': true, 'items': _aiGoalsLoad()}));
      await req.response.close();
      return;
    }
    if (path == '/api/ai/goals/clear' && req.method == 'POST') {
      final f = File('$_home/.xb_ume_ide/ai_goals.json');
      if (f.existsSync()) f.deleteSync();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': true}));
      await req.response.close();
      return;
    }
    if (path == '/api/ai/status') {
      req.response.headers.contentType = ContentType.json;
      req.response
          .write(jsonEncode(<String, Object?>{'ok': true}..addAll(_ai.statusJson())));
      await req.response.close();
      return;
    }
    if (path == '/api/ai/stop' && req.method == 'POST') {
      _ai.stopReq = true;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': true}));
      await req.response.close();
      return;
    }
    if (path == '/api/ai/save' && req.method == 'POST') {
      try {
        final body = await utf8.decoder.bind(req).join();
        final j = jsonDecode(body) as Map<String, dynamic>;
        final file = _autoScenarioFile((j['name'] ?? '').toString());
        if (file == null) {
          req.response.statusCode = HttpStatus.badRequest;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, Object?>{'ok': false, 'error': _autoNameError}));
          await req.response.close();
          return;
        }
        // 拍平各轮 AI 步骤（过滤掉本轮未执行完的尾部 skip 结果对应的步骤）
        final steps = <Object?>[];
        for (final r in _ai.rounds) {
          for (var i = 0; i < r.results.length && i < r.steps.length; i++) {
            if (r.results[i].status == 'pass' || r.results[i].status == 'fail') {
              steps.add(r.steps[i]);
            }
          }
        }
        if (steps.isEmpty) {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(
              <String, Object?>{'ok': false, 'error': '本次 AI 执行没有可保存的步骤'}));
          await req.response.close();
          return;
        }
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(steps));
        req.response.headers.contentType = ContentType.json;
        req.response
            .write(jsonEncode(<String, Object?>{'ok': true, 'steps': steps.length}));
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response
            .write(jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      }
      await req.response.close();
      return;
    }
    // ── 异常列表：Extension 流 Flutter.Error 结构化事件 + 输出流未捕获异 常块 ──
    if (path == '/api/exceptions') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode(<String, Object?>{'items': state.exceptions}),
      );
      await req.response.close();
      return;
    }
    if (path == '/api/exceptions/clear' && req.method == 'POST') {
      state.clearExceptions();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': true}));
      await req.response.close();
      return;
    }
    // ── IDE 跳转：异常栈帧 / 相关 widget 的「跳转」用（异常 Tab）──
    if (path == '/api/openide') {
      final file = req.uri.queryParameters['file'] ?? '';
      final line = int.tryParse(req.uri.queryParameters['line'] ?? '') ?? 1;
      if (file.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final message = await _guiLaunchIde(file, line);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{
        'ok': message == null,
        if (message != null) 'message': message,
      }));
      await req.response.close();
      return;
    }
    if (path == '/api/instances/stores') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      if (uri.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        // 注册表：_stores 值是 WeakReference，经 resolvedStores getter 解包
        // 为存活实例的临时强引用副本（eval 期间存活，不影响 GC 语义）；
        // 旧版 app 端无该 getter 时回退直读 _stores（强引用版注册表）。
        Map<String, Object?> mapRef;
        try {
          mapRef = await rpc.evalRefOn(
            'package:xb_ume/src/core/xb_ume_store_registry.dart',
            'XBUmeStoreRegistry.resolvedStores',
          );
        } catch (_) {
          mapRef = await rpc.evalRefOn(
            'package:xb_ume/src/core/xb_ume_store_registry.dart',
            'XBUmeStoreRegistry._stores',
          );
        }
        final iso = await rpc.isolateId();
        final map = await rpc.rawRpc('getObject', {
          'isolateId': iso,
          'objectId': mapRef['id'],
        });
        final items = <Map<String, Object?>>[];
        for (final assoc in (map['associations'] as List? ?? <Object?>[])) {
          if (assoc is! Map) continue;
          final key = assoc['key'] as Map?;
          final value = assoc['value'] as Map?;
          final instId = value?['id']?.toString();
          if (instId == null || instId.isEmpty) continue;
          items.add(<String, Object?>{
            'id': key?['valueAsString']?.toString() ?? '',
            'instId': instId,
            'cls': (value?['class'] as Map?)?['name']?.toString() ?? '',
          });
        }
        items.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': true,
          'items': items,
        }));
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': false,
          'error': e.toString().contains('版本过旧')
              ? e.toString()
              : '读取注册表失败（${e.toString()}）——若是「未加载 …store_registry…库」，说明 app 端 xb_ume 版本过旧，请更新依赖并重启 app',
        }));
      }
      await rpc.close();
      await req.response.close();
      return;
    }
    if (path == '/api/instances/find') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final cls = req.uri.queryParameters['class']?.trim() ?? '';
      final limit =
          (int.tryParse(req.uri.queryParameters['limit'] ?? '') ?? 20)
              .clamp(1, 100);
      if (uri.isEmpty || cls.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        final iso = await rpc.isolateId();
        final items = <Map<String, Object?>>[];
        final seen = <String>{};
        void add(String id, String source, String clsName) {
          if (id.isEmpty || !seen.add(id)) return;
          items.add(<String, Object?>{
            'id': id,
            'cls': clsName,
            'source': source,
          });
        }

        // 通道一：Element 树遍历（树上存活的 State 实例）。
        try {
          final walkExpr = "(() { final root = WidgetsBinding.instance"
              ".renderViewElement; if (root == null) return null; "
              "final out = <Object>[]; void walk(Element e) { "
              "final s = e is StatefulElement ? e.state : null; "
              "if (s != null && s.runtimeType.toString() == '$cls') { out.add(s); } "
              "e.visitChildren(walk); } root.visitChildren(walk); return out; })()";
          final listRef = await rpc.evalRefOn(
            'package:flutter/src/widgets/navigator.dart',
            walkExpr,
          );
          if (listRef['valueAsString']?.toString() != 'null') {
            final list = await rpc.rawRpc('getObject', {
              'isolateId': iso,
              'objectId': listRef['id'],
            });
            for (final el in (list['elements'] as List? ?? <Object?>[])) {
              if (el is! Map) continue;
              add(
                el['id']?.toString() ?? '',
                'tree',
                (el['class'] as Map?)?['name']?.toString() ?? cls,
              );
            }
          }
        } catch (_) {
          // 树遍历失败（如 NO_ROOT）不阻塞堆扫描。
        }

        // 通道二：堆扫描（ getClassList 匹配类名 → getInstances 捞实例），
        // 不要求挂树，覆盖 Provider notifier / 单例等纯逻辑对象。
        try {
          final classList =
              await rpc.rawRpc('getClassList', {'isolateId': iso});
          final classIds = <String>[];
          for (final c in (classList['classes'] as List? ?? <Object?>[])) {
            if (c is! Map) continue;
            final name = c['name']?.toString() ?? '';
            if (name == cls || name.endsWith('.$cls')) {
              classIds.add(c['id']?.toString() ?? '');
            }
          }
          for (final classId in classIds) {
            if (classId.isEmpty) continue;
            final set = await rpc.rawRpc('getInstances', {
              'isolateId': iso,
              'objectId': classId,
              'limit': limit,
            });
            for (final inst in (set['instances'] as List? ?? <Object?>[])) {
              if (inst is! Map) continue;
              add(
                inst['id']?.toString() ?? '',
                'heap',
                (inst['class'] as Map?)?['name']?.toString() ?? cls,
              );
            }
          }
        } catch (_) {
          // 堆扫描失败同样不阻塞另一路结果。
        }

        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': true,
          'items': items.take(limit).toList(),
        }));
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response
            .write(jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      }
      await rpc.close();
      await req.response.close();
      return;
    }
    if (path == '/api/instances/tree') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final id = req.uri.queryParameters['id'] ?? '';
      final name = req.uri.queryParameters['name'];
      final depth = (int.tryParse(req.uri.queryParameters['depth'] ?? '') ?? 2)
          .clamp(1, 4);
      if (uri.isEmpty || id.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        final iso = await rpc.isolateId();
        final node = await _instNode(rpc, iso, id, name, depth, <String>{});
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'ok': true, 'node': node}));
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response
            .write(jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      }
      await rpc.close();
      await req.response.close();
      return;
    }
    if (path == '/api/instances/set' && req.method == 'POST') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final id = req.uri.queryParameters['id'] ?? '';
      final field = req.uri.queryParameters['field'] ?? '';
      final value = req.uri.queryParameters['value'] ?? '';
      final vtype = req.uri.queryParameters['vtype'] ?? 'string';
      if (uri.isEmpty || id.isEmpty || field.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        final iso = await rpc.isolateId();
        String literal;
        switch (vtype) {
          case 'int':
            final v = int.tryParse(value);
            if (v == null) throw '值不是合法整数：$value';
            literal = value;
          case 'double':
            final v = double.tryParse(value);
            if (v == null) throw '值不是合法小数：$value';
            literal = value;
          case 'bool':
            if (value != 'true' && value != 'false') {
              throw '值必须是 true/false';
            }
            literal = value;
          case 'null':
            literal = 'null';
          default:
            literal = "'${_escPath(value)}'";
        }
        // 在实例上下文 eval：this 绑定为该实例，直接给字段赋值。
        final result = await rpc.rawRpc('evaluate', {
          'isolateId': iso,
          'targetId': id,
          'expression': '$field = $literal',
        });
        // 编译/求值错误返回 type=@Error（LanguageError），不是 'Error'。
        final rtype = result['type']?.toString() ?? '';
        if (rtype == 'Error' || rtype == '@Error') {
          throw (result['message']?.toString() ?? '写回失败（字段不存在或 final？）')
              .split('\n').take(3).join(' ');
        }
        // ChangeNotifier 类写回后自动 notifyListeners（无该方法时静默跳过）。
        var notified = false;
        try {
          final nl = await rpc.rawRpc('evaluate', {
            'isolateId': iso,
            'targetId': id,
            'expression':
                "(() { try { (this as dynamic).notifyListeners(); return '1'; } catch (_) { return '0'; } })()",
          });
          notified = nl['valueAsString']?.toString() == '1';
        } catch (_) {
          // ignored
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': true,
          'notified': notified,
        }));
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response
            .write(jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      }
      await rpc.close();
      await req.response.close();
      return;
    }
    if (path == '/api/sandbox/download' || path == '/api/sandbox/downloadDir') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final target = req.uri.queryParameters['path'] ?? '';
      if (uri.isEmpty || target.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      Future<void> fail(Object e, {int code = HttpStatus.badGateway}) async {
        req.response.statusCode = code;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      }

      // 分段读取文件：每次 evaluate 读 1MB 并 gzip 压缩传输，
      // app 端与 GUI 端内存峰值均为常数级，文件大小无上限。
      Future<void> readFileChunks(
        String rpcFile,
        void Function(List<int> chunk) onChunk,
      ) async {
        final size = int.parse(
          (await rpc.evalString("File('${_escPath(rpcFile)}').lengthSync()"))
              .trim(),
        );
        const chunkSize = 1024 * 1024;
        for (var offset = 0; offset < size; offset += chunkSize) {
          final n = size - offset < chunkSize ? size - offset : chunkSize;
          final data = await rpc.evalString(
            "(() { final fh = File('${_escPath(rpcFile)}').openSync(); "
            "try { fh.setPositionSync($offset); final b = fh.readSync($n); "
            "return gzip.encode(b).join(','); } finally { fh.closeSync(); } })()",
          );
          if (data.isEmpty) continue;
          final gz = data.split(',').map(int.parse).toList();
          if (gz.isNotEmpty) {
            final plain = gzip.decode(gz);
            if (plain.isNotEmpty) onChunk(plain);
          }
        }
      }

      var streaming = false; // 响应已开始流式输出（此时不能再改状态码）
      try {
        if (path == '/api/sandbox/download') {
          final size = int.parse(
            (await rpc.evalString("File('${_escPath(target)}').lengthSync()"))
                .trim(),
          );
          req.response.headers.contentType = ContentType.binary;
          req.response.headers.set(
            'Content-Disposition',
            'attachment; filename="${Uri.encodeComponent(_baseName(target, ''))}"',
          );
          req.response.contentLength = size;
          streaming = true;
          await readFileChunks(target, req.response.add);
          await req.response.close();
          return;
        }
        // 文件夹：递归列出全部文件，逐个流式写入 USTAR tar（无压缩）。
        final info = await rpc.evalString(
          "Platform.operatingSystem + '\\t' + Directory.current.path",
        );
        final os = info.split('\t').first;
        final listing = await rpc.evalString(
          "(() { final files = Directory('${_escPath(target)}')"
          ".listSync(recursive: true, followLinks: false).whereType<File>().toList(); "
          "final sb = StringBuffer()..writeln(files.length); "
          "for (final f in files) { "
          "try { sb..write(f.path)..write('\\t')..write(f.lengthSync())..write('\\t')"
          "..write(f.lastModifiedSync().millisecondsSinceEpoch)..writeln(); } catch (_) {} } "
          "return sb.toString(); })()",
        );
        final lines = listing.split('\n').where((l) => l.isNotEmpty).toList();
        final files = <List<String>>[];
        for (final line in lines.skip(1)) {
          final parts = line.split('\t');
          if (parts.length < 3) continue;
          files.add(<String>[parts[0], parts[1], parts[2]]);
        }
        final name = _baseName(target, os);
        req.response.headers.contentType = ContentType.binary;
        req.response.headers.set(
          'Content-Disposition',
          'attachment; filename="${Uri.encodeComponent(name.isEmpty ? 'sandbox' : name)}.tar"',
        );
        streaming = true;
        var skipped = 0;
        for (final f in files) {
          final size = int.tryParse(f[1]) ?? 0;
          final mtimeSec = (int.tryParse(f[2]) ?? 0) ~/ 1000;
          final header = _tarHeader(_relativeTo(f[0], target, os), size, mtimeSec);
          if (header == null) {
            skipped++;
            continue;
          }
          req.response.add(header);
          await readFileChunks(f[0], req.response.add);
          final padding = (512 - (size % 512)) % 512;
          if (padding > 0) {
            req.response.add(List<int>.filled(padding, 0));
          }
        }
        req.response.add(_tarEnd());
        await req.response.close();
        if (skipped > 0) {
          print('[xbume-gui] 沙盒下载：$skipped 个条目路径过长已跳过');
        }
      } catch (e) {
        if (streaming) {
          // 流式输出已开始，只能截断连接（浏览器报下载失败）。
          try {
            await req.response.close();
          } catch (_) {}
        } else {
          await fail(e);
        }
      } finally {
        await rpc.close();
      }
      return;
    }
    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  } catch (e) {
    print('[xbume-gui] 请求处理异常 $path: $e');
    try {
      req.response.statusCode = HttpStatus.internalServerError;
      await req.response.close();
    } catch (_) {
      // ignored
    }
  }
}

// ---------------------------------------------------------------------------
// GUI 状态与模块逻辑
// ---------------------------------------------------------------------------

class GuiState {
  GuiState() : startedAt = DateTime.now();

  final DateTime startedAt;
  final Set<WebSocket> _clients = <WebSocket>{};
  final List<Map<String, Object?>> _buffer = <Map<String, Object?>>[];
  final List<Map<String, Object?>> _pending = <Map<String, Object?>>[];
  final Map<String, _VmSession> _vmSessions = <String, _VmSession>{};
  Timer? _pollTimer;
  Timer? _flushTimer;

  /// 异常缓冲（全部会话汇总，最新在末尾；供异常 Tab 与 /api/exceptions）。
  final List<Map<String, Object?>> _exceptions = <Map<String, Object?>>[];
  int _excSeq = 0;

  /// 输出流未捕获异常块的逐行解析器（key: uri|stream → tracker）。
  final Map<String, _UncaughtTracker> _uncaught = <String, _UncaughtTracker>{};

  /// 每台设备一个日志流进程（所有设备并行采集，选择器只做前端过滤）。
  final Map<String, Process> _deviceLogProcesses = <String, Process>{};
  final Set<String> _deviceLogStartFailed = <String>{};
  List<Map<String, String>> devices = <Map<String, String>>[];
  String? selectedId;

  /// 日志环形缓冲（供 HTTP 导出接口读取）。
  List<Map<String, Object?>> get buffer => _buffer;

  /// 异常缓冲只读视图（供 /api/exceptions）。
  List<Map<String, Object?>> get exceptions =>
      List<Map<String, Object?>>.unmodifiable(_exceptions);

  void clearExceptions() {
    _exceptions.clear();
    broadcast(<String, Object?>{'type': 'exceptionsCleared'});
  }

  void start() {
    unawaited(poll());
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(poll()),
    );
    _flushTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _flush();
    });
  }

  /// 会话 uri → 应用包名（每个 uri 有 Stdout/Stderr 两条 _VmSession）。
  /// 供 /api/daemon 响应合并展示「会话对应哪个应用」。
  String? appNameFor(String uri) {
    for (final entry in _vmSessions.entries) {
      if (entry.key.startsWith('$uri|')) {
        return entry.value.appName;
      }
    }
    return null;
  }

  Future<void> dispose() async {
    _pollTimer?.cancel();
    _flushTimer?.cancel();
    for (final process in _deviceLogProcesses.values) {
      process.kill();
    }
    for (final session in _vmSessions.values) {
      session.close();
    }
    for (final ws in List<WebSocket>.of(_clients)) {
      try {
        await ws.close();
      } catch (_) {
        // ignored
      }
    }
  }

  // -- 设备管理模块 ----------------------------------------------------------

  /// 轮询设备列表并维护日志源生命周期（全部设备并行采集）。
  Future<void> poll() async {
    try {
      devices = await discoverDevices();
    } catch (e) {
      print('[xbume-gui] 设备发现异常: $e');
    }
    broadcast(<String, Object?>{'type': 'devices', 'devices': devices});
    final ids = devices.map((d) => d['id'] ?? '').toSet();
    for (final device in devices) {
      await _ensureDeviceLogSource(device);
    }
    for (final id in _deviceLogProcesses.keys.toList()) {
      if (!ids.contains(id)) {
        await _stopDeviceLogSource(id);
      }
    }
    await _syncVmSessions();
  }

  /// 选择设备只影响前端过滤，不再切换日志源/清空缓冲。
  Future<void> selectDevice(String? id) async {
    if (selectedId == id) {
      return;
    }
    selectedId = id;
    broadcast(<String, Object?>{'type': 'devices', 'devices': devices});
  }

  // -- 日志模块 --------------------------------------------------------------

  String _sourceForPlatform(String platform) {
    switch (platform) {
      case 'android':
        return 'logcat';
      case 'ohos':
        return 'hilog';
      default:
        return 'ios';
    }
  }

  List<String>? _deviceLogCommand(Map<String, String> device) {
    final id = device['id'] ?? '';
    switch (device['platform']) {
      case 'android':
        return <String>['adb', '-s', id, 'logcat', '-v', 'time'];
      case 'ohos':
        return <String>['hdc', '-t', id, 'hilog'];
      case 'ios-sim':
        return <String>[
          'xcrun',
          'simctl',
          'spawn',
          id,
          'log',
          'stream',
          '--style',
          'compact',
        ];
      case 'ios-real':
        return <String>['idevicesyslog', '-u', id];
      default:
        return null;
    }
  }

  Future<void> _ensureDeviceLogSource(Map<String, String> device) async {
    final id = device['id'] ?? '';
    if (id.isEmpty || _deviceLogProcesses.containsKey(id)) {
      return;
    }
    final command = _deviceLogCommand(device);
    if (command == null) {
      return;
    }
    final source = _sourceForPlatform(device['platform'] ?? '');
    try {
      final process = await Process.start(
        command.first,
        command.sublist(1),
        environment: <String, String>{'PATH': await _toolPath()},
      );
      _deviceLogProcesses[id] = process;
      _deviceLogStartFailed.remove(id);
      process.stdout
          .transform(_lenientUtf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => addDeviceLog(id, source, line));
      process.stderr
          .transform(_lenientUtf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => addDeviceLog(id, source, line));
      unawaited(process.exitCode.then((_) {
        if (_deviceLogProcesses[id] == process) {
          _deviceLogProcesses.remove(id);
        }
      }));
    } catch (e) {
      // 避免每 3s 轮询刷屏：同一设备只提示一次。
      if (_deviceLogStartFailed.add(id)) {
        addDeviceLog(id, source, '[GUI] 无法启动 ${command.first}（未安装或不在 PATH）: $e');
      }
    }
  }

  Future<void> _stopDeviceLogSource(String id) async {
    _deviceLogProcesses.remove(id)?.kill();
  }

  /// 同步 VM service stdout 会话（flutter run 控制台输出来源）。
  ///
  /// 实测（v0.1.5）：flutter run 的控制台输出不走 kind=Stdout 事件，而是
  /// DDS 重发的 kind=WriteEvent（无 source 字段），且连接即回放启动以来
  /// 的缓冲历史；stdout/stderr 仅能靠分别订阅两条流区分，故每会话双连接。
  Future<void> _syncVmSessions() async {
    final status = await queryDaemonStatus();
    final uris = <String>{};
    final labels = <String, String>{};
    if (status != null) {
      final sessions = status['sessions'];
      if (sessions is List) {
        for (final session in sessions) {
          if (session is Map) {
            final uri = session['uri']?.toString();
            if (uri != null && uri.isNotEmpty) {
              uris.add(uri);
              labels[uri] = session['source']?.toString() ?? '';
            }
          }
        }
      }
    }
    for (final uri in uris) {
      for (final stream in const <String>['Stdout', 'Stderr', 'Extension']) {
        final key = '$uri|$stream';
        if (_vmSessions.containsKey(key)) {
          continue;
        }
        // 多个 Flutter 应用同时接入时，用会话来源（如 adb:xxx）区分输出。
        final label = (labels[uri] != null && labels[uri]!.isNotEmpty)
            ? labels[uri]!
            : uri;
        late final _VmSession session;
        if (stream == 'Extension') {
          // 异常通道：Flutter 结构化错误（Flutter.Error）经 developer.postEvent
          // 走 Extension 流，探针 v5 实测定论；不走 Isolate 流（协议无异常事件）。
          session = _VmSession(
            uri,
            stream,
            false,
            (line, isStderr) {},
            onEvent: (event) => _onVmExtensionEvent(label, session, event),
          )..connect();
        } else {
          session = _VmSession(
            uri,
            stream,
            stream == 'Stderr',
            (line, isStderr) => _addFlutterLine(label, line, isStderr, session),
          )..connect();
        }
        _vmSessions[key] = session;
      }
    }
    for (final key in _vmSessions.keys.toList()) {
      if (!uris.contains(key.split('|').first)) {
        _vmSessions.remove(key)!.close();
        // 会话断开：把未捕获块解析器的残留半成品立即结算，避免丢尾。
        final tracker = _uncaught.remove(key);
        final rec = tracker?.parser.takePending();
        if (rec != null) {
          _addException(rec, tracker!.label, tracker.session, 'uncaught');
        }
      }
    }
  }

  /// 从会话来源解析精确所属设备（如 adb:SERIAL#port:x → SERIAL；
  /// port:x → null，此时由前端按 VM 平台与设备平台推断归属）。
  static String? _deviceFromSource(String source) {
    final m = RegExp(r'^(?:adb|hdc):([^#]+)#').firstMatch(source);
    return m?.group(1);
  }

  void _addFlutterLine(
    String app,
    String line,
    bool isStderr,
    _VmSession session,
  ) {
    final entry = makeLogEntry(line, isStderr ? 'flutter-stderr' : 'flutter');
    // tag 列存会话来源：多应用同时调试时可区分与过滤（stderr 由 source 列区分）。
    entry['tag'] = app;
    // 记录 VM 所属平台（来自 getVM），供「选中设备 → 包含该设备上的 VM」匹配。
    final os = session.os;
    if (os != null && os.isNotEmpty) {
      entry['os'] = os;
    }
    // 精确归属：来源带设备号时记录，供「VM × 设备」交集过滤。
    final device = _deviceFromSource(app);
    if (device != null && device.isNotEmpty) {
      entry['device'] = device;
    }
    // 应用包名（连接后异步获取，后续行自动带上），供前端展示会话对应的应用。
    final appName = session.appName;
    if (appName != null && appName.isNotEmpty) {
      entry['app'] = appName;
    }
    // 错误通道输出（异常堆栈多走这里）标为 E·错误，便于着色与筛选定位。
    if (isStderr) {
      entry['level'] = 'E';
    }
    addEntry(entry);
    // 未捕获异常块识别（两种格式）：引擎默认 "Unhandled Exception: " 与
    // xb_scaffold XBErrorHandler 的 "XBErrorHandler catch error: "（均经
    // debugPrint 走输出流）。块内后续 #N 帧行由解析器归集，结束后结算入库。
    final tracker =
        _uncaught.putIfAbsent('${session.uri}|${session.streamId}', () {
      return _UncaughtTracker(app, session);
    });
    tracker.session = session;
    tracker.label = app;
    final rec = tracker.parser.feed(line);
    if (rec != null) {
      _addException(rec, tracker.label, session, 'uncaught');
    }
  }

  /// Extension 流事件：只关心 Flutter.Error 结构化异常（探针 v5 实测）。
  void _onVmExtensionEvent(
    String label,
    _VmSession session,
    Map<String, Object?> event,
  ) {
    if (event['kind']?.toString() != 'Extension') return;
    if (event['extensionKind']?.toString() != 'Flutter.Error') return;
    final data = event['extensionData'];
    if (data is! Map) return;
    final rec = parseFlutterError(data);
    if (rec != null) {
      _addException(rec, label, session, 'framework');
    }
  }

  /// 异常入库：连续同摘要同首帧的异常合并计数（避免回放/重复上报刷屏）。
  void _addException(
    Map<String, Object?> rec,
    String label,
    _VmSession session,
    String channel,
  ) {
    final now = DateTime.now();
    final frames = (rec['stack'] as List? ?? <Object?>[]);
    final firstFrame = frames.isNotEmpty && frames.first is Map
        ? (frames.first as Map)['raw']?.toString() ?? ''
        : '';
    final hash = '${rec['summary'] ?? ''}|$firstFrame';
    rec['id'] = ++_excSeq;
    rec['hash'] = hash;
    rec['channel'] = channel;
    rec['source'] = label;
    rec['time'] = _clock();
    rec['ts'] = now.millisecondsSinceEpoch;
    final os = session.os;
    if (os != null && os.isNotEmpty) rec['os'] = os;
    final app = session.appName;
    if (app != null && app.isNotEmpty) rec['app'] = app;
    if (_exceptions.isNotEmpty) {
      final last = _exceptions.last;
      final lastTs = (last['ts'] as int?) ?? 0;
      if (last['hash'] == hash &&
          now.millisecondsSinceEpoch - lastTs < 10000) {
        last['count'] = ((last['count'] as int?) ?? 1) + 1;
        last['time'] = rec['time'];
        last['ts'] = rec['ts'];
        broadcast(<String, Object?>{'type': 'exception', 'item': last});
        return;
      }
    }
    rec['count'] = 1;
    _exceptions.add(rec);
    if (_exceptions.length > 200) {
      _exceptions.removeAt(0);
    }
    broadcast(<String, Object?>{'type': 'exception', 'item': rec});
  }

  /// 设备日志条目：额外携带设备 id，供按设备过滤。
  void addDeviceLog(String deviceId, String source, String raw) {
    final entry = makeLogEntry(raw, source);
    entry['device'] = deviceId;
    addEntry(entry);
  }

  void addLog(String raw, String source) {
    addEntry(makeLogEntry(raw, source));
  }

  void addEntry(Map<String, Object?> entry) {
    entry['rcv'] = _clock();
    // 毫秒时间戳：日志增量过滤/assertLog 时间窗需要可比较的数值时刻
    entry['rcvMs'] = DateTime.now().millisecondsSinceEpoch;
    _buffer.add(entry);
    if (_buffer.length > kMaxBufferLines) {
      _buffer.removeRange(0, _buffer.length - kMaxBufferLines);
    }
    _pending.add(entry);
  }

  void _flush() {
    // 未捕获异常块：帧尾后无新行超过 800ms 则结算（栈末常无后续输出）。
    for (final tracker in _uncaught.values.toList()) {
      final rec = tracker.parser.flushStale();
      if (rec != null) {
        _addException(rec, tracker.label, tracker.session, 'uncaught');
      }
    }
    if (_pending.isEmpty) {
      return;
    }
    final items = List<Map<String, Object?>>.of(_pending);
    _pending.clear();
    broadcast(<String, Object?>{'type': 'logs', 'items': items});
  }
  // -- 客户端与广播 ----------------------------------------------------------

  void addClient(WebSocket ws) {
    _clients.add(ws);
    // 新客户端立即全量同步（设备 + 已缓冲日志 + 异常 + 当前选中）。
    ws.add(jsonEncode(<String, Object?>{
      'type': 'snapshot',
      'devices': devices,
      'selected': selectedId,
      'items': _buffer,
      'exceptions': _exceptions,
    }));
    ws.listen((dynamic message) {
      if (message is! String) {
        return;
      }
      Object? parsed;
      try {
        parsed = jsonDecode(message);
      } catch (_) {
        return;
      }
      if (parsed is! Map) {
        return;
      }
      if (parsed['type'] == 'select') {
        unawaited(selectDevice(parsed['id']?.toString()));
      } else if (parsed['type'] == 'refresh') {
        unawaited(poll());
      }
    }, onDone: () => _clients.remove(ws), onError: (_) => _clients.remove(ws));
  }

  void broadcast(Map<String, Object?> message) {
    if (_clients.isEmpty) {
      return;
    }
    final text = jsonEncode(message);
    for (final ws in _clients.toList()) {
      try {
        ws.add(text);
      } catch (_) {
        _clients.remove(ws);
      }
    }
  }
}

class _VmSession {
  _VmSession(this.uri, this.streamId, this.isStderr, this.onLine,
      {this.onEvent});

  final String uri;

  /// 订阅的流：Stdout / Stderr（WriteEvent 无 source 字段，
  /// 只能靠分别订阅两条流区分 stdout 与 stderr）；Extension（异常等
  /// developer.postEvent 事件，走 onEvent 回调）。
  final String streamId;
  final bool isStderr;
  final void Function(String line, bool isStderr) onLine;

  /// Extension 流的原始事件回调（仅 streamId=Extension 时使用）。
  final void Function(Map<String, Object?> event)? onEvent;
  WebSocket? _socket;
  String _remainder = '';

  /// VM 所属平台（getVM 的 operatingSystem：android/ohos/ios/macos...），
  /// 供「选中设备 → 包含该设备上的 VM」匹配。
  String? os;

  /// 应用包名（getIsolate 的 libraries 中 package:<pkg>/main.dart 的 <pkg>），
  /// 供会话选择器与日志行展示「这是哪个应用」。
  String? appName;

  Future<void> connect() async {
    try {
      final socket = await WebSocket.connect(uri);
      _socket = socket;
      socket.listen(
        _onData,
        onDone: () => _socket = null,
        onError: (dynamic _) => _socket = null,
      );
      // params 必须是 {streamId: ...} 对象（实测传数组会静默订阅失败）。
      socket.add(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 'sl',
        'method': 'streamListen',
        'params': <String, String>{'streamId': streamId},
      }));
      // 订阅响应（id=sl 的成功/失败回复）在 _onData 里统一检查：
      // 不能在这里 await socket.first——socket.listen 已监听该流，
      // 再取 first 会抛「Stream has already been listened to」令整个
      // 订阅失败（实测三条通道全部因此报错重试死循环）。
      // 查询所属平台。
      socket.add(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 'vm',
        'method': 'getVM',
      }));
    } catch (e) {
      print('[xbume-gui] VM service 连接失败 $uri($streamId): $e');
      _socket = null;
    }
  }

  void _onData(dynamic message) {
    if (message is! String) {
      return;
    }
    Object? parsed;
    try {
      parsed = jsonDecode(message);
    } catch (_) {
      return;
    }
    if (parsed is! Map) {
      return;
    }
    // streamListen 响应：失败必须显式暴露，静默吞掉会导致该通道永久无数据。
    if (parsed['id'] == 'sl') {
      if (parsed['error'] != null) {
        stderr.writeln('[xbume-gui] streamListen($streamId) 被拒: $uri ${
          jsonEncode(parsed['error'])
        }');
      }
      return;
    }
    // getVM 响应：记录所属平台，并查询 root isolate 拿应用包名。
    if (parsed['id'] == 'vm' && parsed['result'] is Map) {
      final result = parsed['result'] as Map;
      os = result['operatingSystem']?.toString();
      final isolates = result['isolates'];
      if (isolates is List && isolates.isNotEmpty && isolates.first is Map) {
        final isolateId = isolates.first['id']?.toString();
        if (isolateId != null && isolateId.isNotEmpty) {
          _socket?.add(jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 'iso',
            'method': 'getIsolate',
            'params': <String, String>{'isolateId': isolateId},
          }));
        }
      }
      return;
    }
    // getIsolate 响应：从 libraries 解析应用包名（rootLib 实测为空，不可用）。
    if (parsed['id'] == 'iso' && parsed['result'] is Map) {
      final libraries = (parsed['result'] as Map)['libraries'];
      if (libraries is List) {
        for (final lib in libraries) {
          final libUri = lib is Map ? lib['uri']?.toString() : null;
          final m = libUri == null
              ? null
              : RegExp(r'^package:([^/]+)/main\.dart$').firstMatch(libUri);
          if (m != null) {
            appName = m.group(1);
            break;
          }
        }
        // 预热包路径表：异常栈 package: → 本机文件解析依赖此缓存
        //（与 routelocate 共用 _pkgRootsFor）。
        final fileUris = libraries
            .whereType<Map>()
            .map((l) => l['uri']?.toString() ?? '')
            .where((u) => u.startsWith('file:///'))
            .toList()
            .cast<String>();
        final projectRoot = _projectRootFor(fileUris);
        if (projectRoot != null) {
          _pkgRootsFor(projectRoot);
        }
      }
      return;
    }
    final params = parsed['params'];
    if (params is! Map) {
      return;
    }
    final event = params['event'];
    if (event is! Map) {
      return;
    }
    // Extension 流：整体交给 onEvent（异常解析在 GuiState 侧）。
    if (streamId == 'Extension') {
      if (onEvent != null) {
        onEvent!(Map<String, Object?>.from(event));
      }
      return;
    }
    final kind = event['kind']?.toString();
    // flutter run 的控制台输出实测为 kind=WriteEvent（DDS 转发）。
    if (kind != 'Stdout' && kind != 'Stderr' && kind != 'WriteEvent') {
      return;
    }
    final bytes = event['bytes'];
    if (bytes is! String) {
      return;
    }
    final isStderr = this.isStderr || event['source'] == 'Stderr';
    final text = utf8.decode(base64.decode(bytes), allowMalformed: true);
    final lines = (_remainder + text).split('\n');
    _remainder = lines.removeLast();
    for (final line in lines) {
      final trimmed = line.trimRight();
      if (trimmed.isNotEmpty) {
        onLine(trimmed, isStderr);
      }
    }
  }

  void close() {
    try {
      _socket?.close();
    } catch (_) {
      // ignored
    }
    _socket = null;
  }
}

/// 未捕获异常解析器的会话级跟踪（key: uri|stream，含来源标签供结算入库）。
class _UncaughtTracker {
  _UncaughtTracker(this.label, this.session);

  String label;
  _VmSession session;
  final _UncaughtParser parser = _UncaughtParser();
}

/// 从 flutter 输出行流识别未捕获异常块的状态机。
///
/// 支持两种格式（探针实测定论）：
///   1. 引擎默认：`Unhandled Exception: <err>` + `#N ... (package:...:L:C)` 帧；
///   2. xb_scaffold XBErrorHandler：`XBErrorHandler catch error: <err>` + 帧。
/// debugPrint 每行输出自带空行分隔（WriteEvent 实测为 "行\n\n\n"），
/// 空行不作为块结束信号；非空非帧行、达到上限或长时间无新行时结算。
class _UncaughtParser {
  static final RegExp _headRe =
      RegExp(r'^(?:flutter: )?(?:Unhandled Exception: |XBErrorHandler catch error: )(.*)$');
  static final RegExp _frameRe =
      RegExp(r'^#\s*(\d+)\s+(.*?)\s+\((.+?):(\d+):(\d+)\)$');
  // 无位置的帧行（如 eval 生成的 "#0  Eval...<...>()"、异步栈尾帧）：
  // 仍属栈内容，保留原文，不能当块结束处理（否则整块被丢弃）。
  static final RegExp _frameNoPosRe = RegExp(r'^#\s*\d+');

  static const int _maxFrames = 120;

  Map<String, Object?>? _pending;
  final List<Map<String, Object?>> _frames = <Map<String, Object?>>[];
  DateTime _lastTouch = DateTime.now();

  /// 喂一行原始输出；块结束时返回记录，否则返回 null（仍在块内）。
  Map<String, Object?>? feed(String raw) {
    _lastTouch = DateTime.now();
    var line = raw;
    // debugPrint 经 WriteEvent 每行带 "flutter: " 前缀（探针实测）。
    if (line.startsWith('flutter: ')) {
      line = line.substring('flutter: '.length);
    }
    line = line.trimRight();
    if (_pending == null) {
      final m = _headRe.firstMatch(line);
      if (m == null) return null;
      _pending = <String, Object?>{'summary': m.group(1)!};
      _frames.clear();
      return null;
    }
    if (line.isEmpty) {
      // 帧行之间的空行是 debugPrint 分隔噪声，不算块结束。
      return null;
    }
    final m = _frameRe.firstMatch(line);
    if (m != null) {
      final uri = m.group(3)!;
      _frames.add(<String, Object?>{
        'i': int.parse(m.group(1)!),
        'method': m.group(2),
        'uri': uri,
        'line': int.parse(m.group(4)!),
        'col': int.parse(m.group(5)!),
        // flutter/dart 帧不入跳转候选，用户包帧才解析本机文件。
        'file': (uri.startsWith('dart:') || uri.startsWith('package:flutter/'))
            ? null
            : _resolveLibraryFile(uri),
        'raw': line,
      });
      if (_frames.length >= _maxFrames) {
        return takePending();
      }
      return null;
    }
    if (line.startsWith('...')) {
      _frames.add(<String, Object?>{'raw': line});
      return null;
    }
    // 无位置的帧（如 "#0  Eval.<anonymous closure> ()"）：保留原文入栈。
    if (_frameNoPosRe.hasMatch(line)) {
      _frames.add(<String, Object?>{'raw': line});
      if (_frames.length >= _maxFrames) {
        return takePending();
      }
      return null;
    }
    // 非空非帧非省略：块结束（后文是普通输出）。
    return takePending();
  }

  /// 超时无新行则结算（帧尾后无后续输出时收尾），由 _flush 周期调用。
  Map<String, Object?>? flushStale() {
    if (_pending == null || _frames.isEmpty) return null;
    if (DateTime.now().difference(_lastTouch).inMilliseconds < 800) {
      return null;
    }
    return takePending();
  }

  /// 强制结算（会话断开 / 超时）；无内容返回 null。
  Map<String, Object?>? takePending() {
    final pending = _pending;
    _pending = null;
    if (pending == null) return null;
    if (_frames.isEmpty) return null;
    pending['stack'] = List<Map<String, Object?>>.of(_frames);
    _frames.clear();
    return pending;
  }
}

/// Dart 栈帧行正则（结构化事件与输出流两种通道共用）。
final RegExp _excFrameRe =
    RegExp(r'^#\s*(\d+)\s+(.*?)\s+\((.+?):(\d+):(\d+)\)$');

/// 解析单个栈帧行 → 帧记录（带可跳转的本机文件；无位置信息的省略行只留 raw）。
Map<String, Object?> _excParseFrame(String raw) {
  final m = _excFrameRe.firstMatch(raw);
  if (m == null) {
    return <String, Object?>{'raw': raw};
  }
  final uri = m.group(3)!;
  return <String, Object?>{
    'i': int.parse(m.group(1)!),
    'method': m.group(2),
    'uri': uri,
    'line': int.parse(m.group(4)!),
    'col': int.parse(m.group(5)!),
    // flutter/dart 帧不入跳转候选，用户包帧才解析本机文件。
    'file': (uri.startsWith('dart:') || uri.startsWith('package:flutter/'))
        ? null
        : _resolveLibraryFile(uri),
    'raw': raw,
  };
}

/// 解析 Flutter.Error 结构化事件（widget_inspector._reportStructuredError 经
/// developer.postEvent 发出；探针 v5 实测字段）。失败返回 null。
Map<String, Object?>? parseFlutterError(Map data) {
  final properties =
      (data['properties'] as List? ?? <Object?>[]).whereType<Map>();
  String? summary;
  String? desc;
  String? widget;
  final frames = <Map<String, Object?>>[];
  for (final p in properties) {
    final type = p['type']?.toString() ?? '';
    final d = p['description']?.toString() ?? '';
    if (type == 'ErrorSummary') {
      summary ??= d;
    } else if (type == 'ErrorDescription' && d.isNotEmpty) {
      desc ??= d;
    } else if (type == 'DiagnosticsBlock') {
      for (final child
          in (p['children'] as List? ?? <Object?>[]).whereType<Map>()) {
        final cd = child['description']?.toString() ?? '';
        if (cd.isNotEmpty && widget == null) widget = cd;
      }
    } else if (type == 'DiagnosticsStackTrace') {
      for (final f
          in (p['properties'] as List? ?? <Object?>[]).whereType<Map>()) {
        final raw = f['description']?.toString() ?? '';
        if (raw.isNotEmpty) frames.add(_excParseFrame(raw));
      }
    }
  }
  final summaryText = summary ?? data['description']?.toString();
  if (summaryText == null || summaryText.isEmpty) {
    return null;
  }
  final rec = <String, Object?>{
    'summary': summaryText,
    if (desc != null && desc.isNotEmpty) 'desc': desc,
    if (widget != null) 'widget': widget,
    if (frames.isNotEmpty) 'stack': frames,
    'errorsSinceReload': data['errorsSinceReload'],
    if (data['renderedErrorText'] != null)
      'rendered': data['renderedErrorText'],
  };
  // 相关 widget 行内嵌 file:/// 位置（如 KeyedSubtree:file:///...dart:109:13），
  // 提取出来供「跳转」。
  if (widget != null) {
    final m = RegExp(r'file://(/.+?):(\d+):(\d+)\s*$').firstMatch(widget);
    if (m != null) {
      final f = File(m.group(1)!);
      if (f.existsSync()) {
        rec['widgetFile'] = m.group(1);
        rec['widgetLine'] = int.parse(m.group(2)!);
      }
    }
  }
  return rec;
}

/// 路径嵌入 evaluate 表达式的转义（app 端普通字符串）。
String _escPath(String p) =>
    p.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

/// P9：Element 树全量拉取表达式（binding.dart 上下文可见 WidgetsBinding/Element）。
/// 输出格式：每行 深度\u0001 类型 \u0001 key\u0001 bounds(x,y,w,h 逻辑像素，无则为空)\u0003；
/// 末尾额外跟一个空行 + dpr\u0001物理宽\u0001物理高。不用 Dart 模板字符串（避开多层转义）。
const String _wtreeExpr = "(() { final v = WidgetsBinding.instance.platformDispatcher.views.first; "
    "final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return 'NO_ROOT'; "
    "final out = StringBuffer(); final sep = String.fromCharCode(1); "
    "final row = String.fromCharCode(3); final se = <Element>[root]; final sd = <int>[0]; "
    "while (se.isNotEmpty) { final e = se.removeLast(); final d = sd.removeLast(); "
    "var b = ''; final r = e.renderObject; "
    "if (r is RenderBox && r.attached) { final p = r.localToGlobal(r.paintBounds.topLeft); "
    "b = p.dx.round().toString() + ',' + p.dy.round().toString() + ',' "
    "+ r.paintBounds.width.round().toString() + ',' + r.paintBounds.height.round().toString(); } "
    "var k = ''; final key = e.widget.key; if (key != null) { k = key.toString(); "
    "if (k.length > 60) { k = k.substring(0, 60); } } "
    "out.write(d.toString()); out.write(sep); out.write(e.widget.runtimeType.toString()); "
    "out.write(sep); out.write(k); out.write(sep); out.write(b); out.write(row); "
    "final kids = <Element>[]; e.visitChildren(kids.add); "
    "for (var i = kids.length - 1; i >= 0; i--) { se.add(kids[i]); sd.add(d + 1); } } "
    "out.write(row); out.write(v.devicePixelRatio.toString()); out.write(sep); "
    "out.write(v.physicalSize.width.round().toString()); out.write(sep); "
    "out.write(v.physicalSize.height.round().toString()); return out.toString(); })()";

/// P9b：点截图反查表达式（calculator.dart 上下文：locator 间距计算器本库可见、
/// widgets.dart 导出 inspector 的 DiagnosticsNode/InspectorSerializationDelegate）。
/// 逻辑：命中点收集 → 面积升序 → 逐 hit 向上找 creationLocation 非 Flutter SDK
/// 的最近业务组件（locator 同款判定，优先非 pub-cache）→ 调
/// XBUmeWidgetSpacingCalculator 算四向间距（searchRoot 限定 xb_ume_app_root 内）。
/// 输出：PICK\u0003 type\u0001file\u0001line\u0001col\u0001bounds \u0003 每向 dir\u0001dist\u0001srcType\u0001srcKind\u0001srcRect；
/// 无命中 MISS；命中但全为 SDK 组件 NOBIZ。坐标 PX,PY 由 GUI 拼入。
const String _wpickExprHead =
    "(() { final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return 'NO_ROOT'; "
    "final pt = Offset(";
const String _wpickExprMid = ", ";
const String _wpickExprBody =
    "); final hits = <Element>[]; final se = <Element>[root]; "
    "while (se.isNotEmpty) { final e = se.removeLast(); final r = e.renderObject; "
    "if (r is RenderBox && r.attached && r.hasSize) { "
    "final tl = r.localToGlobal(Offset.zero); final rect = tl & r.size; "
    "if (rect.width > 0 && rect.height > 0 && rect.contains(pt)) { hits.add(e); } } "
    "final kids = <Element>[]; e.visitChildren(kids.add); "
    "for (var i = kids.length - 1; i >= 0; i--) { se.add(kids[i]); } } "
    "if (hits.isEmpty) return 'MISS'; "
    "hits.sort((a, b) { final ra = a.renderObject as RenderBox; "
    "final rb = b.renderObject as RenderBox; "
    "return (ra.size.width * ra.size.height).compareTo(rb.size.width * rb.size.height); }); "
    "bool isSdk(String f) { final l = f.toLowerCase(); return l.startsWith('dart:') "
    "|| l.startsWith('package:flutter/') || l.contains('/packages/flutter/'); } "
    "bool isPub(String f) { final l = f.toLowerCase(); return l.contains('pub-cache') "
    "|| l.contains('pub/cache') || l.contains('/hosted/pub.'); } "
    "String? locFile(Element e) { try { final jm = e.toDiagnosticsNode() "
    ".toJsonMap(InspectorSerializationDelegate(service: WidgetInspectorService.instance, "
    "includeProperties: false, subtreeDepth: 1)); final loc = jm['creationLocation']; "
    "if (loc is Map) { return (loc['file'] ?? '').toString(); } } catch (_) {} return null; } "
    "Element? pick = null; String pfile = ''; Element? anyNonSdk = null; String afile = ''; "
    "var steps = 0; "
    "void tryOne(Element e) { if (pick != null || steps >= 150) return; steps++; final f = locFile(e); "
    "if (f != null && f.isNotEmpty) { if (anyNonSdk == null && !isSdk(f)) { anyNonSdk = e; afile = f; } "
    "if (!isSdk(f) && !isPub(f)) { pick = e; pfile = f; } } } "
    "for (final h in hits) { tryOne(h); "
    "h.visitAncestorElements((Element anc) { tryOne(anc); return pick == null; }); "
    "if (pick != null) break; } "
    "if (pick == null) { pick = anyNonSdk; pfile = afile; } "
    "if (pick == null) return 'NOBIZ'; "
    "final pr = pick!.renderObject; String pb = ''; "
    "if (pr is RenderBox && pr.hasSize) { final tl = pr.localToGlobal(Offset.zero); "
    "pb = tl.dx.round().toString() + ',' + tl.dy.round().toString() + ',' "
    "+ pr.size.width.round().toString() + ',' + pr.size.height.round().toString(); } "
    "final jm2 = pick!.toDiagnosticsNode().toJsonMap(InspectorSerializationDelegate(" 
    "service: WidgetInspectorService.instance, includeProperties: false, subtreeDepth: 1)); "
    "final loc0 = jm2['creationLocation']; int pl = 0; int pc = 0; "
    "if (loc0 is Map) { final f2 = (loc0['file'] ?? '').toString(); "
    "if (f2.isNotEmpty) { pfile = f2; } pl = (loc0['line'] as num?)?.toInt() ?? 0; "
    "pc = (loc0['column'] as num?)?.toInt() ?? 0; } "
    "final ptype = pick!.widget.runtimeType.toString(); "
    "Element? appRoot = null; final se2 = <Element>[root]; "
    "while (se2.isNotEmpty) { final e2 = se2.removeLast(); final k2 = e2.widget.key; "
    "if (k2 != null && k2.toString().contains('xb_ume_app_root')) { appRoot = e2; break; } "
    "final kids2 = <Element>[]; e2.visitChildren(kids2.add); "
    "for (var i2 = kids2.length - 1; i2 >= 0; i2--) { se2.add(kids2[i2]); } } "
    "final sp = XBUmeWidgetSpacingCalculator().calculate(pick!, searchRoot: appRoot); "
    "final sep = String.fromCharCode(1); final row = String.fromCharCode(3); "
    "final out = StringBuffer(); out.write('PICK'); out.write(row); "
    "out.write(ptype); out.write(sep); out.write(pfile); out.write(sep); "
    "out.write(pl.toString()); out.write(sep); out.write(pc.toString()); out.write(sep); "
    "out.write(pb); out.write(row); "
    "if (sp != null) { for (final it in sp.items) { String dir; "
    "switch (it.direction) { case XBUmeSpacingDirection.up: dir = 'up'; break; "
    "case XBUmeSpacingDirection.down: dir = 'down'; break; "
    "case XBUmeSpacingDirection.left: dir = 'left'; break; "
    "case XBUmeSpacingDirection.right: dir = 'right'; break; } "
    "String srect = ''; final sr = it.sourceRect; "
    "if (sr != null) { srect = sr.left.round().toString() + ',' + sr.top.round().toString() "
    "+ ',' + sr.width.round().toString() + ',' + sr.height.round().toString(); } "
    "out.write(dir); out.write(sep); out.write(it.distance.toStringAsFixed(1)); out.write(sep); "
    "out.write(it.sourceWidgetType ?? 'parent'); out.write(sep); "
    "out.write(it.source == XBUmeSpacingSource.parentEdge ? 'parent' : 'widget'); out.write(sep); "
    "out.write(srect); out.write(row); } } "
    "return out.toString(); })()";

/// 返回字节列表中最后一个完整 UTF-8 序列之后的偏移；末尾若是不完整
/// 的多字节序列（被分片大小切断），返回该序列起点，避免解码出替换符。
int _utf8CompleteBoundary(List<int> b) {
  final n = b.length;
  if (n == 0) return 0;
  var i = n - 1;
  var cont = 0;
  while (i >= 0 && (b[i] & 0xC0) == 0x80) {
    i--;
    cont++;
  }
  if (i < 0) return n; // 全为 continuation 字节的异常流，交给容错解码
  final lead = b[i];
  final expected = lead < 0x80
      ? 1
      : (lead & 0xE0) == 0xC0
          ? 2
          : (lead & 0xF0) == 0xE0
              ? 3
              : (lead & 0xF8) == 0xF0
                  ? 4
                  : 1;
  return cont + 1 < expected ? i : n;
}

/// 任意文本嵌入 evaluate 表达式字符串字面量的转义（XML 写回等）。
/// 注意 $ 是 Dart 字符串插值符，必须一并转义。
String _escEvalString(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll(r'$', r'\$')
    .replaceAll("'", r"\'")
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll('\t', r'\t');

// ── P10 自动化路径：场景执行引擎 ──

/// tap：GestureBinding.handlePointerEvent down+up 同点（binding.dart 上下文，
/// 实测可驱动真实 UI 导航/点击）。phys=true 时坐标为截图物理像素（除 dpr）。
/// 每次注入唯一 pointer id：PointerDownEvent 默认 pointer=0，若 down 派发中
/// 业务抛异常导致 up 未发，_hitTests 残留 pointer 0 会让后续所有 tap 撞
/// '!_hitTests.containsKey(event.pointer)' 断言永久卡死（f_jlink 实测）。
int _nextPointer() => DateTime.now().microsecondsSinceEpoch & 0x3fffffff;

String _autoTapExpr(String x, String y, {bool phys = false, int pointer = 0}) {
  final pos = phys
      ? "final pos = Offset($x, $y) / WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; "
      : "final pos = Offset($x, $y); ";
  // down 派发中业务异常时仍补发 up（释放指针）并返回错误摘要；不 rethrow——
  // 异常经 FlutterError 上报时 inspector 序列化 eval 栈帧会二次炸
  // stack_frame.dart 断言，污染错误信息。
  return "(() { $pos"
      "final pe = PointerDownEvent(pointer: $pointer, position: pos); "
      "try { GestureBinding.instance.handlePointerEvent(pe); } catch (e) { "
      "GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: $pointer, position: pos)); "
      "return 'ERR:' + e.toString(); } "
      "GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: $pointer, position: pos)); "
      "return 'OK'; })()";
}

/// input：直接调当前焦点 client 的 updateEditingValue（该 Flutter 版本
/// TextInput 是实例单例：TextInput._instance._currentConnection?._client）。
/// 需先 tap 输入框建立 TextInputConnection，否则返回 NO_CONN。
String _autoInputExpr(String text) =>
    "(() { final c = TextInput._instance._currentConnection; "
    "if (c == null) return 'NO_CONN'; "
    "final s = '${_escEvalString(text)}'; "
    "(c._client as dynamic).updateEditingValue(TextEditingValue("
    "text: s, selection: TextSelection.collapsed(offset: s.length))); "
    "return 'OK'; })()";

/// assertVisible：树中存在类型匹配（支持泛型前缀）且 renderObject
/// 是有尺寸的 RenderBox。
String _autoAssertVisibleExpr(String type) {
  final t = _escEvalString(type);
  return "(() { final root = WidgetsBinding.instance.renderViewElement; "
      "if (root == null) return 'NO_ROOT'; "
      "final se = <Element>[root!]; "
      "while (se.isNotEmpty) { final e = se.removeLast(); "
      "final t = e.widget.runtimeType.toString(); var ok = t == '$t'; "
      "if (!ok) { final g = t.indexOf('<'); if (g > 0 && t.substring(0, g) == '$t') ok = true; } "
      "if (ok) { final r = e.renderObject; if (r is RenderBox && r.attached "
      "&& r.hasSize && r.size.width > 0 && r.size.height > 0) return 'FOUND'; } "
      "final kids = <Element>[]; e.visitChildren(kids.add); "
      "for (var i = kids.length - 1; i >= 0; i--) se.add(kids[i]); } "
      "return 'NOT_FOUND'; })()";
}

/// 路由栈快照（navigator.dart 上下文）：每个 Navigator 的历史路由名用逗号拼接。
const String _autoRoutesExpr =
    "(() { final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return 'NO_ROOT'; "
    "final navs = <NavigatorState>[]; "
    "void walk(Element e) { final w = e.widget; "
    "if (w is Navigator && e is StatefulElement && e.state is NavigatorState) "
    "{ navs.add(e.state as NavigatorState); } e.visitChildren(walk); } "
    "root.visitChildren(walk); "
    "if (navs.isEmpty) return 'NO_NAV'; "
    "final out = StringBuffer(); "
    "for (final h in navs[0]._history) { out.write(h.route.settings.name); "
    "out.write(String.fromCharCode(44)); } return out.toString(); })()";

/// 单步执行结果。
class _AutoStepResult {
  _AutoStepResult(this.index, this.type, this.expect);
  final int index;
  final String type;
  final String expect;
  String status = 'running'; // running | pass | fail | skip
  var ms = 0;
  String actual = '';
  String error = '';
  String? shot; // 步骤截图文件名（artifacts 目录下）
  Map<String, Object?> toJson() => <String, Object?>{
        'index': index,
        'type': type,
        'status': status,
        'ms': ms,
        'expect': expect,
        'actual': actual,
        'error': error,
        'shot': shot,
      };
}

/// 一次场景运行的状态（GUI 同一时间只跑一个场景）。
class _AutoRunState {
  bool running = false;
  bool stopReq = false;
  String uri = '';
  String name = '';
  var cur = 0;
  List<_AutoStepResult> results = [];
  String runId = '';
  DateTime startedAt = DateTime.now();
  Map<String, Object?> statusJson() => <String, Object?>{
        'running': running,
        'name': name,
        'cur': cur,
        'total': results.length,
        'startedAt': startedAt.toIso8601String(),
        'results': results.map((r) => r.toJson()).toList(),
      };
}

final _auto = _AutoRunState();

String get _autoScenariosDir => '$_home/.xb_ume_ide/scenarios';
String get _autoArtifactsDir => '$_home/.xb_ume_ide/scenarios/artifacts';

/// 场景名非法时的统一提示（400 响应与前端预校验共用）。
const String _autoNameError =
    '场景名非法：只允许中文/字母/数字/下划线/横线，长度 1-64（不能含空格、点号等）';

/// 场景名 → json 文件；名字只允许字母数字下划线中横线中文，防穿越。
File? _autoScenarioFile(String name) {
  final n = name.trim();
  if (n.isEmpty || n.length > 64) return null;
  if (!RegExp(r'^[\w\u4e00-\u9fff-]+$').hasMatch(n)) return null;
  return File('$_autoScenariosDir/$n.json');
}

/// 步骤截图（失败/报告用）：返回文件名，截图失败返回 null。
Future<String?> _autoShot(String uri, String runId, int index) async {
  final rpc = _SandboxRpc(uri);
  try {
    final r = await rpc.rawRpc('_flutter.screenshot');
    final b64 = (r['data'] ?? r['screenshot'])?.toString() ?? '';
    if (b64.isEmpty) return null;
    final dir = Directory(_autoArtifactsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = '$runId-step$index.png';
    File('$_autoArtifactsDir/$f').writeAsBytesSync(base64Decode(b64));
    return f;
  } catch (_) {
    return null;
  } finally {
    await rpc.close();
  }
}

/// 单步执行：返回 (actual, error)；error 非空即失败。
Future<(String, String)> _autoExecStep(
    String uri, Map<String, dynamic> st) async {
  final type = (st['type'] ?? '').toString().trim();
  final rpc = _SandboxRpc(uri);
  try {
    switch (type) {
      case 'tap':
        final x = (st['x'] as num?)?.toDouble();
        final y = (st['y'] as num?)?.toDouble();
        if (x == null || y == null) return ('', 'tap 需要 x/y 数值坐标');
        final s = await rpc.evalStringOn(
            'package:flutter/src/widgets/binding.dart',
            _autoTapExpr(x.toString(), y.toString(),
                phys: (st['phys'] ?? false) == true, pointer: _nextPointer()));
        return (s, s == 'OK' ? '' : (s.startsWith('ERR:') ? 'tap 派发异常: ${s.substring(4)}' : 'tap 注入异常: $s'));
      case 'swipe':
        final x1 = (st['x1'] as num?)?.toDouble();
        final y1 = (st['y1'] as num?)?.toDouble();
        final x2 = (st['x2'] as num?)?.toDouble();
        final y2 = (st['y2'] as num?)?.toDouble();
        if (x1 == null || y1 == null || x2 == null || y2 == null) {
          return ('', 'swipe 需要 x1/y1/x2/y2');
        }
        final ms = (st['ms'] as num?)?.toInt() ?? 300;
        const seg = 8;
        final moveMs = (ms / seg).round().clamp(16, 200);
        final phys = (st['phys'] ?? false) == true;
        // 物理模式：坐标在表达式内先除 dpr 转逻辑像素，再走同一逻辑坐标路径。
        String px(double v) => phys ? '($v / d)' : v.toString();
        // 全程同一唯一 pointer id（down 异常时仍发 up 释放，见 _autoTapExpr）。
        final pid = _nextPointer();
        // 真实触摸事件的 timeStamp 递增（VelocityTracker 算 fling 速度依赖它），
        // move 事件必须显式传 delta：DragGestureRecognizer 用 event.delta 累计
        // 位移判 touchSlop（monodrag.dart _pendingDragOffset += event.delta），
        // 合成 PointerMoveEvent 默认 delta=Offset.zero → 永远超不过 slop →
        // drag 永不启动（实测 f_jlink 真机与 macOS example 上 swipe 均无法
        // 滚动列表，而 tap 不依赖这两者所以有效）。delta 取相邻逻辑像素差。
        final tsBase = DateTime.now().microsecondsSinceEpoch;
        final downUs = '$tsBase';
        const ctx = 'package:flutter/src/widgets/binding.dart';
        String downReply;
        try {
          downReply = await rpc.evalStringOn(ctx,
              "(() { final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; "
              "try { GestureBinding.instance.handlePointerEvent("
              "PointerDownEvent(pointer: $pid, position: Offset(${px(x1)}, ${px(y1)}), timeStamp: Duration(microseconds: $downUs))); } catch (e) { "
              "GestureBinding.instance.handlePointerEvent("
              "PointerUpEvent(pointer: $pid, position: Offset(${px(x1)}, ${px(y1)}))); "
              "return 'ERR:' + e.toString(); } return 'OK'; })()");
        } catch (e) {
          return ('', 'swipe down 注入失败: $e');
        }
        if (downReply != 'OK') {
          return ('', 'swipe down 异常: ${downReply.startsWith('ERR:') ? downReply.substring(4) : downReply}');
        }
        var pmx = x1;
        var pmy = y1;
        for (var i = 1; i <= seg; i++) {
          final t = i / seg;
          final mx = x1 + (x2 - x1) * t;
          final my = y1 + (y2 - y1) * t;
          final tsUs = tsBase + (ms * 1000 * t).round();
          await rpc.evalStringOn(ctx,
              "(() { final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; "
              "GestureBinding.instance.handlePointerEvent("
              "PointerMoveEvent(pointer: $pid, position: Offset(${px(mx)}, ${px(my)}), "
              "delta: Offset(${px(mx)} - ${px(pmx)}, ${px(my)} - ${px(pmy)}), "
              "timeStamp: Duration(microseconds: $tsUs))); return 'OK'; })()");
          pmx = mx;
          pmy = my;
          await Future.delayed(Duration(milliseconds: moveMs));
        }
        await rpc.evalStringOn(ctx,
            "(() { final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; "
            "GestureBinding.instance.handlePointerEvent("
            "PointerUpEvent(pointer: $pid, position: Offset(${px(x2)}, ${px(y2)}), timeStamp: Duration(microseconds: ${tsBase + ms * 1000}))); return 'OK'; })()");
        return ('swipe (${x1.round()},${y1.round()})->(${x2.round()},${y2.round()})', '');
      case 'input':
        final text = (st['text'] ?? '').toString();
        // _instance/_currentConnection 是 text_input.dart 库内私有，
        // 必须在该库上下文 eval（binding.dart 上下文会 Member not found）。
        final s = await rpc.evalStringOn(
            'package:flutter/src/services/text_input.dart', _autoInputExpr(text));
        return (s, s == 'OK' ? '' : s == 'NO_CONN' ? '无焦点输入框（先 tap 输入框）' : '注入异常: $s');
      case 'wait':
        final ms = (st['ms'] as num?)?.toInt() ?? 500;
        await Future.delayed(Duration(milliseconds: ms.clamp(0, 60000)));
        return ('waited $ms ms', '');
      case 'back':
        final s = await rpc.evalStringOn(
            'package:flutter/src/widgets/navigator.dart', _autoRoutesExpr);
        if (s == 'NO_ROOT' || s == 'NO_NAV') return (s, '无路由栈');
        final names = s.split(',').where((e) => e.isNotEmpty).toList();
        if (names.length <= 1) return ('${names.length} route', '已是最后一个路由，无法返回');
        final op = await _autoRouteOp(uri, 'pop', idx: names.length - 1);
        return (op, op == 'OK' ? '' : 'pop 失败: $op');
      case 'navigate':
        final name = (st['name'] ?? '').toString();
        if (name.isEmpty) return ('', 'navigate 需要 name');
        final op = await _autoRouteOp(uri, 'push', name: name);
        return (op, op == 'OK' ? '' : 'push 失败: $op');
      case 'assertVisible':
        // 目标类型用独立 widget 字段（type 被步骤类型占用，不能重复键）。
        final t = (st['widget'] ?? '').toString().trim();
        if (t.isEmpty) return ('', 'assertVisible 需要 widget（页面/组件类名）');
        final s = await rpc.evalStringOn(
            'package:flutter/src/widgets/binding.dart', _autoAssertVisibleExpr(t));
        return (s, s == 'FOUND' ? '' : s == 'NOT_FOUND' ? '树中不存在可见的 $t' : '查找异常: $s');
      case 'assertRoute':
        final name = (st['name'] ?? '').toString();
        final s = await rpc.evalStringOn(
            'package:flutter/src/widgets/navigator.dart', _autoRoutesExpr);
        if (s == 'NO_ROOT' || s == 'NO_NAV') return (s, '无路由栈');
        final names = s.split(',').where((e) => e.isNotEmpty).toList();
        final top = names.isEmpty ? '' : names.last;
        return (top,
            name.isEmpty || top.contains(name) ? '' : '栈顶路由 $top 不匹配 $name');
      case 'assertInstance':
        final cls = (st['class'] ?? '').toString().trim();
        if (cls.isEmpty) return ('', 'assertInstance 需要 class');
        final n = await _autoInstanceCount(uri, cls);
        return ('$n 个', n > 0 ? '' : '堆/树上不存在 $cls 实例');
      case 'eval':
        final expr = (st['expr'] ?? '').toString();
        if (expr.isEmpty) return ('', 'eval 需要 expr');
        final s = await rpc.evalStringOn(
            'package:flutter/src/widgets/binding.dart', expr);
        final expect = (st['expect'] ?? '').toString();
        return (s,
            expect.isEmpty || s.contains(expect) ? '' : '期望包含「$expect」实际「$s」');
      case 'assertText':
        final contains = (st['contains'] ?? '').toString();
        final notContains = (st['notContains'] ?? '').toString();
        if (contains.isEmpty && notContains.isEmpty) {
          return ('', 'assertText 需要 contains 或 notContains');
        }
        if (_aiCtx()['text'] != true) {
          return ('', 'SKIPPED: 页面文本上下文开关已关闭（AI 设置）');
        }
        final s = await rpc.evalStringOn(
            'package:flutter/src/widgets/binding.dart',
            _aiPageTextExpr(limit: 200));
        final texts = s.split('\u0002').where((e) => e.isNotEmpty).toList();
        if (contains.isNotEmpty) {
          final hit = texts.where((e) => e.contains(contains)).toList();
          return (hit.isEmpty ? '未命中' : '命中: ${hit.take(3).join(' / ')}',
              hit.isEmpty ? '页面文本中未找到「$contains」' : '');
        }
        final bad = texts.where((e) => e.contains(notContains)).toList();
        return (bad.isEmpty ? '未出现「$notContains」' : '仍存在: ${bad.take(3).join(' / ')}',
            bad.isEmpty ? '' : '页面文本中不应出现「$notContains」');
      case 'assertRequest':
        final url = (st['urlContains'] ?? '').toString().trim();
        if (url.isEmpty) return ('', 'assertRequest 需要 urlContains');
        if (_aiCtx()['net'] != true) {
          return ('', 'SKIPPED: 网络上下文开关已关闭（AI 设置）');
        }
        final method = (st['method'] ?? '').toString().trim().toUpperCase();
        final neg = (st['not'] ?? false) == true;
        final within = (st['withinLastMs'] as num?)?.toInt();
        // 时间窗：显式 withinLastMs > AI 运行起点（回放场景兑底近 5 分钟）
        final since = within != null
            ? DateTime.now().subtract(Duration(milliseconds: within))
            : (_ai.running
                ? _ai.startedAt
                : DateTime.now().subtract(const Duration(minutes: 5)));
        final recs = await _aiNetRecords(uri, since: since, limit: 100);
        final matched = recs.where((e) =>
            e['url'].toString().contains(url) &&
            (method.isEmpty ||
                e['method'].toString().toUpperCase() == method)).toList();
        final desc = matched
            .map((e) => '${e['method']} ${e['url']} ${e['statusCode']}')
            .join(' · ');
        if (neg) {
          return (matched.isEmpty ? '无匹配（符合预期）' : desc,
              matched.isEmpty ? '' : '不应出现的请求出现了：$desc');
        }
        return (matched.isEmpty
                ? '窗口内 ${recs.length} 条请求，无匹配'
                : desc,
            matched.isEmpty
                ? '窗口内无匹配请求（urlContains=$url${method.isEmpty ? '' : ' method=$method'}）'
                : '');
      case 'assertLog':
        final contains = (st['contains'] ?? '').toString();
        final notContains = (st['notContains'] ?? '').toString();
        if (contains.isEmpty && notContains.isEmpty) {
          return ('', 'assertLog 需要 contains 或 notContains');
        }
        if (_aiCtx()['log'] != true) {
          return ('', 'SKIPPED: 日志上下文开关已关闭（AI 设置）');
        }
        final lv = (st['level'] ?? '').toString().trim().toUpperCase();
        final src = (st['source'] ?? '').toString().trim().toLowerCase();
        final within = (st['withinLastMs'] as num?)?.toInt() ??
            (_ai.running
                ? DateTime.now().difference(_ai.startedAt).inMilliseconds
                : 300000);
        final cutoffMs = DateTime.now().millisecondsSinceEpoch - within;
        final hits = <String>[];
        for (final e in _guiLogBuffer) {
          final ms = (e['rcvMs'] as num?)?.toInt() ?? 0;
          if (ms < cutoffMs) {
            continue;
          }
          if (lv.isNotEmpty &&
              (e['level'] ?? '').toString().toUpperCase() != lv) {
            continue;
          }
          if (src.isNotEmpty &&
              (e['source'] ?? '').toString().toLowerCase() != src) {
            continue;
          }
          var m = (e['msg'] ?? '').toString().replaceAll('\n', ' ');
          if (m.length > 160) m = m.substring(0, 160);
          hits.add('[${e['level']}/${e['source']}] $m');
        }
        if (contains.isNotEmpty) {
          final hit = hits.firstWhere((e) => e.contains(contains),
              orElse: () => '');
          return (hit.isEmpty ? '窗口内 ${hits.length} 条无匹配' : hit,
              hit.isEmpty ? '日志中未找到「$contains」' : '');
        }
        final bad = hits.where((e) => e.contains(notContains)).take(3).toList();
        return (bad.isEmpty ? '未出现「$notContains」' : bad.join(' | '),
            bad.isEmpty ? '' : '日志中不应出现「$notContains」');
      default:
        return ('', '未知步骤类型 $type（支持 tap/swipe/input/wait/back/navigate/assertVisible/assertRoute/assertInstance/assertText/assertRequest/assertLog/eval）');
    }
  } catch (e) {
    return ('', e.toString());
  } finally {
    await rpc.close();
  }
}

/// 路由操作复用（与 /api/routeop 同一套 eval，navigator.dart 上下文）。
Future<String> _autoRouteOp(String uri, String op,
    {int idx = -1, String name = ''}) async {
  final rpc = _SandboxRpc(uri);
  try {
    const walk = "final root = WidgetsBinding.instance.renderViewElement; "
        "if (root == null) return 'NO_ROOT'; "
        "final navigators = <NavigatorState>[]; "
        "void walk(Element e) { final w = e.widget; "
        "if (w is Navigator && e is StatefulElement && e.state is NavigatorState) "
        "{ navigators.add(e.state as NavigatorState); } e.visitChildren(walk); } "
        "root.visitChildren(walk); ";
    final expr = op == 'pop'
        ? "(() { $walk"
            "if (navigators.isEmpty) return 'NO_NAV'; "
            "final h = navigators[0]._history; if (h.length <= 1) return 'LAST_ROUTE'; "
            "navigators[0].pop(); return 'OK'; })()"
        : "(() { $walk"
            "if (navigators.isEmpty) return 'NO_NAV'; "
            "if (navigators[0].widget.onGenerateRoute == null) return 'NO_ROUTE_TABLE'; "
            "try { final r = navigators[0]._routeNamed('${_escEvalString(name)}', arguments: null); "
            "if (r == null) return 'UNKNOWN'; navigators[0].push(r); return 'OK'; "
            "} catch (e) { return 'ERR:' + e.runtimeType.toString(); } })()";
    return await rpc.evalStringOn('package:flutter/src/widgets/navigator.dart', expr);
  } finally {
    await rpc.close();
  }
}

/// 堆/树上实例计数（assertInstance 用，复用实例 Tab 的堆扫描）。
Future<int> _autoInstanceCount(String uri, String cls) async {
  final rpc = _SandboxRpc(uri);
  try {
    final iso = await rpc.isolateId();
    final classList = await rpc.rawRpc('getClassList', {'isolateId': iso});
    var count = 0;
    for (final c in (classList['classes'] as List? ?? <Object?>[])) {
      if (c is! Map) continue;
      final name = c['name']?.toString() ?? '';
      if (name != cls && !name.endsWith('.$cls')) continue;
      try {
        final set = await rpc.rawRpc('getInstances', {
          'isolateId': iso,
          'objectId': c['id']?.toString() ?? '',
          'limit': 100,
        });
        count += (set['instances'] as List? ?? <Object?>[]).length;
      } catch (_) {}
    }
    return count;
  } finally {
    await rpc.close();
  }
}

/// 场景执行主循环：逐步执行 + 每步截图 + 步间稳定延迟；
/// stopReq 置位后剩余步骤标 skip。失败是否继续由 continueOnFail 控制。
Future<void> _autoRunSteps(String uri, String name, List steps,
    {bool continueOnFail = false}) async {
  _auto
    ..running = true
    ..stopReq = false
    ..uri = uri
    ..name = name
    ..cur = 0
    ..runId = 'run-${DateTime.now().millisecondsSinceEpoch}'
    ..startedAt = DateTime.now()
    ..results = <_AutoStepResult>[];
  for (final raw in steps) {
    final st = raw is Map<String, dynamic> ? raw : <String, dynamic>{};
    final type = (st['type'] ?? '?').toString();
    final r = _AutoStepResult(
        _auto.results.length,
        type,
        (st['expect'] ??
                (st['type'] == 'assertVisible'
                    ? '可见 ${st['widget'] ?? ''}'
                    : ''))
            .toString());
    _auto.results.add(r);
    _auto.cur = r.index;
    if (_auto.stopReq) {
      r
        ..status = 'skip'
        ..error = '用户停止';
      continue;
    }
    final sw = Stopwatch()..start();
    final (actual, err) = await _autoExecStep(uri, st);
    r.ms = sw.elapsedMilliseconds;
    r.actual = actual;
    if (err.isNotEmpty) {
      r
        ..status = 'fail'
        ..error = err;
      r.shot = await _autoShot(uri, _auto.runId, r.index);
      if (!continueOnFail) {
        _auto.stopReq = true;
        continue;
      }
    } else {
      r.status = 'pass';
    }
    // 步间稳定延迟（tap/swipe 后 UI 需要渲染时间），可被步骤里的 wait 之外的
    // waitAfter 覆盖。
    final waitAfter = (st['waitAfter'] as num?)?.toInt() ?? 700;
    if (waitAfter > 0) await Future.delayed(Duration(milliseconds: waitAfter));
  }
  _auto.running = false;
}

// ── P11 AI 驱动：自然语言目标 → 截图→AI→步骤→执行 循环 ─────────────────

String get _aiConfigPath => '$_home/.xb_ume_ide/ai_config.json';

/// AI 目标历史（下拉选择复用）：去重、最新在前、上限 20 条。
List<String> _aiGoalsLoad() {
  try {
    final j = jsonDecode(File('$_home/.xb_ume_ide/ai_goals.json').readAsStringSync());
    return j is List ? j.map((e) => e.toString()).toList() : <String>[];
  } catch (_) {
    return <String>[];
  }
}

void _aiGoalsAdd(String goal) {
  final g = goal.trim();
  if (g.isEmpty) return;
  final items = _aiGoalsLoad()..remove(g);
  items.insert(0, g);
  if (items.length > 20) items.removeRange(20, items.length);
  try {
    final f = File('$_home/.xb_ume_ide/ai_goals.json');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode(items));
  } catch (_) {}
}

Map<String, String> _aiConfig() {
  try {
    final j = jsonDecode(File(_aiConfigPath).readAsStringSync());
    if (j is Map) {
      return <String, String>{
        'baseUrl': (j['baseUrl'] ?? '').toString(),
        'apiKey': (j['apiKey'] ?? '').toString(),
        'model': (j['model'] ?? '').toString(),
      };
    }
  } catch (_) {}
  return <String, String>{'baseUrl': '', 'apiKey': '', 'model': ''};
}

/// apiKey 打码展示（保留末 4 位）；同值回传视为未修改。
String _aiMaskKey(String k) =>
    k.isEmpty ? '' : '****${k.length > 4 ? k.substring(k.length - 4) : ''}';

/// 结构化上下文开关（存于 ai_config.json 的 ctx 字段，缺省全开）。
Map<String, bool> _aiCtx() {
  try {
    final j = jsonDecode(File(_aiConfigPath).readAsStringSync());
    final c = j is Map ? j['ctx'] : null;
    if (c is Map) {
      bool b(Object? v) => v is bool ? v : true;
      return <String, bool>{
        'routes': b(c['routes']),
        'text': b(c['text']),
        'net': b(c['net']),
        'log': b(c['log']),
      };
    }
  } catch (_) {}
  return <String, bool>{'routes': true, 'text': true, 'net': true, 'log': true};
}

/// AI 一轮的完整记录（决策 + 执行结果）。
class _AiRound {
  _AiRound(this.round);
  final int round;
  String think = '';
  String raw = ''; // AI 原始回复（截断留档，排障用）
  List<Map<String, dynamic>> steps = [];
  List<_AutoStepResult> results = [];
  String? shot; // 轮前截图文件名
  String error = ''; // 非空 = 本轮异常（截图/AI 调用/解析失败），循环终止
  int retries = 0; // 本轮 AI 调用/解析失败的重试次数
  Map<String, Object?> toJson() => <String, Object?>{
        'round': round,
        'think': think,
        'error': error,
        'retries': retries,
        'shot': shot,
        'steps': steps.length,
        'results': results.map((e) => e.toJson()).toList(),
      };
}

/// 一次 AI 驱动运行的状态（GUI 同一时间只跑一个）。
class _AiRunState {
  bool running = false;
  bool stopReq = false;
  bool done = false; // AI 判定目标完成
  String uri = '';
  String goal = '';
  String runId = '';
  var cur = 0;
  List<_AiRound> rounds = [];
  DateTime startedAt = DateTime.now();
  int logCursorMs = 0; // 增量日志游标（上一轮收集到的最后一条 rcvMs）
  Map<String, Object?> statusJson() => <String, Object?>{
        'running': running,
        'done': done,
        'goal': goal,
        'cur': cur,
        'rounds': rounds.map((r) => r.toJson()).toList(),
        'startedAt': startedAt.toIso8601String(),
      };
}

final _ai = _AiRunState();

const int _aiMaxStepsPerRound = 5;
const int _aiMaxRetries = 3; // AI 调用/回复解析失败的单轮重试上限（退避 2s/4s/6s）
const Set<String> _aiAllowedStepTypes = {
  'tap', 'swipe', 'input', 'wait', 'back', 'assertVisible', 'assertInstance',
  'eval', 'assertText', 'assertRequest', 'assertLog',
};

const String _aiSystemPrompt = '''你是 Flutter app 的 UI 自动化操作员。你会看到 app 当前截图和操作目标，
需要返回 JSON 指令驱动 UI 完成目标。
可用步骤类型（坐标均为截图的物理像素，与截图分辨率一致）：
- {"type":"tap","x":整数,"y":整数} 点击
- {"type":"swipe","x1":..,"y1":..,"x2":..,"y2":..,"ms":400} 滑动
- {"type":"input","text":"内容"} 向当前焦点输入框输入文本（须先 tap 输入框获得焦点）
- {"type":"back"} 返回上一页
- {"type":"wait","ms":800} 等待
- {"type":"assertVisible","widget":"Widget类名"} 断言某 Widget 类当前可见
- {"type":"assertInstance","class":"类名"} 断言某类实例存在
- {"type":"eval","expr":"Dart表达式","expect":"期望子串"} 执行任意 Dart 表达式（慎用，仅必要时）
- {"type":"assertText","contains":"文本"} 或 {"type":"assertText","notContains":"文本"} 断言当前页面文本（依据上下文的「页面文本」）
- {"type":"assertRequest","urlContains":"/api/xx","method":"GET","not":false} 断言最近发出过匹配请求（not:true 表示不应出现）
- {"type":"assertLog","contains":"关键字","level":"E","source":"flutter 或 device"} 断言最近日志（反向用 notContains）
规则：
1. 只输出一个 JSON 对象：{"done":false,"think":"简短分析","steps":[...]}，不要输出任何其他文本。
2. 每次最多 5 步，做一小批就等结果；点击若引起页面跳转，后续加 {"type":"wait","ms":900}。
3. 从截图中识别按钮/输入框/列表位置，坐标对准元素中心；坐标基于给定的截图分辨率，(0,0) 在左上角、右下角约 (宽,高)；底部导航栏贴在截图底边（y 接近图像高度），不在屏幕中部。
4. 连续两轮界面无变化时必须换策略（换坐标/滑动/返回）。
5. 目标已达成时返回 {"done":true,"think":"...","steps":[]}。
6. 步骤失败时分析原因（元素不在/坐标偏/需先滚动），下一轮修正。
7. 消息里会附「结构化上下文」（路由栈/页面文本/网络请求/增量日志）：判断状态是否变化、请求是否发出、列表是否刷新、有无报错等数据层问题时，优先用这些证据与 assertText/assertRequest/assertLog 断言，截图只用于定位元素坐标。''';

/// 从 AI 回复提取首个平衡的 JSON 对象（容忍 ``` 围栏与前后杂文本）。
Map<String, dynamic>? _aiParseReply(String s) {
  final start = s.indexOf('{');
  if (start < 0) return null;
  var depth = 0;
  var inStr = false;
  var esc = false;
  for (var i = start; i < s.length; i++) {
    final ch = s[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (ch == r'\') {
        esc = true;
      } else if (ch == '"') {
        inStr = false;
      }
      continue;
    }
    if (ch == '"') {
      inStr = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        try {
          final v = jsonDecode(s.substring(start, i + 1));
          return v is Map<String, dynamic> ? v : null;
        } catch (_) {
          return null;
        }
      }
    }
  }
  return null;
}

/// 调 OpenAI 兼容 chat/completions（baseUrl 填到 /v1 或完整端点均可），
/// 返回首条回复文本。支持 image_url 消息（vision）。
Future<String> _aiCall(List<Map<String, Object?>> messages) async {
  final cfg = _aiConfig();
  if (cfg['baseUrl']!.isEmpty || cfg['apiKey']!.isEmpty) {
    throw 'AI 未配置：请先设置接口地址与密钥';
  }
  var base = cfg['baseUrl']!.trim().replaceAll(RegExp(r'/+\$'), '');
  if (base.endsWith('/chat/completions')) {
    // 已是完整端点
  } else if (base.endsWith('/v1')) {
    base = '$base/chat/completions';
  } else {
    base = '$base/v1/chat/completions';
  }
  final hc = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final rq = await hc.openUrl('POST', Uri.parse(base));
    rq.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${cfg['apiKey']}');
    rq.headers.contentType = ContentType.json;
    // 显式 Content-Length（部分本地服务不支持 chunked）
    final payload = utf8.encode(jsonEncode(<String, Object?>{
      'model': cfg['model'] ?? '',
      'temperature': 0.2,
      'messages': messages,
    }));
    rq.headers.contentLength = payload.length;
    rq.add(payload);
    final rs = await rq.close().timeout(const Duration(seconds: 120));
    final body = await utf8.decoder.bind(rs).join();
    if (rs.statusCode != 200) {
      throw 'HTTP ${rs.statusCode}: ${body.length > 300 ? body.substring(0, 300) : body}';
    }
    final j = jsonDecode(body);
    final choices = (j as Map)['choices'] as List?;
    if (choices == null || choices.isEmpty) throw 'AI 回复缺少 choices';
    final msg = (choices.first as Map?)?['message'];
    final s = (msg is Map ? msg['content'] : null)?.toString() ?? '';
    if (s.isEmpty) throw 'AI 回复为空';
    return s;
  } finally {
    hc.close(force: true);
  }
}

/// 页面文本收集表达式（binding.dart 上下文）：BFS 全树取 Text.data 与
/// EditableText 内容，去重保序。binding.dart 未必导出 Text/EditableText
/// 类名，用 runtimeType 匹配 + dynamic 取字段（P10 assertVisible 同理）。
/// 条目间用 \u0002 分隔（String.fromCharCode 避免转义地狱），GUI 侧限流。
String _aiPageTextExpr({int limit = 40}) =>
    "(() { final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return ''; "
    "final out = <String>[]; final seen = <String>{}; "
    "void add(String? t) { if (t == null) return; final s = t.trim(); "
    "if (s.isEmpty) return; if (seen.add(s)) out.add(s); } "
    "void visit(Element e) { if (out.length >= $limit) return; "
    "final tn = e.widget.runtimeType.toString(); "
    // Offstage 子树（下层页面保活）的文本不属于当前可见页面，跳过避免误导
    "if (tn == 'Offstage') { try { if ((e.widget as dynamic).offstage == true) return; } catch (_) {} } "
    "try { if (tn == 'Text') { add((e.widget as dynamic).data as String?); } "
    "else if (tn == 'EditableText') { add((e.widget as dynamic).controller.text as String?); } "
    "} catch (_) {} "
    "e.visitChildren(visit); } visit(root); "
    "return out.join(String.fromCharCode(2)); })()";

/// 拉取 app 端 network 记录（xb_ume core 库 eval，与 /api/network 同源），
/// 可按时间窗过滤；app 未接入 network 模块时在此抛异常由调用方标 N/A。
Future<List<Map<String, Object?>>> _aiNetRecords(String uri,
    {DateTime? since, int limit = 8}) async {
  final rpc = _SandboxRpc(uri);
  try {
    await rpc.libraryId('package:xb_ume/src/core/xb_ume.dart');
    final cutoffExpr =
        since == null ? '' : "final c = DateTime.parse('${since.toIso8601String()}'); ";
    final filterExpr = since == null ? '' : '.where((e) => e.time.isAfter(c)) ';
    final raw = await rpc.evalStringOn(
      'package:xb_ume/src/core/xb_ume.dart',
      "(() { final n = XBUme.controller.network; $cutoffExpr"
      "return n$filterExpr.map((e) => [e.method, e.url, "
      "(e.statusCode ?? '').toString(), e.status.name].join('\\u0001')).join('\\u0002'); })()",
    );
    final items = <Map<String, Object?>>[];
    for (final line in raw.split('\u0002')) {
      if (line.isEmpty) continue;
      final p = line.split('\u0001');
      if (p.length < 4) continue;
      items.add(<String, Object?>{
        'method': p[0],
        'url': p[1],
        'statusCode': p[2],
        'status': p[3],
      });
    }
    // n 为旧→新序（/api/network 同源），取末尾 limit 条即最近的
    return items.length > limit ? items.sublist(items.length - limit) : items;
  } finally {
    await rpc.close();
  }
}

/// 收集一轮的结构化上下文（路由栈/页面文本/最近网络请求）；单项失败标注
/// N/A 继续，不中断循环。增量日志由 _aiLogDelta 在 _aiLoop 侧单独处理（带游标）。
Future<String> _aiCollectContext(String uri, Map<String, bool> ctx) async {
  final out = StringBuffer();
  if (ctx['routes'] == true || ctx['text'] == true) {
    final rpc = _SandboxRpc(uri);
    try {
      if (ctx['routes'] == true) {
        try {
          final s = await rpc.evalStringOn(
              'package:flutter/src/widgets/navigator.dart', _autoRoutesExpr);
          final names = (s == 'NO_ROOT' || s == 'NO_NAV')
              ? <String>[]
              : s.split(',').where((e) => e.isNotEmpty).toList();
          out.write('当前路由栈：${names.isEmpty ? 'N/A' : names.join(' > ')}\n');
        } catch (_) {
          out.write('当前路由栈：N/A\n');
        }
      }
      if (ctx['text'] == true) {
        try {
          final s = await rpc.evalStringOn(
              'package:flutter/src/widgets/binding.dart', _aiPageTextExpr());
          final items = s.split('\u0002').where((e) => e.isNotEmpty).toList();
          // 总长限流，防超大列表撑爆消息
          var joined = items.join(' / ');
          if (joined.length > 300) joined = joined.substring(0, 300);
          out.write('页面文本：${items.isEmpty ? 'N/A' : joined}\n');
        } catch (_) {
          out.write('页面文本：N/A\n');
        }
      }
    } finally {
      await rpc.close();
    }
  }
  if (ctx['net'] == true) {
    try {
      final recs = await _aiNetRecords(uri, since: _ai.startedAt);
      out.write(recs.isEmpty
          ? '最近网络请求（本次运行以来）：无\n'
          : '最近网络请求（本次运行以来）：\n');
      for (final e in recs) {
        out.write(
            '- ${e['method']} ${e['url']} ${e['statusCode']} ${e['status']}\n');
      }
    } catch (_) {
      out.write('最近网络请求：N/A（app 未接入 network 模块）\n');
    }
  }
  return out.toString();
}

/// 增量日志：自游标 rcvMs 以来的新增条目（E/W 全给，I 级需含错误关键字），
/// 上限 25 条超出附省略说明；返回（文本, 新游标）。
(String, int) _aiLogDelta(int cursorMs) {
  final kw = RegExp('error|exception|fail|crash', caseSensitive: false);
  final all = _guiLogBuffer.where((e) {
    final ms = (e['rcvMs'] as num?)?.toInt() ?? 0;
    return ms >= cursorMs;
  }).toList();
  var next = cursorMs;
  for (final e in all) {
    final ms = (e['rcvMs'] as num?)?.toInt() ?? 0;
    if (ms > next) next = ms;
  }
  final picked = <Map<String, Object?>>[];
  for (final e in all) {
    final lv = (e['level'] ?? 'I').toString();
    if (lv == 'E' || lv == 'W' || kw.hasMatch((e['msg'] ?? '').toString())) {
      picked.add(e);
    }
  }
  if (picked.isEmpty) return ('无', next);
  final show = picked.length > 25 ? picked.sublist(picked.length - 25) : picked;
  final sb = StringBuffer();
  for (final e in show) {
    var m = (e['msg'] ?? '').toString().replaceAll('\n', ' ');
    if (m.length > 120) m = m.substring(0, 120);
    final tag = (e['tag'] ?? '').toString();
    sb.write('- [${e['level']}/${e['source']}'
        '${tag.isNotEmpty && tag != e['source'] ? '/' : ''}$tag] $m\n');
  }
  if (picked.length > 25) sb.write('-（另有 ${picked.length - 25} 条省略）\n');
  return (sb.toString(), next);
}

/// AI 驱动主循环：截图 → AI 决策 → 执行 → 反馈，直至 done/轮数上限/停止。
Future<void> _aiLoop(String uri, String goal) async {
  _ai
    ..running = true
    ..stopReq = false
    ..done = false
    ..uri = uri
    ..goal = goal
    ..runId = 'ai-${DateTime.now().millisecondsSinceEpoch}'
    ..cur = 0
    ..startedAt = DateTime.now()
    ..rounds = <_AiRound>[];
  _ai.logCursorMs = _ai.startedAt.millisecondsSinceEpoch;
  String? failB64; // 上一轮失败步骤截图（反馈给 AI 自适应，用后清空）
  try {
    while (!_ai.stopReq) {
      final r = _AiRound(_ai.rounds.length);
      _ai.rounds.add(r);
      _ai.cur = r.round;
      // 1) 截图：直接作为 AI 输入 + 落盘留档
      String b64;
      final rpc = _SandboxRpc(uri);
      try {
        final resp = await rpc.rawRpc('_flutter.screenshot');
        b64 = (resp['data'] ?? resp['screenshot'])?.toString() ?? '';
      } catch (e) {
        r.error = '截图失败（app 已断开？）: $e';
        break;
      } finally {
        await rpc.close();
      }
      if (b64.isEmpty) {
        r.error = '截图为空';
        break;
      }
      Directory(_autoArtifactsDir).createSync(recursive: true);
      r.shot = '${_ai.runId}-r${r.round}.png';
      final pngBytes = base64Decode(b64);
      File('$_autoArtifactsDir/${r.shot}').writeAsBytesSync(pngBytes);
      // 解析 PNG IHDR 拿真实分辨率：AI 不知道图幅会坐标系幻觉（f_jlink 实测
      // 轮 18 误以为 924×2000，点出屏外），必须显式告知。
      var iw = 0, ih = 0;
      if (pngBytes.length > 24 && pngBytes[0] == 0x89 && pngBytes[1] == 0x50) {
        iw = (pngBytes[16] << 24) | (pngBytes[17] << 16) | (pngBytes[18] << 8) | pngBytes[19];
        ih = (pngBytes[20] << 24) | (pngBytes[21] << 16) | (pngBytes[22] << 8) | pngBytes[23];
      }
      // 2.5) 结构化上下文：路由栈/页面文本/最近请求/增量日志
      //（单项失败标 N/A 继续，不中断循环；增量日志带游标只取新增）
      final ctx = _aiCtx();
      final ctxStr = await _aiCollectContext(uri, ctx);
      var logStr = '无';
      if (ctx['log'] == true) {
        final (ls, nextCur) = _aiLogDelta(_ai.logCursorMs);
        _ai.logCursorMs = nextCur;
        logStr = ls;
      }
      // 3) 组消息：system + 目标 + 历史摘要 + 截图
      final hist = StringBuffer();
      for (final p in _ai.rounds) {
        if (p.round == r.round) continue;
        hist.write('轮${p.round}: ${p.error.isNotEmpty ? '异常=${p.error}' : 'think=${p.think}'}; ');
        for (final sr in p.results) {
          hist.write('${sr.type}=${sr.status == 'pass' ? 'OK' : '失败:${sr.error.isEmpty ? sr.actual : sr.error}'}; ');
        }
      }
      final userText = StringBuffer();
      userText.write('目标：$goal\n');
      if (iw > 0) {
        userText.write('截图分辨率：$iw×$ih（坐标以此像素坐标系为准，左上角为原点）\n');
      }
      userText.write('── 结构化上下文（数据层证据，判断状态变化优先用它）──\n');
      userText.write(ctxStr);
      if (ctx['log'] == true) {
        userText.write('增量日志（自上轮以来）：$logStr\n');
      }
      userText.write('执行历史：');
      userText.write(hist.isEmpty ? '无（这是第一步）' : hist.toString());
      if (failB64 != null) {
        userText.write('\n注意：第二张截图是上一轮失败时的画面，请分析失败原因并修正。');
      }
      final content = <Object?>[
        <String, Object?>{'type': 'text', 'text': userText.toString()},
        <String, Object?>{
          'type': 'image_url',
          'image_url': <String, Object?>{'url': 'data:image/png;base64,$b64'},
        },
      ];
      if (failB64 != null) {
        content.add(<String, Object?>{
          'type': 'image_url',
          'image_url': <String, Object?>{'url': 'data:image/png;base64,$failB64'},
        });
      }
      failB64 = null;
      final messages = <Map<String, Object?>>[
        <String, Object?>{'role': 'system', 'content': _aiSystemPrompt},
        <String, Object?>{'role': 'user', 'content': content},
      ];
      // 3) 调 AI + 解析 + 步骤解析。网络失败/回复不可解析/无有效步骤都属 AI 侧故障，
      // 自动重试（递增退避），不直接终止任务；重试耗尽才停下。
      final steps = <Map<String, dynamic>>[];
      var aiErr = '';
      Map<String, dynamic>? obj;
      for (var attempt = 0; attempt <= _aiMaxRetries; attempt++) {
        if (_ai.stopReq) break;
        if (attempt > 0) {
          r.retries++;
          await Future.delayed(Duration(seconds: 2 * attempt));
          if (_ai.stopReq) break;
        }
        String reply;
        try {
          reply = await _aiCall(messages);
        } catch (e) {
          aiErr = 'AI 调用失败: $e';
          continue;
        }
        r.raw = reply.length > 2000 ? reply.substring(0, 2000) : reply;
        obj = _aiParseReply(reply);
        if (obj == null) {
          aiErr = 'AI 回复无法解析为 JSON';
          continue;
        }
        r.think = (obj['think'] ?? '').toString();
        if (obj['done'] == true) break;
        // 4) 过滤步骤（白名单 + 每轮上限），AI 坐标即截图像素 → phys:true
        steps.clear();
        final rawSteps = obj['steps'] is List ? obj['steps'] as List : <Object?>[];
        for (final s in rawSteps) {
          if (steps.length >= _aiMaxStepsPerRound) break;
          if (s is Map) {
            final m = s.map((k, v) => MapEntry(k.toString(), v));
            final t = (m['type'] ?? '').toString();
            if (!_aiAllowedStepTypes.contains(t)) continue;
            // 上下文开关关闭的断言步骤直接丢弃（消息里也没给对应上下文）
            if (t == 'assertText' && ctx['text'] != true) continue;
            if (t == 'assertRequest' && ctx['net'] != true) continue;
            if (t == 'assertLog' && ctx['log'] != true) continue;
            if (t == 'tap' || t == 'swipe') m['phys'] = true;
            steps.add(m);
          }
        }
        if (steps.isEmpty) {
          aiErr =
              'AI 未给出有效步骤（raw: ${r.raw.length > 200 ? r.raw.substring(0, 200) : r.raw}）';
          continue;
        }
        aiErr = '';
        break;
      }
      if (_ai.stopReq) break;
      if (aiErr.isNotEmpty || obj == null) {
        r.error = '$aiErr（已重试 ${r.retries} 次仍失败，任务停止）';
        break;
      }
      if (obj['done'] == true) {
        _ai.done = true;
        break;
      }
      r.steps = steps;
      // 5) 执行：失败即停本轮，失败截图反馈给 AI 重新决策
      for (final st in steps) {
        if (_ai.stopReq) break;
        final res = _AutoStepResult(
            r.results.length, (st['type'] ?? '?').toString(),
            (st['expect'] ?? '').toString());
        r.results.add(res);
        final sw = Stopwatch()..start();
        final (actual, err) = await _autoExecStep(uri, st);
        res.ms = sw.elapsedMilliseconds;
        res.actual = actual;
        if (err.isNotEmpty) {
          res
            ..status = 'fail'
            ..error = err;
          res.shot = await _autoShot(uri, _ai.runId, res.index);
          if (res.shot != null) {
            failB64 =
                base64Encode(File('$_autoArtifactsDir/${res.shot}').readAsBytesSync());
          }
          break;
        }
        res.status = 'pass';
        final waitAfter = (st['waitAfter'] as num?)?.toInt() ?? 700;
        if (waitAfter > 0) await Future.delayed(Duration(milliseconds: waitAfter));
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
  } finally {
    _ai.running = false;
  }
}

/// 取路径最后一段（os 为 app 端 Platform.operatingSystem）。
String _baseName(String p, String os) {
  final sep = os == 'windows' ? r'\' : '/';
  final idx = p.lastIndexOf(sep);
  return idx < 0 ? p : p.substring(idx + 1);
}

/// 递归展开实例字段树（/api/instances/tree）。
///
/// 字符串/数字/bool 直接给值；List/Map 摘录条目（上限 100）；普通对象按
/// fields 递归。depth 限展开层数，visited 按 objectId 防环。引用在
/// depth 用尽后降级为 kind=ref 摘要（仅类名/预览值），GUI 可按 id 二次展开。
Future<Map<String, Object?>> _instNode(
  _SandboxRpc rpc,
  String iso,
  String id,
  String? name,
  int depth,
  Set<String> visited,
) async {
  final node = <String, Object?>{'name': name ?? '', 'id': id};
  if (!visited.add(id)) {
    node['kind'] = 'circular';
    return node;
  }
  final obj = await rpc.rawRpc('getObject', {
    'isolateId': iso,
    'objectId': id,
  });
  if (obj['type']?.toString() == 'Sentinel') {
    node['kind'] = 'expired';
    return node;
  }
  node['cls'] = (obj['class'] as Map?)?['name']?.toString() ?? '';

  // 引用摘要：不做二次 getObject，仅取 ref 自带的类名与预览值。
  Map<String, Object?> refSummary(String refName, Map ref) {
    final v = ref['valueAsString']?.toString() ?? '';
    // late 字段未初始化时 ref 是 Sentinel，值为 <not initialized>。
    if (v == '<not initialized>') {
      return <String, Object?>{
        'name': refName,
        'kind': 'value',
        'id': '',
        'cls': '',
        'value': '（late 字段，未初始化）',
      };
    }
    return <String, Object?>{
      'name': refName,
      'kind': 'ref',
      'id': ref['id']?.toString() ?? '',
      'cls': (ref['class'] as Map?)?['name']?.toString() ?? '',
      'value': v,
    };
  }

  Future<Map<String, Object?>> expandRef(String refName, Map ref) async {
    final rid = ref['id']?.toString() ?? '';
    // 带预览值的引用（null/数字/bool/字符串）是叶子，直接摘要；
    // 且不能进 visited——Null 等是 VM 单例，全堆共享同一 id，
    // 一旦记录会让后续所有 null 字段误判为循环引用。
    if (rid.isEmpty || ref['valueAsString'] != null) {
      return refSummary(refName, ref);
    }
    if (depth <= 1) return refSummary(refName, ref);
    return _instNode(rpc, iso, rid, refName, depth - 1, visited);
  }

  final vstr = obj['valueAsString']?.toString();
  final elements = obj['elements'] as List?;
  final assocs = obj['associations'] as List?;
  final fields = obj['fields'] as List?;
  final children = <Map<String, Object?>>[];
  if (elements != null) {
    node['kind'] = 'list';
    node['length'] = obj['length']?.toString() ?? '?';
    // 列表元素用下标当名字，避免渲染成无名字段。
    var ei = 0;
    for (final e in elements.take(100)) {
      if (e is Map) children.add(await expandRef('[${ei++}]', e));
    }
  } else if (assocs != null) {
    node['kind'] = 'map';
    node['length'] = obj['length']?.toString() ?? '?';
    for (final a in assocs.take(100)) {
      if (a is! Map) continue;
      final k = a['key'];
      final v = a['value'];
      final keyPreview = k is Map
          ? (k['valueAsString']?.toString() ??
              (k['class'] as Map?)?['name']?.toString() ??
              '?')
          : '?';
      final kref = k is Map ? k : <String, Object?>{};
      final kid = kref['id']?.toString() ?? '';
      children.add(
        depth > 1 && kid.isNotEmpty && kref['valueAsString'] == null
            ? await _instNode(
                rpc, iso, kid, 'key: $keyPreview', depth - 1, visited)
            : refSummary('key: $keyPreview', kref),
      );
      children.add(await expandRef('value', v is Map ? v : <String, Object?>{}));
    }
  } else if (fields != null) {
    node['kind'] = 'object';
    for (final f in fields) {
      if (f is! Map) continue;
      final decl = f['decl'] as Map?;
      final ref = f['value'];
      final child = await expandRef(
        decl?['name']?.toString() ?? '?',
        ref is Map ? ref : <String, Object?>{},
      );
      // 「仅用户字段」过滤依据：字段声明所属类是否 SDK。
      child['sdk'] = _fieldIsSdk(decl);
      children.add(child);
    }
  } else if (vstr != null) {
    node['kind'] = 'value';
    node['value'] = vstr;
    if (obj['valueAsStringIsTruncated'] == true) {
      node['truncated'] = true;
    }
  } else {
    node['kind'] = 'opaque';
  }
  if (children.isNotEmpty) node['children'] = children;
  return node;
}

/// 字段声明所属类是否 Flutter/dart SDK（实例 Tab「仅用户字段」过滤用）。
/// VM 返回的 @Field decl.owner（@Class ref）内嵌 library uri，零额外 RPC；
/// owner/library 缺失时视为用户字段（保守显示）。
bool _fieldIsSdk(Map? decl) {
  final owner = decl?['owner'];
  final libUri = owner is Map
      ? ((owner['library'] as Map?)?['uri'] ?? '').toString()
      : '';
  return libUri.startsWith('dart:') || libUri.startsWith('package:flutter/');
}

/// 计算 p 相对于 root 的 tar 内路径（同一 os 分隔符体系）。
String _relativeTo(String p, String root, String os) {
  final sep = os == 'windows' ? r'\' : '/';
  final prefix = root.endsWith(sep) ? root : '$root$sep';
  if (p.startsWith(prefix)) {
    return p.substring(prefix.length);
  }
  return p;
}

/// 应用沙盒浏览器：通过 VM service evaluate 在 app 进程内执行 dart:io 代码，
/// 零 app 端改动（debug 模式即可，release 无 VM service）。
/// 每次请求新建临时连接，用完即断。
class _SandboxRpc {
  _SandboxRpc(this.uri);

  final String uri;
  int _seq = 0;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  final Map<String, Completer<Object?>> _pending = {};
  String? _isolateId;

  /// 已解析的库 id 缓存（uri → Library id，每连接有效）。
  final Map<String, String> _libIds = {};

  /// 建立连接（懒加载；同一连接复用多次 evaluate，避免分段读反复握手）。
  Future<void> _ensureConnected() async {
    if (_socket != null) return;
    // 死会话（app 已断但端口仍在）会让握手挂起，必须限时。
    final socket = await WebSocket.connect(uri).timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw '连接 VM service 超时（会话可能已断开）',
    );
    _socket = socket;
    _sub = socket.listen(
      (message) {
        if (message is! String) return;
        Object? parsed;
        try {
          parsed = jsonDecode(message);
        } catch (_) {
          return;
        }
        if (parsed is! Map) return;
        final id = parsed['id']?.toString();
        final completer = _pending.remove(id);
        if (completer == null) return;
        if (parsed['error'] is Map) {
          completer.completeError(
            (parsed['error'] as Map)['message']?.toString() ?? 'VM service 错误',
          );
        } else {
          completer.complete(parsed['result']);
        }
      },
      onDone: () {
        for (final c in _pending.values) {
          c.completeError('连接已关闭');
        }
        _pending.clear();
        _socket = null;
      },
      onError: (Object e) {
        for (final c in _pending.values) {
          c.completeError(e);
        }
        _pending.clear();
        _socket = null;
      },
    );
  }

  /// 通用 VM service 调用（供路由定位使用 evaluate/getObject 等）。
  Future<Map<String, Object?>> rawRpc(
    String method, [
    Map<String, Object?>? params,
  ]) async {
    await _ensureConnected();
    await _resolveTarget();
    return _rpc(method, params);
  }

  /// 当前 isolate id（须先经 rawRpc 或 evalString 触发连接）。
  Future<String> isolateId() async {
    await _ensureConnected();
    await _resolveTarget();
    return _isolateId!;
  }

  /// 按库 uri 查找库 id（公开版本）。
  Future<String> libraryId(String uri) => _libraryId(uri);

  /// 单次 JSON-RPC 请求-响应。
  Future<Map<String, Object?>> _rpc(
    String method, [
    Map<String, Object?>? params,
  ]) {
    final id = 'r${_seq++}';
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _socket!.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        if (params != null) 'params': params,
      }),
    );
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw 'VM service 响应超时（会话可能已挂起或断开）';
      },
    ).then((v) => v as Map<String, Object?>);
  }

  /// 解析 isolateId（每连接一次）；库 id 由 _libraryId 按需解析并缓存。
  Future<void> _resolveTarget() async {
    await _ensureConnected();
    if (_isolateId != null) return;
    final vm = await _rpc('getVM');
    final isolates = vm['isolates'];
    final isolateId = isolates is List && isolates.isNotEmpty
        ? (isolates.first as Map)['id']?.toString()
        : null;
    if (isolateId == null || isolateId.isEmpty) {
      throw '未找到可用的 isolate';
    }
    _isolateId = isolateId;
  }

  /// 按库 uri 查找库 id（每连接每库一次）。
  Future<String> _libraryId(String uri) async {
    final cached = _libIds[uri];
    if (cached != null) return cached;
    await _resolveTarget();
    final iso = await _rpc('getIsolate', {'isolateId': _isolateId});
    for (final lib in (iso['libraries'] as List? ?? <Object?>[])) {
      if (lib is Map && lib['uri'] == uri) {
        final id = lib['id']?.toString();
        if (id != null && id.isNotEmpty) {
          _libIds[uri] = id;
          return id;
        }
      }
    }
    throw uri == 'dart:io' ? 'app 未加载 dart:io 库' : 'app 未加载 $uri 库（非 Flutter 调试会话？）';
  }

  /// 在 app 的 dart:io 库上下文执行表达式，返回完整字符串。
  /// 超过 VM 截断阈值时用 getObject 分页拉全。
  Future<String> evalString(String expression) =>
      evalStringOn('dart:io', expression);

  /// 在 app 的指定库上下文执行表达式（库上下文可访问该库私有成员），
  /// 返回完整字符串；超过 VM 截断阈值时用 getObject 分页拉全。
  /// 注意：表达式须为单行 IIFE——实测 VM eval 对多行 IIFE 会返回未调用的
  /// Closure（kind=Closure）而非执行结果。
  Future<String> evalStringOn(String libraryUri, String expression) async {
    await _ensureConnected();
    final libId = await _libraryId(libraryUri);
    final result = await _rpc('evaluate', {
      'isolateId': _isolateId,
      'targetId': libId,
      'expression': expression,
    });
    // evaluate 返回临时引用：type 为 @Instance（非固定 id 的 InstanceRef）。
    final resultType = result['type']?.toString();
    if (resultType != 'Instance' && resultType != '@Instance') {
      // ErrorRef / Sentinel：表达式编译失败或运行时异常（如路径不存在）。
      final message =
          result['message']?.toString() ?? result['valueAsString']?.toString();
      throw message == null || message.isEmpty
          ? '执行失败：${jsonEncode(result)}'
          : message;
    }
    var value = result['valueAsString']?.toString() ?? '';
    if (result['valueAsStringIsTruncated'] != true) {
      return value;
    }
    // 字符串被 VM 截断：分页拉取全文。
    final objectId = result['id']?.toString();
    final total = result['length'] is int ? result['length'] as int : 0;
    if (objectId == null || objectId.isEmpty || total <= value.length) {
      return value;
    }
    final sb = StringBuffer(value);
    var offset = value.length;
    const pageSize = 4 * 1024 * 1024;
    while (offset < total) {
      final page = await _rpc('getObject', {
        'isolateId': _isolateId,
        'objectId': objectId,
        'offset': offset,
        'count': pageSize,
      });
      final part = page['valueAsString']?.toString() ?? '';
      if (part.isEmpty) break;
      sb.write(part);
      offset += part.length;
    }
    return sb.toString();
  }

  /// 在指定库上下文执行表达式，返回原始 evaluate 响应。表达式返回对象时
  /// （type 为 Instance/@Instance），id 可用于 getObject 展开字段树。
  Future<Map<String, Object?>> evalRefOn(String libraryUri, String expression) async {
    await _ensureConnected();
    final libId = await _libraryId(libraryUri);
    final result = await _rpc('evaluate', {
      'isolateId': _isolateId,
      'targetId': libId,
      'expression': expression,
    });
    final t = result['type']?.toString();
    if (t != 'Instance' && t != '@Instance') {
      final message =
          result['message']?.toString() ?? result['valueAsString']?.toString();
      throw message == null || message.isEmpty
          ? '执行失败：${jsonEncode(result)}'
          : message;
    }
    return result;
  }

  /// 关闭连接（请求方在 finally 中调用）。
  Future<void> close() async {
    await _sub?.cancel();
    try {
      await _socket?.close();
    } catch (_) {
      // ignored
    }
    _socket = null;
  }
}

/// 生成单个 tar 文件条目的 512 字节 USTAR header；路径超长返回 null。
/// 数据与填充由调用方流式写入（分段读取，不整文件驻留内存）。
List<int>? _tarHeader(String name, int size, int mtimeSec) {
  if (name.length > 255) {
    return null;
  }
  final header = List<int>.filled(512, 0);
  void writeField(int offset, int fieldSize, String value) {
    final codes = value.codeUnits;
    for (var i = 0; i < fieldSize && i < codes.length; i++) {
      header[offset + i] = codes[i] & 0xff;
    }
  }

  // 长路径拆分：prefix(155) + '/' + name(100)。
  var fileName = name;
  var prefix = '';
  if (name.length > 100) {
    final split = name.lastIndexOf('/', 99);
    if (split < 0 || name.length - split - 1 > 100) {
      return null;
    }
    prefix = name.substring(0, split);
    if (prefix.length > 155) {
      return null;
    }
    fileName = name.substring(split + 1);
  }
  writeField(0, 100, fileName);
  writeField(100, 8, '0000644');
  writeField(108, 8, '0000000');
  writeField(116, 8, '0000000');
  writeField(124, 12, '${size.toRadixString(8).padLeft(11, '0')} ');
  writeField(
    136,
    12,
    '${mtimeSec.clamp(0, 8589934591).toRadixString(8).padLeft(11, '0')} ',
  );
  writeField(257, 6, 'ustar');
  writeField(263, 2, '00');
  writeField(345, 155, prefix);
  header[156] = 0x30; // typeflag '0'（普通文件）
  // checksum：先填空格求和，再写入 6 位八进制 + \0 + 空格。
  for (var i = 148; i < 156; i++) {
    header[i] = 0x20;
  }
  var sum = 0;
  for (final b in header) {
    sum += b;
  }
  final chk = sum.toRadixString(8).padLeft(6, '0');
  for (var i = 0; i < 6; i++) {
    header[148 + i] = chk.codeUnitAt(i);
  }
  header[154] = 0;
  header[155] = 0x20;
  return header;
}

/// tar 结束块（两个 512 全零块）。
List<int> _tarEnd() => List<int>.filled(1024, 0);

// ---------------------------------------------------------------------------
// 守护进程控制模块
// ---------------------------------------------------------------------------

/// 查询 daemon 状态（经互斥端口 status 协议）。未运行返回 null。
Future<Map<String, Object?>?> queryDaemonStatus() async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      kDaemonLockPort,
      timeout: const Duration(milliseconds: 800),
    );
    final completer = Completer<Map<String, Object?>?>();
    late StreamSubscription<List<int>> sub;
    sub = socket.listen((data) {
      if (!completer.isCompleted) {
        try {
          final decoded = jsonDecode(utf8.decode(data));
          completer.complete(decoded is Map
              ? <String, Object?>{
                  for (final entry in decoded.entries)
                    entry.key.toString(): entry.value,
                }
              : null);
        } catch (_) {
          completer.complete(null);
        }
      }
      unawaited(sub.cancel());
    }, onDone: () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }, onError: (dynamic _) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });
    socket.write(kDaemonStatusToken);
    await socket.flush();
    final result = await completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => null,
    );
    return result;
  } catch (_) {
    return null;
  } finally {
    socket?.destroy();
  }
}

/// 重启守护进程：杀掉所有实例 → detached 启动部署副本 → 等待就绪。
/// 依赖 ide.dart 单实例接管锁：新实例自动成为唯一实例。
Future<Map<String, Object?>> restartDaemon() async {
  final script = File('$_home/.xb_ume_ide/ide.dart');
  if (!script.existsSync()) {
    return <String, Object?>{
      'ok': false,
      'message': '未找到守护脚本，请先执行 dart run xb_ume:ide --install',
    };
  }
  await killOtherDaemons();
  try {
    await Process.start(
      Platform.resolvedExecutable,
      <String>[script.path, '--daemon'],
      mode: ProcessStartMode.detached,
    );
  } catch (e) {
    return <String, Object?>{'ok': false, 'message': '启动失败: $e'};
  }
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (await queryDaemonStatus() != null) {
      return <String, Object?>{'ok': true, 'message': '守护进程已重启'};
    }
  }
  return <String, Object?>{
    'ok': false,
    'message': '重启后未检测到 daemon（可查看 ~/.xb_ume_ide/daemon.log）',
  };
}

/// 停止本机上其他 `ide.dart --daemon` 进程（排除自身）。
/// 复制自 bin/ide.dart 的 _killOtherDaemons（单文件部署无法共享代码）。
Future<void> killOtherDaemons() async {
  try {
    if (Platform.isWindows) {
      final ps = "Get-CimInstance Win32_Process | Where-Object { "
          "\$_.CommandLine -match 'ide\\.dart' -and "
          "\$_.CommandLine -match '--daemon' -and \$_.ProcessId -ne $pid } | "
          "ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }";
      await Process.run('powershell', <String>['-NoProfile', '-Command', ps]);
    } else {
      final pgrep = await Process.run(
        'pgrep',
        <String>['-f', r'ide\.dart.*--daemon'],
      );
      for (final line in pgrep.stdout.toString().split('\n')) {
        final other = int.tryParse(line.trim());
        if (other != null && other != pid) {
          await Process.run('kill', <String>['-9', '$other']);
        }
      }
    }
  } catch (_) {
    // 清理失败不阻塞。
  }
}

/// 读取 daemon 配置中的 IDE 顺序（供页面展示）。
Map<String, Object?> readGuiIdeOrder() {
  try {
    final file = File('$_home/.xb_ume_ide/config.json');
    if (!file.existsSync()) {
      return const <String, Object?>{};
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map && decoded['ideOrder'] is List) {
      return <String, Object?>{'ideOrder': decoded['ideOrder']};
    }
  } catch (_) {
    // ignored
  }
  return const <String, Object?>{};
}

/// 读取 config.json 原始内容（供读-改-写保留其他配置键）。
Map<String, Object?> _guiReadConfigRaw() {
  try {
    final file = File('$_home/.xb_ume_ide/config.json');
    if (!file.existsSync()) return <String, Object?>{};
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    }
  } catch (_) {
    // 配置损坏时直接重建。
  }
  return <String, Object?>{};
}

/// 把 ideOrder 写入 config.json（保留其他配置键）。
Future<void> writeGuiIdeOrder(List<String> order) async {
  final cfg = _guiReadConfigRaw();
  cfg['ideOrder'] = order;
  final file = File('$_home/.xb_ume_ide/config.json');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(cfg));
}

/// 扫描本机已安装的 IDE（供「IDE 优先级」页展示与自动追加新装 IDE）。
Future<List<String>> scanInstalledIdes() async {
  final installed = <String>[];
  for (final ide in _guiDefaultIdeOrder) {
    var ok = false;
    if (ide == 'androidStudio') {
      ok = _guiAndroidStudioBinaries().any((bin) => File(bin).existsSync());
    } else {
      ok = await _guiHasCommand(ide);
      if (!ok && Platform.isMacOS) {
        ok = (_guiMacosVscodeAppClis[ide] ?? const <String>[]).any(
          (p) => File(p).existsSync(),
        );
      }
    }
    if (ok) installed.add(ide);
  }
  return installed;
}

/// 当前配置的 ideOrder（无配置/损坏时返回默认名单）。
List<String> readGuiIdeOrderList() {
  final order = _guiReadConfigRaw()['ideOrder'];
  if (order is! List) return List<String>.of(_guiDefaultIdeOrder);
  final names = order.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
  return names.isEmpty ? List<String>.of(_guiDefaultIdeOrder) : names;
}

/// 等价别名：同一 IDE 的不同 CLI 名（如 Qoder CN IDE.app 同时提供
/// qodercn 与 qoder-cn 两个命令，指向同一个应用，不重复出现在列表中）。
/// key 为别名，value 为规范名（与 daemon 侧去重逻辑一致）。
const Map<String, String> _guiEquivalentIdes = <String, String>{
  'qoder-cn': 'qodercn',
};

// ---------------------------------------------------------------------------
// 设备发现与日志行解析（纯函数，供单测覆盖）
// ---------------------------------------------------------------------------

String? _toolPathEnv;

/// 拼接开发工具常见安装目录到 PATH。
/// GUI 从桌面入口（launchd / 资源管理器）启动时系统 PATH 只有默认目录，
/// 而 adb（Android SDK / brew）、hdc（DevEco SDK）、idevice（brew）都不在其中，
/// 导致设备发现与设备日志源全部失败；终端里测试正常是因为 shell PATH 齐全。
Future<String> _toolPath() async {
  if (_toolPathEnv != null) return _toolPathEnv!;
  final dirs = <String>[
    if (!Platform.isWindows) '/opt/homebrew/bin',
    if (!Platform.isWindows) '/usr/local/bin',
  ];
  final androidHome = Platform.environment['ANDROID_HOME'];
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    dirs.addAll(<String>[
      if (androidHome != null) '$androidHome\\platform-tools',
      if (localAppData.isNotEmpty)
        '$localAppData\\Android\\Sdk\\platform-tools',
    ]);
    final sdkRoot = Directory(r'C:\Program Files\Huawei\DevEco Studio\sdk');
    if (sdkRoot.existsSync()) {
      for (final entry in sdkRoot.listSync()) {
        final toolchain = Directory('${entry.path}\\openharmony\\toolchains');
        if (toolchain.existsSync()) dirs.add(toolchain.path);
      }
    }
  } else {
    dirs.addAll(<String>[
      if (androidHome != null) '$androidHome/platform-tools',
      '$_home/Library/Android/sdk/platform-tools',
      '$_home/Android/Sdk/platform-tools',
    ]);
    // DevEco Studio SDK 的 hdc 工具链（可能存在多版本目录）。
    final sdkRoot = Directory('/Applications/DevEco-Studio.app/Contents/sdk');
    if (sdkRoot.existsSync()) {
      try {
        for (final entry in sdkRoot.listSync()) {
          final toolchain = Directory('${entry.path}/openharmony/toolchains');
          if (toolchain.existsSync()) dirs.add(toolchain.path);
        }
      } catch (_) {
        // ignored
      }
    }
  }
  final current = Platform.environment['PATH'] ?? '';
  _toolPathEnv = <String>[
    ...dirs.where((d) => d.isNotEmpty),
    current,
  ].join(Platform.isWindows ? ';' : ':');
  return _toolPathEnv!;
}

/// 以增强 PATH 运行设备工具（adb / hdc / simctl / idevice 等）。
Future<ProcessResult> _runTool(String exe, List<String> args) async {
  return Process.run(
    exe,
    args,
    environment: <String, String>{'PATH': await _toolPath()},
  );
}

// -- 路由跳转：类 → 源文件解析与 IDE 唤起 ---------------------------------

/// 与 daemon 共用的 IDE 优先级名单（~/.xb_ume_ide/config.json 的 ideOrder）。
const List<String> _guiDefaultIdeOrder = <String>[
  'qodercn',
  'qoder-cn',
  'cursor',
  'trae',
  'windsurf',
  'code',
  'androidStudio',
];

/// macOS 上未安装 shell 命令时，按 app 内置 CLI 兑底查找（与 daemon 一致）。
const Map<String, List<String>> _guiMacosVscodeAppClis = <String, List<String>>{
  'qoder-cn': <String>[
    '/Applications/Qoder CN IDE.app/Contents/Resources/app/bin/qoder-cn',
    '/Applications/Qoder.app/Contents/Resources/app/bin/qoder-cn',
  ],
  'qodercn': <String>[
    '/Applications/Qoder CN IDE.app/Contents/Resources/app/bin/qodercn',
    '/Applications/Qoder.app/Contents/Resources/app/bin/qodercn',
  ],
  'cursor': <String>[
    '/Applications/Cursor.app/Contents/Resources/app/bin/cursor',
  ],
  'trae': <String>[
    '/Applications/Trae.app/Contents/Resources/app/bin/trae',
    '/Applications/Trae CN.app/Contents/Resources/app/bin/trae',
  ],
  'windsurf': <String>[
    '/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf',
  ],
  'code': <String>[
    '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code',
  ],
};

List<String> _guiAndroidStudioBinaries() {
  if (Platform.isMacOS) {
    return <String>[
      '/Applications/Android Studio.app/Contents/MacOS/studio',
      '/Applications/Android Studio Preview.app/Contents/MacOS/studio',
    ];
  }
  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    return <String>[
      r'C:\Program Files\Android\Android Studio\bin\studio64.exe',
      r'C:\Program Files\Android\Android Studio Preview\bin\studio64.exe',
      if (localAppData.isNotEmpty)
        '$localAppData\\Programs\\Android Studio\\bin\\studio64.exe',
    ];
  }
  return <String>['studio', 'android-studio'];
}

Future<bool> _guiHasCommand(String command) async {
  try {
    final result = Platform.isWindows
        ? await Process.run('where', <String>[command])
        : await Process.run('which', <String>[command]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<bool> _guiRunChecked(String command, List<String> args) async {
  try {
    final result = await Process.run(
      command,
      args,
      runInShell: Platform.isWindows,
      environment: <String, String>{'PATH': await _toolPath()},
    );
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// vscode 系 ide 名 → macOS app 名（CLI 打开文件后用 open -a 激活窗口）。
/// CLI（如 qodercn -g file:line）只向已运行实例发 IPC，不会把窗口带到前台。
const Map<String, String> _guiMacosIdeAppNames = <String, String>{
  'qodercn': 'Qoder CN IDE',
  'qoder-cn': 'Qoder',
  'cursor': 'Cursor',
  'trae': 'Trae',
  'windsurf': 'Windsurf',
  'code': 'Visual Studio Code',
};

/// qodercn/qoder-cn 的 CLI 实为 dispatcher：`-g` 直传会被路由给独立安装的
/// QoderCN CLI（qoderclicn，未装则 exit 127）而非 IDE，导致优先级检测失败
/// 静默落到下一个 IDE（实测打开成 VSCode）。必须加 `ide` 子命令（走
/// _run_ide → Qoder CN IDE.app 的原生 launcher）；只装 CLI 未装 IDE 时
/// 同样 exit 127，正确落到下一优先级。
const Map<String, List<String>> _guiIdeCliSubcommands = <String, List<String>>{
  'qodercn': <String>['ide'],
  'qoder-cn': <String>['ide'],
};

Future<void> _guiCopyClipboard(String text) async {
  try {
    if (Platform.isMacOS) {
      final process = await Process.start('pbcopy', const <String>[]);
      process.stdin.write(text);
      await process.stdin.close();
      await process.exitCode;
    } else if (Platform.isLinux) {
      final process = await Process.start(
        'xclip',
        const <String>['-selection', 'clipboard'],
      );
      process.stdin.write(text);
      await process.stdin.close();
      await process.exitCode;
    } else if (Platform.isWindows) {
      await Process.run(
        'cmd',
        <String>['/c', 'echo $text|clip'],
        runInShell: true,
      );
    }
  } catch (_) {
    // ignored
  }
}

/// 读取 IDE 优先级配置（与 daemon 同一份 ~/.xb_ume_ide/config.json）。
List<String> _guiIdeOrder() {
  try {
    final file = File('$_home/$kInstallDirName/$kConfigName');
    if (!file.existsSync()) return _guiDefaultIdeOrder;
    final parsed = jsonDecode(file.readAsStringSync());
    final order = parsed is Map<String, Object?> ? parsed['ideOrder'] : null;
    if (order is! List) return _guiDefaultIdeOrder;
    final names = order.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    return names.isEmpty ? _guiDefaultIdeOrder : names;
  } catch (_) {
    return _guiDefaultIdeOrder;
  }
}

/// 用配置的 IDE 打开源文件（优先级与 daemon 的 IDE 跳转一致）。
/// 返回 null 表示成功，否则返回失败原因文案（已复制路径到剪贴板兑底）。
Future<String?> _guiLaunchIde(String path, int line) async {
  for (final ide in _guiIdeOrder()) {
    if (ide == 'androidStudio') {
      if (Platform.isMacOS) {
        final query = 'file=${Uri.encodeComponent(path)}&line=$line';
        if (await _guiRunChecked('open', <String>['idea://open?$query'])) {
          return null;
        }
      } else {
        for (final bin in _guiAndroidStudioBinaries()) {
          if ((await _guiHasCommand(bin)) || File(bin).existsSync()) {
            if (await _guiRunChecked(bin, <String>['--line', '$line', path])) {
              return null;
            }
          }
        }
      }
      continue;
    }
    // vscode-like：CLI 名即 ide 名（qodercn/code/...）。
    String? cli;
    if (await _guiHasCommand(ide)) {
      cli = ide;
    } else if (Platform.isMacOS) {
      for (final p in _guiMacosVscodeAppClis[ide] ?? const <String>[]) {
        if (File(p).existsSync()) {
          cli = p;
          break;
        }
      }
    }
    if (cli == null) continue;
    if (await _guiRunChecked(cli, <String>[
      ...(_guiIdeCliSubcommands[ide] ?? const <String>[]),
      '-g', '$path:$line',
    ])) {
      // 后台进程唤起不会激活 IDE 窗口，补一次 open -a 把它带到前台。
      if (Platform.isMacOS) {
        final appName = _guiMacosIdeAppNames[ide];
        if (appName != null) {
          try {
            await Process.run('open', <String>['-a', appName]);
          } catch (_) {
            // 激活失败不影响打开结果。
          }
        }
      }
      return null;
    }
  }
  await _guiCopyClipboard('$path:$line');
  return '未找到可用的 IDE，已复制路径到剪贴板';
}

/// 包名 → 包根路径缓存（来自项目 .dart_tool/package_config.json）。
final Map<String, Map<String, String>> _pkgRootsCache = <String, Map<String, String>>{};

/// 从 isolate 的 file:/// 库 uri 提取 Flutter 项目根目录。
String? _projectRootFor(List<String> fileUris) {
  for (final uri in fileUris) {
    const marker = '/.dart_tool/flutter_build/';
    final idx = uri.indexOf(marker);
    // 注意截取起点是 'file://'（7 字符），保留第三个斜杠作路径根。
    if (idx > 0) return uri.substring('file://'.length, idx);
  }
  for (final uri in fileUris) {
    final idx = uri.indexOf('/lib/');
    if (idx > 'file://'.length) return uri.substring('file://'.length, idx);
  }
  return null;
}

/// 读取项目的 .dart_tool/package_config.json，返回 包名 → 包根路径。
Map<String, String>? _pkgRootsFor(String projectRoot) {
  final cached = _pkgRootsCache[projectRoot];
  if (cached != null) return cached;
  try {
    final file = File('$projectRoot/.dart_tool/package_config.json');
    if (!file.existsSync()) return null;
    final parsed = jsonDecode(file.readAsStringSync());
    if (parsed is! Map<String, Object?>) return null;
    final packages = parsed['packages'];
    if (packages is! List) return null;
    final roots = <String, String>{};
    for (final pkg in packages) {
      if (pkg is! Map) continue;
      final name = pkg['name']?.toString();
      final rootUri = pkg['rootUri']?.toString();
      if (name == null || rootUri == null) continue;
      var root = rootUri.startsWith('file://')
          ? rootUri.substring('file://'.length) // 'file:///a' → '/a'
          : _normalizeLocalPath('$projectRoot/.dart_tool/$rootUri');
      while (root.endsWith('/')) {
        root = root.substring(0, root.length - 1);
      }
      roots[name] = root;
    }
    _pkgRootsCache[projectRoot] = roots;
    return roots;
  } catch (_) {
    return null;
  }
}

/// 归一化本机路径（处理 ../ 与 ./，package_config 的相对 rootUri 用）。
String _normalizeLocalPath(String p) {
  final abs = p.startsWith('/');
  final out = <String>[];
  for (final seg in p.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return (abs ? '/' : '') + out.join('/');
}

/// 把库 uri 解析为本机存在的源文件路径；找不到返回 null。
/// package:<pkg>/<p> → <pkgRoot>/lib/<p>；file:/// 直接映射。
String? _resolveLibraryFile(String uri) {
  String candidate;
  if (uri.startsWith('file:///')) {
    candidate = uri.substring('file:///'.length);
  } else if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final pkg = rest.substring(0, slash);
    final path = rest.substring(slash + 1);
    // 从缓存的所有项目根里找包含该包的。
    for (final roots in _pkgRootsCache.values) {
      final pkgRoot = roots[pkg];
      if (pkgRoot != null) {
        final f = File('$pkgRoot/lib/$path');
        if (f.existsSync()) return f.path;
      }
    }
    return null;
  } else {
    return null;
  }
  final f = File(candidate);
  return f.existsSync() ? f.path : null;
}

/// 在源文件中找类/mixin/enum 声明行（1-based）；找不到返回 1。
int _findClassDeclLine(String path, String className) {
  try {
    final lines = File(path).readAsLinesSync();
    final pattern = RegExp('^(?:abstract\\s+)?(?:class|enum|mixin|extension)\\s+$className\\b');
    for (var i = 0; i < lines.length; i++) {
      if (pattern.hasMatch(lines[i])) return i + 1;
    }
  } catch (_) {
    // ignored
  }
  return 1;
}

// -- 路由 State / ChangeNotifier 的静态源码解析 ------------------------------
// 前置条件：routelocate 已把路由子树中第一个用户 widget 类定位到本机源
// 文件。State 名与 ChangeNotifier 名均从源码推导，不再连 VM：
//   State 名 = widget 类 createState() 的返回类型；
//   ChangeNotifier 名 = State 字段里第一个沿 extends 链能到
//   ChangeNotifier 的类型（仅搜本机项目 lib/，框架类型自然跳过）。

/// 从 widget 类源码静态解析（State 类名, ChangeNotifier 类名列表）。
/// State 可能持有多个 CN 字段（controller2/3/4…），全部收集。
(String, List<String>) _routeStateAndNotifier(String widgetFile, String widgetCls) {
  final src = File(widgetFile).readAsStringSync();
  final widgetBody = _classBodyOf(src, widgetCls);
  if (widgetBody == null) return ('', const <String>[]);
  // createState() => _HomePageState(); / createState() { return _HomePageState(); }
  final sm = RegExp(r'createState\s*\(\s*\)\s*(?:=>|=>)\s*([A-Za-z_$][\w$]*)')
          .firstMatch(widgetBody) ??
      RegExp(r'createState\s*\(\s*\)\s*\{\s*(?:return\s+)?([A-Za-z_$][\w$]*)')
          .firstMatch(widgetBody);
  final stateName = sm?.group(1);
  if (stateName == null || stateName.isEmpty) return ('', const <String>[]);
  // State 类多与 widget 同文件（私有类）；不在时按项目类索引找。
  var stateBody = _classBodyOf(src, stateName);
  if (stateBody == null) {
    final root = _pubspecRootFor(widgetFile);
    final f = root == null ? null : _clsFileIndexFor(root)[stateName];
    if (f != null) stateBody = _classBodyOf(File(f).readAsStringSync(), stateName);
  }
  if (stateBody == null) return (stateName, const <String>[]);
  return (stateName, _notifierFieldsOf(stateBody, src, widgetFile));
}

/// 源码中类 <clsName> 的类体（大括号配平截取，不含外层花括号）。
String? _classBodyOf(String src, String clsName) {
  final m = RegExp('(?:^|\\s)(?:abstract\\s+|base\\s+|final\\s+|sealed\\s+|mixin\\s+)*class\\s+'
              '${RegExp.escape(clsName)}[\\s<]')
      .firstMatch(src);
  if (m == null) return null;
  final open = src.indexOf('{', m.end);
  if (open < 0) return null;
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  return null;
}

/// 源文件中类 <clsName> 声明子句里的直接父类名（无 extends 返回 null）。
String? _superClassOf(String src, String clsName) {
  final m = RegExp('(?:^|\\s)(?:abstract\\s+|base\\s+|final\\s+|sealed\\s+)*class\\s+'
              '${RegExp.escape(clsName)}[\\s<][^{]*\\{')
      .firstMatch(src);
  if (m == null) return null;
  return RegExp(r'\bextends\s+([A-Za-z_$][\w$]*)').firstMatch(m.group(0)!)?.group(1);
}

/// State 类体中所有 ChangeNotifier 子类字段 + 同文件内 Provider
/// ConsumerN<A, B, …> 泛型参数（页面用 Consumer2/3/4 监听多个 CN，
/// 这些 CN 经 Provider 注入、不是 State 字段），去重保序。
List<String> _notifierFieldsOf(String stateBody, String fileSrc, String stateFile) {
  final root = _pubspecRootFor(stateFile);
  // 字段声明：修饰符 + 类型（可泛型/可空）+ 字段名，以 = 或 ; 结尾。
  final fieldRe = RegExp(
      r'^\s*(?:final\s+|late\s+|const\s+|static\s+)*'
      r'([A-Za-z_$][\w$]*)(?:<[^;=]*?>)?\??\s+_?[a-z][\w$]*\s*(?:=|;)',
      multiLine: true);
  final seen = <String>{};
  final out = <String>[];
  void probe(String t) {
    if (!seen.add(t)) return;
    if (t == 'ChangeNotifier' || t == 'ValueNotifier') {
      out.add(t);
    } else if (root != null && _extendsChangeNotifier(t, root, 0)) {
      out.add(t);
    }
  }

  for (final m in fieldRe.allMatches(stateBody)) {
    probe(m.group(1)!);
  }
  // ConsumerN<...>：泛型参数即被监听的类型，逐个验证是否 CN 子类
  // （如 Consumer2<HomeController, AppTheme>；非 CN 参数自然被过滤）。
  final consumerRe = RegExp(r'\bConsumer[2-9]<([^>]*)>');
  for (final m in consumerRe.allMatches(fileSrc)) {
    for (final raw in m.group(1)!.split(',')) {
      final idm = RegExp(r'^[A-Za-z_$][\w$]*').firstMatch(raw.trim());
      if (idm != null) probe(idm.group(0)!);
    }
  }
  return out;
}

/// 项目内类型 <type> 是否沿 extends 链最终继承 ChangeNotifier。
bool _extendsChangeNotifier(String type, String root, int depth) {
  if (type == 'ChangeNotifier' || type == 'ValueNotifier') return true;
  if (depth > 4) return false;
  final f = _clsFileIndexFor(root)[type];
  if (f == null) return false; // 框架/外部类型，不在本机项目内。
  try {
    final sup = _superClassOf(File(f).readAsStringSync(), type);
    if (sup == null) return false;
    return _extendsChangeNotifier(sup, root, depth + 1);
  } catch (_) {
    return false;
  }
}

/// 从文件向上找 pubspec.yaml 所在目录（项目根）；找不到返回 null。
String? _pubspecRootFor(String file) {
  var dir = File(file).parent.path;
  while (true) {
    if (File('$dir/pubspec.yaml').existsSync()) return dir;
    final up = Directory(dir).parent.path;
    if (up == dir) return null;
    dir = up;
  }
}

/// 项目根 →（类名 → 类所在 lib 文件路径）索引，每个根首次构建后缓存。
final Map<String, Map<String, String>> _clsFileCache = <String, Map<String, String>>{};

Map<String, String> _clsFileIndexFor(String root) {
  return _clsFileCache.putIfAbsent(root, () {
    final idx = <String, String>{};
    final lib = Directory('$root/lib');
    if (lib.existsSync()) {
      for (final ent in lib.listSync(recursive: true)) {
        if (ent is! File || !ent.path.endsWith('.dart')) continue;
        String src;
        try {
          src = ent.readAsStringSync();
        } catch (_) {
          continue;
        }
        for (final m in RegExp(r'\bclass\s+([A-Za-z_$][\w$]*)').allMatches(src)) {
          idx.putIfAbsent(m.group(1)!, () => ent.path);
        }
      }
    }
    return idx;
  });
}

/// 发现本机连接的设备：Android（adb）/ 鸿蒙（hdc）/ iOS（仅 macOS）。
Future<List<Map<String, String>>> discoverDevices() async {
  final devices = <Map<String, String>>[];
  try {
    final result = await _runTool('adb', <String>['devices', '-l']);
    devices.addAll(parseAdbDevices(result.stdout.toString()));
  } catch (_) {
    // adb 未安装。
  }
  try {
    final result = await _runTool('hdc', <String>['list', 'targets']);
    for (final id in parseHdcTargets(result.stdout.toString())) {
      devices.add(<String, String>{
        'id': id,
        'platform': 'ohos',
        'name': id,
        'state': 'device',
      });
    }
  } catch (_) {
    // hdc 未安装或不在 PATH。
  }
  if (Platform.isMacOS) {
    try {
      final result = await _runTool(
        'xcrun',
        <String>['simctl', 'list', 'devices', 'booted'],
      );
      for (final sim in parseBootedSimulators(result.stdout.toString())) {
        devices.add(<String, String>{
          'id': sim['udid']!,
          'platform': 'ios-sim',
          'name': sim['name']!,
          'state': 'device',
        });
      }
    } catch (_) {
      // Xcode 命令行工具不可用。
    }
    try {
      final result = await _runTool('idevice_id', <String>['-l']);
      for (final udid in parseIdeviceIds(result.stdout.toString())) {
        devices.add(<String, String>{
          'id': udid,
          'platform': 'ios-real',
          'name': udid,
          'state': 'device',
        });
      }
    } catch (_) {
      // libimobiledevice 未安装（iOS 真机日志为 best-effort 能力）。
    }
  }
  return devices;
}

/// 解析 `adb devices -l` 输出。
List<Map<String, String>> parseAdbDevices(String out) {
  final devices = <Map<String, String>>[];
  for (var line in out.split('\n')) {
    line = line.trim();
    if (line.isEmpty ||
        line.startsWith('List of devices') ||
        line.startsWith('*')) {
      continue;
    }
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      continue;
    }
    var name = parts[0];
    for (final part in parts.skip(2)) {
      if (part.startsWith('model:')) {
        name = part.substring(6);
      }
    }
    devices.add(<String, String>{
      'id': parts[0],
      'platform': 'android',
      'name': name,
      'state': parts[1],
    });
  }
  return devices;
}

/// 解析 `hdc list targets` 输出（每行一个设备 key）。
List<String> parseHdcTargets(String out) {
  final targets = <String>[];
  for (var line in out.split('\n')) {
    line = line.trim();
    if (line.isEmpty || line.contains('error') || line.startsWith('[')) {
      continue;
    }
    targets.add(line);
  }
  return targets;
}

/// 解析 `xcrun simctl list devices booted` 输出中的已启动模拟器。
List<Map<String, String>> parseBootedSimulators(String out) {
  final result = <Map<String, String>>[];
  final re = RegExp(r'^\s*(.+?)\s+\(([0-9A-Fa-f-]{36})\)\s+\(Booted\)');
  for (final line in out.split('\n')) {
    final match = re.firstMatch(line);
    if (match != null) {
      result.add(<String, String>{
        'name': match.group(1)!.trim(),
        'udid': match.group(2)!,
      });
    }
  }
  return result;
}

/// 解析 `idevice_id -l` 输出（每行一个 UDID；新式 25 位或旧式 40 位 hex）。
List<String> parseIdeviceIds(String out) {
  final ids = <String>[];
  final re = RegExp(r'^[0-9A-Fa-f-]{20,}$');
  for (var line in out.split('\n')) {
    line = line.trim();
    if (line.isNotEmpty && re.hasMatch(line)) {
      ids.add(line);
    }
  }
  return ids;
}

Map<String, String>? parseLogcatLine(String line) {
  // `logcat -v time`：10-12 14:23:01.123 D/Flutter( 1234): message
  final re = RegExp(
    r'^(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+([VDIWEF])/(.+?)\s*\(\s*(\d+)\):\s?(.*)$',
  );
  final match = re.firstMatch(line);
  if (match == null) {
    return null;
  }
  return <String, String>{
    'ts': match.group(1)!,
    'level': match.group(2)!,
    'tag': match.group(3)!,
    'msg': match.group(5)!,
  };
}

Map<String, String>? parseHilogLine(String line) {
  // hilog：01-01 08:00:00.000  1234  5678 I C01800/MyTag: message
  final re = RegExp(
    r'^(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+(\d+)\s+(\d+)\s+([VDIWEF])\s+(\S+):\s?(.*)$',
  );
  final match = re.firstMatch(line);
  if (match == null) {
    return null;
  }
  return <String, String>{
    'ts': match.group(1)!,
    'level': match.group(4)!,
    'tag': match.group(5)!,
    'msg': match.group(6)!,
  };
}

Map<String, String>? parseIosLogLine(String line) {
  // idevicesyslog：Oct 12 14:23:01  MyApp[1234] <Notice>: message
  final syslog = RegExp(
    r'^(\w{3}\s+\d+\s+[\d:]+)\s+(\S+?)\[(\d+)\]\s+<(\w+)>:\s?(.*)$',
  );
  var match = syslog.firstMatch(line);
  if (match != null) {
    return <String, String>{
      'ts': match.group(1)!,
      'level': _iosLevel(match.group(4)!),
      'tag': match.group(2)!,
      'msg': match.group(5)!,
    };
  }
  // simctl log stream --style compact：
  // 2026-10-12 14:23:01.123-0700  MyApp[1234:5678] [Notice] message
  final compact = RegExp(
    r'^(\d{4}-\d{2}-\d{2}\s+[\d:.]+(?:[+-]\d{4})?)\s+(?:\S+\s+)?(\S+?)\[(\d+)[^\]]*\]\s*(?:\[(\w+)\]\s*)?(.*)$',
  );
  match = compact.firstMatch(line);
  if (match != null) {
    final levelWord = match.group(4);
    return <String, String>{
      'ts': match.group(1)!,
      'level': levelWord == null ? 'I' : _iosLevel(levelWord),
      'tag': match.group(2)!,
      'msg': match.group(5)!,
    };
  }
  return null;
}

String _iosLevel(String word) {
  switch (word.toLowerCase()) {
    case 'error':
    case 'fault':
      return 'E';
    case 'warning':
      return 'W';
    case 'debug':
      return 'D';
    case 'notice':
    case 'info':
    case 'default':
      return 'I';
    default:
      return 'I';
  }
}

/// 任意来源的日志行 → 结构化条目（解析失败时保留原文兜底）。
Map<String, Object?> makeLogEntry(String raw, String source) {
  Map<String, String>? parsed;
  if (source == 'logcat') {
    parsed = parseLogcatLine(raw);
  } else if (source == 'hilog') {
    parsed = parseHilogLine(raw);
  } else if (source == 'ios') {
    parsed = parseIosLogLine(raw);
  }
  final entry = parsed ?? <String, String>{
    'ts': '',
    'level': 'I',
    'tag': source,
    'msg': raw,
  };
  return <String, Object?>{
    'ts': entry['ts'],
    'level': entry['level'],
    'tag': entry['tag'],
    'msg': entry['msg'],
    'source': source,
  };
}

String _clock() {
  final now = DateTime.now();
  return '${now.hour.toString().padLeft(2, '0')}:'
      '${now.minute.toString().padLeft(2, '0')}:'
      '${now.second.toString().padLeft(2, '0')}';
}

// ---------------------------------------------------------------------------
// 系统辅助
// ---------------------------------------------------------------------------

Future<bool> pingGui(int port) async {
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(milliseconds: 500);
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port/ping'))
        .timeout(const Duration(seconds: 1));
    final response = await request.close().timeout(const Duration(seconds: 1));
    final body = await response.transform(_lenientUtf8.decoder).join();
    return body.trim() == 'xbume-gui';
  } catch (_) {
    return false;
  } finally {
    client?.close();
  }
}

Future<void> openBrowser(int port) async {
  final url = 'http://127.0.0.1:$port';
  try {
    if (Platform.isWindows) {
      await Process.start('cmd', <String>['/c', 'start', '', url],
          runInShell: true);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[url]);
    } else {
      await Process.run('xdg-open', <String>[url]);
    }
  } catch (e) {
    print('[xbume-gui] 无法自动打开浏览器，请手动访问: $url ($e)');
  }
}

Future<void> openWithSystemApp(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.start('cmd', <String>['/c', 'start', '', path],
          runInShell: true);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[path]);
    } else {
      await Process.run('xdg-open', <String>[path]);
    }
  } catch (e) {
    print('[xbume-gui] 无法打开文件 $path: $e');
  }
}

// ---------------------------------------------------------------------------
// 内嵌 Web UI
// ---------------------------------------------------------------------------

const String guiHtml = r'''
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>xb_ume 工具箱</title>
<style>
  :root { --bg:#0b0f14; --panel:#131a23; --line:#223041; --fg:#dbe6f0; --dim:#8aa0b4; --acc:#00e5ff; }
  * { box-sizing:border-box; margin:0; padding:0; }
  body { background:var(--bg); color:var(--fg); font:14px/1.5 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif; height:100vh; display:flex; flex-direction:column; }
  header { display:flex; align-items:center; gap:12px; padding:10px 16px; border-bottom:1px solid var(--line); }
  header h1 { font-size:15px; font-weight:600; color:var(--acc); margin-right:12px; }
  .tab { padding:6px 14px; border:1px solid var(--line); border-radius:6px; cursor:pointer; color:var(--dim); }
  .tab.active { color:var(--acc); border-color:var(--acc); }
  .ide-list { list-style:none; margin:10px 0 0; padding:0; }
  .ide-list li { display:flex; align-items:center; gap:8px; padding:7px 10px; border:1px solid var(--line); border-radius:6px; margin-bottom:6px; background:var(--bg2,#161b22); }
  .ide-list li .handle { color:var(--dim); cursor:grab; user-select:none; }
  .ide-list li.dragging { opacity:.45; }
  .ide-list li.dragover { border-color:var(--acc); }
  .ide-list li .notinstalled { color:var(--dim); font-size:12px; margin-left:auto; }
  #hdr-right { margin-left:auto; display:flex; align-items:center; gap:10px; }
  #wsdot { width:8px; height:8px; border-radius:50%; background:#e5484d; }
  #wsdot.on { background:#46d68c; }
  main { flex:1; overflow:auto; padding:0 16px 16px; }
  /* 各页自带顶部间距；Storage 页为 0，让 sticky 工具栏天然位于滚动起点，避免滚动初期的位移与顶部露内容 */
  .page { padding-top:16px; }
  #page-storage { padding-top:0; }
  .page { display:none; } .page.active { display:block; }
  table { width:100%; border-collapse:collapse; }
  th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); }
  th { color:var(--dim); font-weight:500; }
  button, select, input { background:var(--panel); color:var(--fg); border:1px solid var(--line); border-radius:6px; padding:6px 12px; font:inherit; }
  button { cursor:pointer; } button:hover { border-color:var(--acc); }
  button.primary { border-color:var(--acc); color:var(--acc); }
  .card { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:16px; margin-bottom:16px; }
  .row { display:flex; align-items:center; gap:10px; flex-wrap:wrap; margin-bottom:10px; }
  .muted { color:var(--dim); }
  .ok { color:#46d68c; } .bad { color:#e5484d; }
  #logview { font:12px/1.45 ui-monospace,Menlo,Consolas,monospace; background:#070b10; border:1px solid var(--line); border-radius:8px; padding:8px; height:calc(100vh - 210px); overflow-y:auto; white-space:pre-wrap; word-break:break-all; }
  .lv-V { color:#8aa0b4; } .lv-D { color:#6fa8dc; } .lv-I { color:#dbe6f0; } .lv-W { color:#f5c451; } .lv-E { color:#ef6a6a; }
  .tag { color:var(--acc); }
  .src { color:#b07de8; }
  label.chk { margin-right:6px; color:var(--dim); cursor:pointer; }
  .sbtable { width:100%; border-collapse:collapse; font-size:13px; margin-top:4px; }
  .wtrow { cursor:pointer; white-space:nowrap; }
  .wtrow:hover { background:#21262d; }
  .wtsel { background:rgba(31,111,235,.25); }
  .wtrow.wtsel { opacity:1; }
  .wtsdk { opacity:.5; }
  .wttgl { display:inline-block; width:16px; color:var(--dim); text-align:center; text-decoration:none; }
  .wtref { position:absolute; border:1px dashed #e8c268; pointer-events:none; }
  .wtreflbl { position:absolute; transform:translate(-50%,-50%); background:rgba(20,20,20,.88); color:#e8c268; font-size:11px; padding:1px 5px; border-radius:3px; pointer-events:none; white-space:nowrap; }
  mark { background:#3fb950; color:#0d1117; border-radius:2px; }
  .sbtable th, .sbtable td { text-align:left; padding:4px 8px; border-bottom:1px solid var(--line); }
  .sbtable th { color:var(--dim); font-weight:600; }
  /* Storage 表格列宽：key 列固定 400px */
  .sttable { margin-top:0; }
  .sttable th:nth-child(1), .sttable td:nth-child(1) { width:400px; }
  .sttable th:nth-child(2) { width:110px; }
  .sttable th:nth-child(4) { width:64px; }
  /* Storage 工具栏/信息行/表头固定，不随内容滚动（表头 top 由 JS 实测写入） */
  #st-toolbar { position:sticky; top:0; z-index:6; background:var(--bg); padding:10px 0 6px; border-bottom:1px solid var(--line); }
  .sthead { position:sticky; z-index:5; background:var(--bg); padding:3px 0; }
  .sttable th { position:sticky; z-index:4; background:var(--bg); }
  /* 行悬停高亮：标记鼠标当前所在行（匹配 td，不影响表头行） */
  .sbtable tr { transition: background .12s; }
  .sbtable tr:hover td { background:#182231; }
  .sbtable tr:hover a { text-decoration:underline; }
  .sbtable a { color:var(--acc); cursor:pointer; text-decoration:none; }
  .sbcrumb { font-size:13px; word-break:break-all; }
  .sbcrumb a { color:var(--acc); cursor:pointer; text-decoration:none; }
  .fgroup { display:flex; align-items:center; gap:8px; border:1px solid var(--line); border-radius:8px; padding:4px 10px; background:#0e141c; }
  .fgroup .gtitle { color:var(--acc); font-size:12px; font-weight:600; }
  .fgroup .gsep { width:1px; height:16px; background:var(--line); }
  .vlv { display:flex; align-items:center; gap:2px; }
  .vlv.dim { opacity:.45; }
  .vlv.dim label { pointer-events:none; }
  #exc-overlay { position:fixed; top:56px; right:16px; z-index:99; max-width:420px; background:#5c1a1a; color:#ffb4b4; border:1px solid #c0392b; border-radius:8px; padding:8px 12px; font-size:13px; cursor:pointer; box-shadow:0 2px 12px rgba(0,0,0,.5); display:none; word-break:break-all; }
  .exccard { border:1px solid #5c2a2a; border-radius:8px; padding:10px 12px; margin-bottom:10px; background:#140e0e; }
  .exccard .exchead { color:#ff9d9d; font-weight:600; word-break:break-all; }
  .excframe { font-family:monospace; font-size:12px; padding:1px 0; word-break:break-all; }
  .excframe .muted { color:#666; }
</style>
</head>
<body>
<header>
  <h1>xb_ume 工具箱</h1>
  <div class="tab active" data-tab="daemon">守护进程</div>
  <div class="tab" data-tab="logs">日志</div>
  <div class="tab" data-tab="exc">异常<span id="exc-badge" style="display:none;background:#c0392b;color:#fff;border-radius:9px;font-size:11px;padding:0 6px;margin-left:4px"></span></div>
  <div class="tab" data-tab="sandbox">应用沙盒</div>
  <div class="tab" data-tab="routes">路由栈</div>
  <div class="tab" data-tab="network">Network</div>
  <div class="tab" data-tab="storage">Storage</div>
  <div class="tab" data-tab="status">状态</div>
  <div class="tab" data-tab="instances">实例</div>
  <div class="tab" data-tab="shot">截图</div>
  <!-- Widget 树功能暂时隐藏（parent 参照标注定位待优化），代码保留，恢复时去掉 display:none -->
  <div class="tab" data-tab="wtree" style="display:none">Widget树</div>
  <div class="tab" data-tab="auto">自动化</div>
  <div id="hdr-right">
    <span id="vmstat" class="bad" style="display:none"></span>
    <select id="vmsel" style="display:none" onchange="setVmFilter(this.value)" title="选择要查看哪个调试会话（Flutter 输出来源），IDE 跳转不受影响"></select>
    <select id="hdrdev" onchange="selectDevice(this.value)"></select>
    <button onclick="refreshAll()" title="立即扫描设备并刷新调试会话状态">刷新</button>
    <div id="wsdot" title="页面连接状态"></div>
  </div>
</header>
<div id="exc-overlay" onclick="excGoTab()"></div>
<main>
  <section class="page active" id="page-daemon">
    <div class="card">
      <div class="row"><b>守护进程状态</b><button onclick="refreshDaemon()">刷新</button><button class="primary" onclick="restartDaemon()">重启守护进程</button><button onclick="rtOp('reassemble')" title="ext.flutter.reassemble：重建全部 Widget（实例 Tab 字段写回后立即生效）；完整热重载需 IDE 编译 kernel，此处不做">UI 重建</button><button onclick="rtOp('gc')" title="_collectAllGarbage：触发全量 GC（泄漏检测前用）">触发 GC</button><span id="rt-op-stat" class="muted"></span></div>
      <div id="daemon-status" class="muted">查询中…</div>
    </div>
    <div class="card">
      <div class="row"><b>IDE 优先级</b><button onclick="resetIdeOrder()">恢复默认</button><button onclick="openConfig()">打开配置文件</button></div>
      <ul id="ide-order-list" class="ide-list"></ul>
      <div id="ide-order-tip" class="muted" style="margin-top:4px">拖动 ☰ 调整优先级，松手即保存；进入本页会自动扫描已安装的 IDE，新装的追加到列表末尾；未安装的自动跳过</div>
    </div>
  </section>
  <section class="page" id="page-logs">
    <div class="row">
      <div class="fgroup">
        <b class="gtitle">设备日志</b>
        <label class="chk"><input type="checkbox" id="f-src-device" checked onchange="renderLogs();syncGroup()">启用</label>
        <span class="gsep"></span>
        <span class="vlv" id="vlv">
          <label class="chk" title="Verbose：最详细的跟踪日志，量最大，一般排查用不到"><input type="checkbox" class="f-lv" value="V" checked onchange="renderLogs()">V·详细</label>
          <label class="chk" title="Debug：调试日志，开发期输出"><input type="checkbox" class="f-lv" value="D" checked onchange="renderLogs()">D·调试</label>
          <label class="chk" title="Info：一般信息，正常运行日志"><input type="checkbox" class="f-lv" value="I" checked onchange="renderLogs()">I·信息</label>
          <label class="chk" title="Warning：警告，潜在问题"><input type="checkbox" class="f-lv" value="W" checked onchange="renderLogs()">W·警告</label>
          <label class="chk" title="Error：错误/异常/崩溃"><input type="checkbox" class="f-lv" value="E" checked onchange="renderLogs()">E·错误</label>
        </span>
      </div>
      <div class="fgroup" title="Flutter 输出不受级别筛选影响；来源由页头右侧的会话下拉框选择">
        <b class="gtitle">Flutter 输出</b>
        <label class="chk"><input type="checkbox" id="f-src-flutter" checked onchange="renderLogs()">启用</label>
        <span class="gsep"></span>
        <span class="muted" style="font-size:12px">按页头会话选择</span>
      </div>
      <input id="f-kw" placeholder="关键字过滤（空格分隔多个，任一命中即显示）" title="空格分隔多个关键字，日志包含任一关键字即保留" oninput="logKwInput()" style="width:300px">
      <button onclick="copyLogs(this)" title="复制当前显示（含过滤）的全部日志到剪贴板">复制</button>
      <button onclick="logTop()" title="滚动到最早日志">到顶</button>
      <button onclick="logBottom()" title="滚动到最新日志；到底后恢复自动跟随新日志">到底</button>
      <button onclick="togglePause(this)">暂停</button>
      <button onclick="clearLogs()">清屏</button>
      <a href="/api/logs.txt" target="_blank"><button>导出</button></a>
    </div>
    <div id="logview"><span class="muted">暂无日志</span></div>
    <div class="muted" style="margin-top:6px">关键字过滤支持空格分隔多个，日志包含任一关键字即显示（实时生效，新日志到达时增量追加，不打断选中/复制；新行只在底部追加，往上翻不会被强制拉底，需回到底部跟随可点底部或再滚到底）。打印规则：未选 VM 也未选设备时不打印；选 VM 打印该会话的 Flutter 输出；选设备打印该设备的设备日志及属于该设备的 VM 输出；都选则两个源都打印（互不约束）。「设备日志」= 已连接设备的全量系统日志（logcat/hilog/iOS log）；「Flutter 输出」= 调试会话的 stdout/stderr。</div>
  </section>
  <section class="page" id="page-exc">
    <div style="display:flex;align-items:center;gap:10px">
      <button onclick="excRefresh()" title="重新拉取已捕获的异常列表">刷新</button>
      <button onclick="excClear()" title="清空异常列表">清空</button>
      <input id="exc-kw" placeholder="关键字过滤（摘要/帧/源）" oninput="excRender()" style="width:220px">
      <span class="muted" id="exc-stat">全部调试会话的实时异常</span>
    </div>
    <div id="exc-body" style="margin-top:8px"><span class="muted">暂无异常（app 抛异常时会实时出现在这里）</span></div>
    <div class="muted" style="margin-top:6px">数据来源：① VM service Extension 流的 Flutter.Error 结构化事件（debug 模式框架自动发出，App 无需任何接入）；② 会话输出流中的未捕获异常块（引擎 Unhandled Exception / xb_scaffold XBErrorHandler 格式）。连续相同异常自动合并计数；栈中用户代码帧（package:）可点「跳转」用 IDE 打开对应源码（IDE 优先级同守护进程）；新异常到达时右上角出现红色浮层，点击跳到本页。</div>
  </section>
  <section class="page" id="page-sandbox">
    <input type="file" id="sb-up-file" style="display:none" onchange="sbUploadPick(this)">
    <div id="sb-up-tip" class="muted" style="display:none;margin-bottom:4px"></div>
    <div id="sb-body"><span class="muted">请先选择 VM</span></div>
    <div class="muted" style="margin-top:6px">通过 VM service 读取应用进程可见的文件系统（仅 debug 模式可用）；看哪个 app 的沙盒由页头右侧的会话选择决定。文件/文件夹均可下载（文件夹为 .tar，分段流式传输，无大小限制，超大文件耗时线性增长）。每行提供「上传」，把本地文件写入该目录（文件行则写入其所在目录），单个文件上限 12MB。</div>
  </section>
  <section class="page" id="page-routes">
    <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
      <button onclick="rtRefresh()" title="重新拉取当前会话的路由栈">刷新</button>
      <button onclick="leakCheck()" title="GC 后对本会话浏览过的页面 State 类做树上/堆上双计数：不在路由栈中但堆上仍有实例即疑似泄漏">泄漏检测</button>
      <input id="rt-leak-cls" placeholder="手动补充 State 类名（可选，逗号分隔）" style="width:230px" onkeydown="if(event.key==='Enter')leakCheck()">
      <span class="muted">选中会话 app 的 Navigator 路由栈（栈底 → 栈顶，当前路由高亮）</span>
    </div>
    <div id="rt-body" style="margin-top:8px"><span class="muted">请先选择 VM</span></div>
    <div id="rt-leak" style="margin-top:10px"></div>
    <div class="muted" style="margin-top:6px">通过 VM service 在 app 进程内读取 Navigator 路由栈（仅 debug 模式可用）；弹窗、BottomSheet 也是路由栈的一层；路由名取 settings.name，匿名 push 的页面显示 &lt;unnamed&gt;；嵌套 Navigator 分组展示。点击行内「跳转」会用配置的 IDE 打开该页面对应的源码文件（IDE 优先级与守护进程的 IDE 跳转一致，见 config.json 的 ideOrder）。行尾「操作」列可对路由执行 pop（仅栈顶，走转场）/ remove（直接出栈）；每个 Navigator 分组头部的输入框可 pushNamed 指定名字的路由（需 app 配置了 routes/onGenerateRoute，名字解析不出会明确报 UNKNOWN）。「泄漏检测」对本会话浏览过的页面 State 类做 GC 后堆扫描，不在栈中但堆上仍有实例的即疑似泄漏。</div>
  </section>
  <section class="page" id="page-network">
    <div style="display:flex;align-items:center;gap:10px">
      <input id="nw-kw" placeholder="关键字过滤（URL/方法/状态）" oninput="nwRender()" style="width:260px">
      <button onclick="nwRefresh()" title="重新拉取 app 内 ume 已捕获的请求">刷新</button>
      <button onclick="nwClear()" title="清空 app 内 ume 的 Network 记录">清空</button>
      <span class="muted">选中会话 app 内 xb_ume Network 模块捕获的请求（与手机端面板同源）</span>
    </div>
    <div id="nw-body" style="margin-top:8px"><span class="muted">请先选择 VM</span></div>
    <div class="muted" style="margin-top:6px">数据来自 app 内 xb_ume 的 Network 模块（需 app 接入 xb_ume 并配置 HttpOverrides/Dio 拦截）。点击行展开/收起详情（可同时展开多条，互不影响）；行内 cURL 复制到剪贴板；「重发」在电脑上直接按原方法/URL/请求头/请求体发起请求（不经过手机），结果附在该条详情下方。</div>
  </section>
  <section class="page" id="page-storage">
    <div id="st-toolbar" style="display:flex;align-items:center;gap:10px">
      <select id="st-file" onchange="stLoad()" style="max-width:420px"></select>
      <button onclick="stLoad()" title="重新读取选中的 shared_prefs 文件">刷新</button>
      <input id="st-kw" placeholder="关键字过滤" oninput="stRender()" style="width:180px">
      <button onclick="stAddRow()">新增</button>
      <span class="muted">shared_preferences 存储（shared_prefs XML）</span>
    </div>
    <div id="st-body"><span class="muted">请先选择 VM</span></div>
    <div class="muted" style="margin-top:6px">直接读写 app 的 shared_prefs XML 文件（Android；经 VM service 写回手机）。修改/删除/新增后立即写入文件，但 shared_preferences 插件在 app 内有内存缓存——重启 app 后生效。</div>
  </section>
  <section class="page" id="page-status">
    <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
      <button onclick="cnScan()" title="收集树上挂着的 ChangeNotifier 类 + 手动输入类，聚合实例数/监听者数/字段摘要">扫描</button>
      <input id="cn-cls" placeholder="补充 CN 类名（可选，逗号分隔）" style="width:250px" onkeydown="if(event.key==='Enter')cnScan()">
      <span class="muted">选中会话 app 的 ChangeNotifier 状态聚合（仅 debug 模式可用）</span>
    </div>
    <div id="cn-body" style="margin-top:8px"><span class="muted">请先选择 VM</span></div>
    <div class="muted" style="margin-top:6px">候选类 = Element 树上挂着的 ChangeNotifier（State 本身是 CN 的，如框架控制器）+ 手动输入；实例数 = GC 后堆扫描（getClassList + getInstances totalCount）；监听者数读 _listeners 的非 Null 槽（老版 SDK 读 _count 字段），读不到显示 ?；字段摘要取第一个实例。同类的多个实例状态可能不同，展开全量与实时查看点类名跳「实例」Tab。</div>
  </section>
  <section class="page" id="page-instances">
    <div style="display:flex;align-items:center;gap:10px">
      <button onclick="inLoadStores()" title="列出 app 端 XBUme.registerStore 注册的实例">注册表 Store</button>
      <input id="in-cls" placeholder="类名（如 CounterState / UserNotifier）" style="width:260px" onkeydown="if(event.key==='Enter')inFind()">
      <button class="primary" onclick="inFind()" title="按类名查找：先遍历 Element 树找 State，再堆扫描捞全部实例">查找实例</button>
      <span id="in-stat" class="muted">选中会话 app 内的运行时实例（仅 debug 可用）</span>
    </div>
    <div id="in-list" style="margin-top:8px"></div>
    <div id="in-tree" style="margin-top:8px"></div>
    <div class="muted" style="margin-top:6px">三条途径定位实例：「注册表 Store」读 app 端 XBUme.registerStore(id, obj) 注册的对象（如 Provider 的 ChangeNotifier）；「查找实例」按类名先遍历 Element 树（树上存活的 State），再堆扫描（getClassList + getInstances，覆盖不在树上的单例）。字段树可直接编辑基础类型字段（int/double/bool/String）并写回 app，ChangeNotifier 类型写回后自动 notifyListeners。</div>
  </section>
  <section class="page" id="page-shot">
    <div style="display:flex;align-items:center;gap:8px">
      <button class="primary" onclick="shRefresh()">刷新截图</button>
      <select id="sh-auto" onchange="shAuto(this.value)">
        <option value="">自动刷新：关</option>
        <option value="1">每 1 秒</option>
        <option value="2">每 2 秒</option>
        <option value="5">每 5 秒</option>
      </select>
      <button onclick="shSave()">下载 PNG</button>
      <label style="font-size:12px"><input type="checkbox" id="sh-rec" onchange="shRecToggle(this)"> 录制点击</label>
    </div>
    <div class="muted" id="sh-tip" style="display:none;margin-top:8px"></div>
    <div style="margin-top:8px"><img id="sh-img" style="display:none;max-width:100%;border:1px solid #444;cursor:crosshair" onclick="shImgClick(event)" alt="app 截图"></div>
    <div class="muted" style="margin-top:6px">实时截图（_flutter.screenshot，debug 模式可用）；自动刷新选低频档，避免截图流量过大。</div>
  </section>
  <section class="page" id="page-wtree">
    <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
      <button class="primary" onclick="wtLoad()">刷新树 + 截图</button>
      <button onclick="wtExpandAll()">展开全部</button>
      <button onclick="wtCollapseAll()">收起全部</button>
      <input id="wt-cls" placeholder="按类型/key 过滤" style="width:170px" oninput="wtDoFilter(this.value)">
      <span id="wt-info" class="muted"></span>
    </div>
    <div class="muted" style="margin-top:4px;font-size:12px">点截图选中业务组件（非 Flutter SDK，locator 同款判定），并显示宽高与四向间距；SDK 包装节点在树中淡化。</div>
    <div style="display:flex;gap:10px;margin-top:8px;align-items:flex-start">
      <div id="wt-body" style="flex:0 0 44%;max-height:72vh;overflow:auto;border:1px solid var(--line);padding:4px;font-size:12px;line-height:1.8"></div>
      <div style="flex:1;max-height:72vh;overflow:auto">
        <div id="wt-inner" style="position:relative;display:inline-block">
          <img id="wt-img" style="display:none;max-width:100%;border:1px solid #444;cursor:crosshair" onclick="wtImgClick(event)" alt="app 截图">
          <div id="wt-box" style="display:none;position:absolute;border:2px solid #f85149;background:rgba(248,81,73,.12);pointer-events:none"></div>
          <div id="wt-refs" style="position:absolute;left:0;top:0;pointer-events:none"></div>
        </div>
        <span id="wt-tip" class="muted">请先选择 VM，再点「刷新树 + 截图」</span>
      </div>
    </div>
    <div class="muted" style="margin-top:6px">点击树节点在截图上高亮其位置；点击截图自动选中该位置上最小的节点（含全部包装层，从深到浅可层层剥开）。过滤即时生效（显示匹配节点及其祖先）。bounds 由 app 内 localToGlobal 实时计算，按 dpr 对齐截图物理像素。</div>
  </section>
  <section class="page" id="page-auto">
    <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
      <select id="au-sel" onchange="auPick(this.value)"><option value="">— 选择场景 —</option></select>
      <button onclick="auLoad()">刷新</button>
      <input id="au-name" placeholder="场景名" style="width:120px">
      <button class="primary" onclick="auSave()">保存</button>
      <button onclick="auDelete()">删除</button>
      <button onclick="auFmt()">格式化</button>
      <button class="primary" onclick="auRun()">▶ 运行</button>
      <button onclick="auStop()">■ 停止</button>
      <label style="font-size:12px"><input type="checkbox" id="au-cont"> 失败继续</label>
      <button onclick="auImportRec()">导入录制(<span id="au-rec-n">0</span>)</button>
    </div>
    <div class="muted" style="margin-top:4px;font-size:12px">步骤 JSON：[{"type":"tap","x":400,"y":280,"phys":true},{"type":"input","text":"hi"},{"type":"swipe","x1":400,"y1":400,"x2":400,"y2":150,"ms":400,"phys":true},{"type":"wait","ms":1000},{"type":"back"},{"type":"navigate","name":"xxx"},{"type":"assertVisible","widget":"页面类名"},{"type":"assertRoute","name":"路由名"},{"type":"assertInstance","class":"类名"},{"type":"assertText","contains":"xx"},{"type":"assertRequest","urlContains":"/api/xx","method":"GET"},{"type":"assertLog","contains":"xx","level":"E"},{"type":"eval","expr":"1+1","expect":"2"}]。tap/swipe 坐标：phys=true 为截图物理像素（录制坐标），否则逻辑像素；assertText/assertRequest/assertLog 反向断言用 notContains / not:true，时间窗用 withinLastMs。</div>
    <textarea id="au-steps" style="width:100%;height:180px;margin-top:6px;font-family:monospace;font-size:12px;border:1px solid var(--line);background:var(--bg);color:var(--fg)" placeholder='[{"type":"tap","x":400,"y":280,"phys":true}]'></textarea>
    <div style="margin-top:6px"><span id="au-prog" class="muted"></span></div>
    <div id="au-report" style="margin-top:6px;max-height:45vh;overflow:auto"></div>
    <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:12px;border-top:1px solid var(--line);padding-top:8px">
      <b style="font-size:13px">AI 驱动</b>
      <input id="ai-goal" placeholder="描述要做什么，如：打开 XBDialogInputDemo 页面再返回首页" style="flex:1;min-width:240px">
      <select id="ai-goal-hist" onchange="aiGoalPick()" style="max-width:160px"><option value="">历史▼</option></select>
      <button class="primary" onclick="aiStart()">▶ AI 执行</button>
      <button onclick="aiStop()">■ 停止</button>
      <button onclick="aiCfgShow()">AI 设置</button>
      <button id="ai-save-btn" style="display:none" onclick="aiSaveScenario()">存为场景</button>
    </div>
    <div id="ai-cfg" style="display:none;margin-top:6px;padding:8px;border:1px solid var(--line);font-size:12px">
      <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
        <span>接口地址</span><input id="ai-base" style="width:280px" placeholder="https://api.openai.com/v1">
        <span>密钥</span><input id="ai-key" type="password" style="width:180px">
        <span>模型</span><input id="ai-model" style="width:170px" placeholder="gpt-4o / qwen-vl-max …">
        <button onclick="aiCfgSave()">保存配置</button>
        <span class="muted">OpenAI 兼容 /chat/completions，需支持图片输入</span>
      </div>
      <div style="display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin-top:6px">
        <span>上下文开关</span>
        <label><input type="checkbox" id="ai-ctx-routes" checked> 路由栈</label>
        <label><input type="checkbox" id="ai-ctx-text" checked> 页面文本</label>
        <label><input type="checkbox" id="ai-ctx-net" checked> 网络请求</label>
        <label><input type="checkbox" id="ai-ctx-log" checked> 增量日志</label>
        <span class="muted">关闭后 AI 消息不含对应上下文、对应断言步骤被忽略</span>
      </div>
    </div>
    <div style="margin-top:6px"><span id="ai-prog" class="muted"></span></div>
    <div id="ai-report" style="margin-top:6px;max-height:45vh;overflow:auto"></div>
  </section>
</main>
<script>
var ws = null, devices = [], selected = null, logs = [], paused = false, vmFilter = '';
var fpBySource = {}, vmFilterFp = '', vmMiss = 0; // 会话指纹映射、所选会话指纹与瞬断容忍计数
var vmApps = {}; // 会话来源 → 应用包名（/api/daemon 返回，回放日志无 app 时兑底展示）
var vmUriBySource = {}; // 会话来源 → VM service ws uri（沙盒 Tab 用）
var platformNames = { android: 'Android', ohos: '鸿蒙', 'ios-sim': 'iOS 模拟器', 'ios-real': 'iOS 真机' };
function connect() {
  ws = new WebSocket('ws://' + location.host + '/ws');
  ws.onopen = function(){ document.getElementById('wsdot').classList.add('on'); };
  ws.onclose = function(){ document.getElementById('wsdot').classList.remove('on'); setTimeout(connect, 1500); };
  ws.onmessage = function(e){
    var msg = JSON.parse(e.data);
    if (msg.type === 'snapshot') { devices = msg.devices; selected = msg.selected; logs = msg.items; excItems = msg.exceptions || []; excBadge(); renderHdrDev(); renderLogs(); refreshDaemon(); }
    else if (msg.type === 'devices') { devices = msg.devices; renderHdrDev(); }
    else if (msg.type === 'logs') { msg.items.forEach(function(l){ l._seq = ++logSeq; }); logs = logs.concat(msg.items); if (logs.length > 5000) logs = logs.slice(-5000); if (!paused) logFlushNew(); }
    else if (msg.type === 'cleared') { logs = []; renderLogs(); }
    else if (msg.type === 'exception') { excOnItem(msg.item); }
    else if (msg.type === 'exceptionsCleared') { excItems = []; excRender(); }
  };
}
connect();
document.querySelectorAll('.tab').forEach(function(t){
  t.onclick = function(){
    document.querySelectorAll('.tab').forEach(function(x){ x.classList.remove('active'); });
    document.querySelectorAll('.page').forEach(function(x){ x.classList.remove('active'); });
    t.classList.add('active');
    document.getElementById('page-' + t.dataset.tab).classList.add('active');
    if (t.dataset.tab === 'daemon') { refreshDaemon(); loadIdeOrder(); }
    else if (t.dataset.tab === 'sandbox') sbRefresh();
    else if (t.dataset.tab === 'routes') rtRefresh();
    else if (t.dataset.tab === 'network') nwRefresh();
    else if (t.dataset.tab === 'storage') stRefresh();
    else if (t.dataset.tab === 'status') cnScan();
    else if (t.dataset.tab === 'instances') inRefresh();
    else if (t.dataset.tab === 'shot') shRefresh();
    else if (t.dataset.tab === 'auto') { auLoad(); aiPoll(); aiGoalsLoad(); } // aiPoll 仅拉取渲染，不启动任务；页面重载后恢复报告
    else if (t.dataset.tab === 'wtree') wtLoad();
    else if (t.dataset.tab === 'exc') { document.getElementById('exc-overlay').style.display = 'none'; excBadge(); excRefresh(); }
  };
});
function esc(s){ var d = document.createElement('div'); d.textContent = s == null ? '' : String(s); return d.innerHTML; }
// -- 异常 Tab -------------------------------------------------------------
var excItems = [];      // 异常记录（后端 schema：id/summary/desc/widget/stack/…）
var excById = {};       // id → 记录（栈帧行「跳转」回调按 id+idx 反查，免转义）
var excOvTimer = null;  // 红浮层自动隐藏定时器
function excBadge(){
  var b = document.getElementById('exc-badge');
  var t = document.querySelector('.tab.active');
  if (excItems.length && (!t || t.dataset.tab !== 'exc')) {
    b.style.display = ''; b.textContent = excItems.length;
  } else { b.style.display = 'none'; }
}
function excGoTab(){
  var t = document.querySelector('.tab[data-tab="exc"]');
  if (t) t.click(); // 复用 tab 点击链：切页 + 隐藏浮层 + excRefresh
}
function excOnItem(item){
  if (!item) return;
  var i = excItems.length - 1;
  for (; i >= 0; i--) { if (excItems[i].id === item.id) break; }
  if (i >= 0) excItems[i] = item; else excItems.push(item);
  var t = document.querySelector('.tab.active');
  if (t && t.dataset.tab === 'exc') { excRender(); return; }
  excBadge();
  var ov = document.getElementById('exc-overlay');
  // 必须写显式 display 值：CSS 里 #exc-overlay 默认 display:none，
  // 置空字符串会回落到 none，浮层永远不显示（浏览器实测确认）。
  ov.style.display = 'block';
  ov.textContent = '\u26a0 异常' + (item.count > 1 ? ' ×' + item.count : '') +
    ' [' + (item.channel === 'framework' ? '框架' : '未捕获') + '] ' + (item.summary || '');
  if (excOvTimer) clearTimeout(excOvTimer);
  excOvTimer = setTimeout(function(){ ov.style.display = 'none'; excOvTimer = null; }, 12000);
}
function excRefresh(){
  fetch('/api/exceptions').then(function(r){ return r.json(); }).then(function(d){
    excItems = d.items || [];
    excRender();
  }).catch(function(e){ document.getElementById('exc-stat').textContent = '拉取失败：' + e; });
}
function excClear(){
  fetch('/api/exceptions/clear', { method: 'POST' })
    .then(function(){ excItems = []; excRender(); })
    .catch(function(e){ alert('清空失败：' + e); });
}
function excRender(){
  var body = document.getElementById('exc-body');
  var stat = document.getElementById('exc-stat');
  var kw = (document.getElementById('exc-kw').value || '').toLowerCase();
  var list = excItems.filter(function(it){
    if (!kw) return true;
    var hay = (it.summary || '') + ' ' + (it.desc || '') + ' ' + (it.source || '') +
      ' ' + (it.channel || '') + ' ' + (it.app || '') + ' ' + (it.widget || '');
    (it.stack || []).forEach(function(f){
      hay += ' ' + (f.raw || '') + ' ' + (f.method || '') + ' ' + (f.uri || '');
    });
    return hay.toLowerCase().indexOf(kw) >= 0;
  });
  stat.textContent = excItems.length
    ? ('共 ' + excItems.length + ' 条异常' + (list.length < excItems.length ? '，过滤后 ' + list.length + ' 条' : ''))
    : '全部调试会话的实时异常';
  if (!list.length) {
    body.innerHTML = '<span class="muted">' +
      (excItems.length ? '无匹配项' : '暂无异常（app 抛异常时会实时出现在这里）') + '</span>';
    excBadge();
    return;
  }
  var html = '';
  for (var i = list.length - 1; i >= 0; i--) html += excCardHtml(list[i]); // 新的在前
  body.innerHTML = html;
  excBadge();
}
function excCardHtml(it){
  excById[it.id] = it;
  var h = '<div class="exccard">';
  h += '<div class="exchead">' + esc(it.time || '') +
    ' <b style="color:' + (it.channel === 'framework' ? '#e74c3c' : '#e67e22') + '">' +
    (it.channel === 'framework' ? '框架' : '未捕获') + '</b> ' + esc(it.source || '');
  if (it.app) h += ' · ' + esc(it.app);
  if (it.os) h += ' · ' + esc(it.os);
  if (it.count > 1) h += ' <span style="color:#e67e22">×' + it.count + '</span>';
  h += ' <a href="javascript:void(0)" onclick="excCopy(' + it.id + ',this)" title="复制本条异常全部内容">复制</a>';
  h += '</div>';
  h += '<div style="margin-top:4px">' + esc(it.summary || '') + '</div>';
  if (it.desc) h += '<div class="muted" style="margin-top:4px;white-space:pre-wrap">' + esc(it.desc) + '</div>';
  if (it.widget) {
    h += '<div style="margin-top:4px">Widget：' + esc(it.widget);
    if (it.widgetFile) h += ' <a href="javascript:void(0)" onclick="excJump(' + it.id + ',' + (it.widgetLine || 1) + ',this)">跳转</a>';
    h += '</div>';
  }
  if (it.stack && it.stack.length) {
    h += '<div style="margin-top:6px;font-size:12px">';
    it.stack.forEach(function(f, idx){
      var raw = f.raw || ((f.method || '') + ' (' + (f.uri || '') + ':' + (f.line || 0) + ')');
      h += '<div class="excframe">' + esc(raw);
      if (f.file) h += ' <a href="javascript:void(0)" onclick="excFrameJump(' + it.id + ',' + idx + ',this)">跳转</a>';
      h += '</div>';
    });
    h += '</div>';
  }
  h += '</div>';
  return h;
}
function excJump(id, line, el){ // 相关 widget 的 IDE 跳转
  var it = excById[id];
  if (!it || !it.widgetFile) return;
  excOpenIde(it.widgetFile, line, el);
}
function excCopy(id, el){ // 复制本条异常全部内容（头部/摘要/描述/Widget/栈帧逐行）
  var it = excById[id];
  if (!it) return;
  var lines = [];
  var head = (it.time || '') + ' [' + (it.channel === 'framework' ? '框架' : '未捕获') + '] ' + (it.source || '');
  if (it.app) head += ' · ' + it.app;
  if (it.os) head += ' · ' + it.os;
  if (it.count > 1) head += ' ×' + it.count;
  lines.push(head);
  if (it.summary) lines.push(it.summary);
  if (it.desc) lines.push(it.desc);
  if (it.widget) lines.push('Widget：' + it.widget + (it.widgetFile ? '（' + it.widgetFile + ':' + (it.widgetLine || 1) + '）' : ''));
  (it.stack || []).forEach(function(f){
    lines.push(f.raw || ((f.method || '') + ' (' + (f.uri || '') + ':' + (f.line || 0) + ')'));
  });
  var text = lines.join('\n');
  var done = function(){ el.textContent = '已复制✓'; setTimeout(function(){ el.textContent = '复制'; }, 1500); };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done, function(){ copyLogsFallback(text); done(); });
  } else { copyLogsFallback(text); done(); }
}
function excFrameJump(id, idx, el){ // 栈帧行的 IDE 跳转（仅用户代码帧有 file）
  var it = excById[id];
  var f = it && it.stack && it.stack[idx];
  if (!f || !f.file) return;
  excOpenIde(f.file, f.line, el);
}
function excOpenIde(file, line, el){
  el.textContent = '打开中…';
  fetch('/api/openide?file=' + encodeURIComponent(file) + '&line=' + (line || 1))
    .then(function(r){ return r.json(); })
    .then(function(d){ el.textContent = d.ok ? '已打开 ✓' : '失败：' + (d.message || '未知错误'); })
    .catch(function(e){ el.textContent = '失败：' + e; });
}
// -- 截图 Tab ------------------------------------------------------------
var shTimer = null;
// -- 运行时操作（reassemble / GC） ---------------------------------------
function rtOp(op){
  var uri = vmFilter ? (vmUriBySource[vmFilter] || '') : '';
  var stat = document.getElementById('rt-op-stat');
  if (!uri) { stat.textContent = '请先选择 VM 会话'; return; }
  stat.textContent = op === 'reassemble' ? '重建中…' : 'GC 中…';
  fetch('/api/runtime/op?uri=' + encodeURIComponent(uri) + '&op=' + op, { method: 'POST' })
    .then(function(r){ return r.json(); })
    .then(function(d){
      stat.textContent = d.ok
        ? (op === 'reassemble' ? 'UI 已重建 ✓' : 'GC 已触发 ✓')
        : '失败：' + (d.error || '未知错误');
    })
    .catch(function(e){ stat.textContent = '失败：' + e; });
}
function shUri(){ return vmFilter ? (vmUriBySource[vmFilter] || '') : ''; }
function shRefresh(){
  var uri = shUri();
  var img = document.getElementById('sh-img');
  var tip = document.getElementById('sh-tip');
  if (!uri) {
    img.style.display = 'none'; tip.style.display = '';
    tip.textContent = '请先在页头选择 VM 会话（仅 debug 模式可用）';
    return;
  }
  img.onerror = function(){
    img.style.display = 'none'; tip.style.display = '';
    tip.textContent = '截图失败（app 需 debug 模式且在前台运行；会话可能已断开）';
  };
  img.onload = function(){ img.style.display = ''; if (!document.getElementById('sh-rec').checked) tip.style.display = 'none'; };
  img.style.display = 'none';
  img.src = '/api/screenshot?uri=' + encodeURIComponent(uri) + '&t=' + Date.now();
}
function shAuto(v){
  if (shTimer) { clearInterval(shTimer); shTimer = null; }
  if (v) shTimer = setInterval(function(){
    var t = document.querySelector('.tab.active');
    if (t && t.dataset.tab === 'shot') shRefresh();
  }, (+v) * 1000);
}
function shSave(){
  var uri = shUri(); if (!uri) return;
  var a = document.createElement('a');
  a.href = '/api/screenshot?uri=' + encodeURIComponent(uri) + '&t=' + Date.now();
  a.download = 'xbume-shot-' + new Date().toISOString().replace(/[:.]/g, '-') + '.png';
  a.click();
}
// ── P10 自动化路径：截图录制点击 + 场景列表/编辑/运行/报告 ──
var auRecBuf = [];   // 录制点击缓冲（sh-rec 开启时点击截图追加 tap 步骤，物理像素坐标）
var auTimer = null;  // 运行状态轮询定时器
var auTotal = 0;     // 本次运行总步数（POST /api/auto/run 响应）
function shRecToggle(cb){
  auRecBuf = [];
  document.getElementById('au-rec-n').textContent = '0';
  var tip = document.getElementById('sh-tip');
  if (cb.checked) { tip.style.display = ''; tip.textContent = '录制点击已开启：点击截图会追加 tap 步骤（物理像素坐标），到「自动化」Tab 导入'; }
  else { tip.style.display = 'none'; }
}
function shImgClick(ev){
  if (!document.getElementById('sh-rec').checked) return;
  var img = document.getElementById('sh-img');
  if (!img.src || img.style.display === 'none') return;
  // 截图 PNG 为物理像素；img 被缩放显示，按显示比例换算回原图坐标
  var px = Math.round(ev.offsetX / img.clientWidth * img.naturalWidth);
  var py = Math.round(ev.offsetY / img.clientHeight * img.naturalHeight);
  auRecBuf.push({ type: 'tap', x: px, y: py, phys: true });
  document.getElementById('au-rec-n').textContent = String(auRecBuf.length);
}
function auLoad(){
  fetch('/api/auto/list').then(function(r){ return r.json(); }).then(function(j){
    var sel = document.getElementById('au-sel');
    var cur = sel.value;
    var html = '<option value="">— 选择场景 —</option>';
    (j.items || []).forEach(function(it){
      html += '<option value="' + esc(it.name) + '"' + (it.name === cur ? ' selected' : '') + '>'
        + esc(it.name) + '（' + it.steps + ' 步）</option>';
    });
    sel.innerHTML = html;
  });
}
function auPick(name){
  if (!name) return;
  fetch('/api/auto/get?name=' + encodeURIComponent(name)).then(function(r){ return r.json(); }).then(function(j){
    if (!j.ok) { alert(j.error || '读取失败'); return; }
    document.getElementById('au-name').value = j.name;
    document.getElementById('au-steps').value = JSON.stringify(j.steps, null, 2);
  });
}
function auSteps(){
  try { return JSON.parse(document.getElementById('au-steps').value || '[]'); }
  catch (e) { alert('步骤 JSON 解析失败：' + e); return null; }
}
function auSave(){
  var name = document.getElementById('au-name').value.trim();
  var steps = auSteps(); if (!steps) return;
  if (!name) { alert('请填写场景名'); return; }
  if (name.length > 64 || !/^[\w\u4e00-\u9fff-]+$/.test(name)) { alert('场景名只能包含中文、字母、数字、下划线、横线（不能含空格、点号等），长度 1-64'); return; }
  fetch('/api/auto/save', { method: 'POST', headers: {'Content-Type':'application/json'},
    body: JSON.stringify({ name: name, steps: steps }) })
    .then(function(r){ return r.json().catch(function(){ return {ok:false, error:'保存失败（HTTP ' + r.status + '）'}; }); })
    .then(function(j){ if (j.ok) auLoad(); else alert(j.error || '保存失败'); })
    .catch(function(e){ alert('保存请求失败: ' + e); });
}
function auDelete(){
  var name = document.getElementById('au-name').value.trim();
  if (!name || !confirm('删除场景 ' + name + '？')) return;
  fetch('/api/auto/delete?name=' + encodeURIComponent(name), { method: 'POST' })
    .then(function(r){ return r.json().catch(function(){ return {ok:false, error:'删除失败（HTTP ' + r.status + '）'}; }); })
    .then(function(j){ if (j.ok) { document.getElementById('au-steps').value = ''; auLoad(); } else alert(j.error || '删除失败'); })
    .catch(function(e){ alert('删除请求失败: ' + e); });
}
function auFmt(){
  var steps = auSteps(); if (!steps) return;
  document.getElementById('au-steps').value = JSON.stringify(steps, null, 2);
}
function auImportRec(){
  if (!auRecBuf.length) { alert('录制缓冲为空：到「截图」Tab 勾选「录制点击」后点击截图'); return; }
  document.getElementById('au-steps').value = JSON.stringify(auRecBuf, null, 2);
}
function auRun(){
  var uri = shUri(); if (!uri) { alert('请先在页头选择 VM 会话'); return; }
  var steps = auSteps(); if (!steps || !steps.length) { alert('步骤为空'); return; }
  var cont = document.getElementById('au-cont').checked ? '1' : '0';
  var nm = document.getElementById('au-name').value.trim();
  document.getElementById('au-report').innerHTML = '';
  fetch('/api/auto/run?uri=' + encodeURIComponent(uri) + '&continue=' + cont + (nm ? '&name=' + encodeURIComponent(nm) : ''),
    { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(steps) })
    .then(function(r){ return r.json().then(function(j){ j._code = r.status; return j; }); })
    .then(function(j){
      if (!j.ok) { alert(j.error || '启动失败（' + j._code + '）'); return; }
      auTotal = j.total || steps.length;
      if (auTimer) clearInterval(auTimer);
      auTimer = setInterval(auPoll, 500);
      auPoll();
    });
}
function auStop(){
  fetch('/api/auto/stop', { method: 'POST' });
}
function auPoll(){
  fetch('/api/auto/status').then(function(r){ return r.json(); }).then(function(j){
    var prog = document.getElementById('au-prog');
    var done = !j.running && j.results.length > 0;
    var fails = j.results.filter(function(r){ return r.status === 'fail'; }).length;
    prog.textContent = j.running
      ? ('执行中：' + j.name + ' · 步骤 ' + (j.cur + 1) + '/' + auTotal + '（已完成 ' + j.results.length + '）')
      : (done ? ('结束：' + j.name + ' · 共 ' + j.results.length + ' 步，失败 ' + fails) : '');
    if (!j.running && auTimer) { clearInterval(auTimer); auTimer = null; }
    auRenderReport(j.results);
  });
}
function auRenderReport(results){
  var el = document.getElementById('au-report');
  var bd = 'padding:3px 6px;border-bottom:1px solid var(--line)';
  var html = '<table style="border-collapse:collapse;width:100%;font-size:12px">'
    + '<tr style="text-align:left"><th style="' + bd + '">#</th>'
    + '<th style="' + bd + '">类型</th>'
    + '<th style="' + bd + '">状态</th>'
    + '<th style="' + bd + '">耗时</th>'
    + '<th style="' + bd + '">期望</th>'
    + '<th style="' + bd + '">实际</th>'
    + '<th style="' + bd + '">截图</th></tr>';
  (results || []).forEach(function(r){
    var c = r.status === 'pass' ? '#4caf50' : (r.status === 'fail' ? '#ef5350' : '#8aa0b4');
    var act = r.actual + (r.error ? ' | ' + r.error : '');
    html += '<tr>'
      + '<td style="' + bd + '">' + (r.index + 1) + '</td>'
      + '<td style="' + bd + '">' + esc(r.type) + '</td>'
      + '<td style="' + bd + ';color:' + c + '">' + esc(r.status) + '</td>'
      + '<td style="' + bd + '">' + r.ms + 'ms</td>'
      + '<td style="' + bd + '">' + esc(r.expect) + '</td>'
      + '<td style="' + bd + ';max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + esc(act) + '">' + esc(act) + '</td>'
      + '<td style="' + bd + '">'
      + (r.shot ? '<a href="/api/auto/artifact?f=' + encodeURIComponent(r.shot) + '" target="_blank">图</a>' : '-')
      + '</td></tr>';
  });
  el.innerHTML = html + '</table>';
}
// -- P11 AI 驱动：自然语言目标 → 截图→AI→步骤→执行 循环 --------------------
var aiTimer = null;
function aiCfgShow(){
  var el = document.getElementById('ai-cfg');
  var show = el.style.display === 'none';
  el.style.display = show ? '' : 'none';
  if (!show) return;
  fetch('/api/ai/config').then(function(r){ return r.json(); }).then(function(j){
    document.getElementById('ai-base').value = j.baseUrl || '';
    document.getElementById('ai-model').value = j.model || '';
    var k = document.getElementById('ai-key');
    k.value = j.apiKey || '';
    k.dataset.masked = j.apiKey || '';
    var c = j.ctx || {};
    document.getElementById('ai-ctx-routes').checked = c.routes !== false;
    document.getElementById('ai-ctx-text').checked = c.text !== false;
    document.getElementById('ai-ctx-net').checked = c.net !== false;
    document.getElementById('ai-ctx-log').checked = c.log !== false;
  });
}
function aiCfgSave(){
  var k = document.getElementById('ai-key');
  var key = k.value.trim();
  if (key === (k.dataset.masked || '')) key = ''; // 未修改 → 不覆盖旧密钥
  fetch('/api/ai/config', { method: 'POST', headers: {'Content-Type':'application/json'},
    body: JSON.stringify({ baseUrl: document.getElementById('ai-base').value.trim(),
      apiKey: key, model: document.getElementById('ai-model').value.trim(),
      ctx: { routes: document.getElementById('ai-ctx-routes').checked,
        text: document.getElementById('ai-ctx-text').checked,
        net: document.getElementById('ai-ctx-net').checked,
        log: document.getElementById('ai-ctx-log').checked } }) })
    .then(function(r){ return r.json(); })
    .then(function(j){ alert(j.ok ? 'AI 配置已保存' : (j.error || '保存失败')); });
}
function aiStart(){
  var uri = shUri(); if (!uri) { alert('请先在页头选择 VM 会话'); return; }
  var goal = document.getElementById('ai-goal').value.trim();
  if (!goal) { alert('请先描述目标'); return; }
  document.getElementById('ai-report').innerHTML = '';
  document.getElementById('ai-save-btn').style.display = 'none';
  fetch('/api/ai/run?uri=' + encodeURIComponent(uri) + '&goal=' + encodeURIComponent(goal), { method: 'POST' })
    .then(function(r){ return r.json().then(function(j){ j._code = r.status; return j; }); })
    .then(function(j){
      if (!j.ok) { alert(j.error || '启动失败（' + j._code + '）'); return; }
      aiGoalsLoad();
      if (aiTimer) clearInterval(aiTimer);
      aiTimer = setInterval(aiPoll, 800);
      aiPoll();
    });
}
function aiGoalsLoad(){
  fetch('/api/ai/goals').then(function(r){ return r.json(); }).then(function(j){
    var sel = document.getElementById('ai-goal-hist');
    var html = '<option value="">历史▼</option>';
    (j.items || []).forEach(function(g){
      html += '<option value="' + esc(g) + '">' + esc(g.length > 40 ? g.substring(0, 40) + '…' : g) + '</option>';
    });
    html += '<option value="__clear__">✕ 清空历史</option>';
    sel.innerHTML = html;
  });
}
function aiGoalPick(){
  var sel = document.getElementById('ai-goal-hist');
  var v = sel.value;
  sel.value = '';
  if (!v) return;
  if (v === '__clear__') {
    if (!confirm('清空全部历史目标？')) return;
    fetch('/api/ai/goals/clear', { method: 'POST' }).then(function(){ aiGoalsLoad(); });
    return;
  }
  document.getElementById('ai-goal').value = v;
}
function aiStop(){ fetch('/api/ai/stop', { method: 'POST' }); }
function aiPoll(){
  fetch('/api/ai/status').then(function(r){ return r.json(); }).then(function(j){
    var rounds = j.rounds || [];
    var prog = document.getElementById('ai-prog');
    var lastErr = '';
    for (var i = rounds.length - 1; i >= 0; i--) { if (rounds[i].error) { lastErr = rounds[i].error; break; } }
    prog.textContent = j.running
      ? ('AI 执行中：第 ' + (j.cur + 1) + ' 轮 · ' + (rounds[j.cur] && rounds[j.cur].think ? String(rounds[j.cur].think).substring(0, 60) : '思考中…'))
      : (rounds.length ? ('结束：' + rounds.length + ' 轮' + (j.done ? ' · AI 判定目标完成' : (lastErr ? ' · ' + lastErr : ''))) : '');
    if (!j.running && aiTimer) {
      clearInterval(aiTimer); aiTimer = null;
      if (rounds.length) document.getElementById('ai-save-btn').style.display = '';
    }
    aiRenderReport(rounds);
  });
}
function aiRenderReport(rounds){
  var el = document.getElementById('ai-report');
  var bd = 'padding:3px 6px;border-bottom:1px solid var(--line)';
  var html = '';
  (rounds || []).forEach(function(r){
    html += '<div style="border:1px solid var(--line);margin-bottom:6px;padding:6px">'
      + '<div style="display:flex;gap:8px;align-items:flex-start">'
      + '<b style="font-size:12px">轮 ' + (r.round + 1) + '</b>'
      + (r.shot ? '<a href="/api/auto/artifact?f=' + encodeURIComponent(r.shot) + '" target="_blank">'
        + '<img src="/api/auto/artifact?f=' + encodeURIComponent(r.shot) + '" style="height:64px;border:1px solid #444"></a>' : '')
      + '<div style="flex:1;font-size:12px">'
      + ((r.retries || 0) > 0 ? '<span style="color:#e6b800">AI 调用重试 ' + r.retries + ' 次</span><br>' : '')
      + (r.error ? '<span style="color:#ef5350">' + esc(r.error) + '</span><br>' : '')
      + (r.think ? 'AI：' + esc(r.think) : '')
      + '</div></div>';
    if ((r.results || []).length) {
      html += '<table style="border-collapse:collapse;width:100%;font-size:12px;margin-top:4px">'
        + '<tr style="text-align:left"><th style="' + bd + '">#</th><th style="' + bd + '">类型</th><th style="' + bd + '">状态</th><th style="' + bd + '">耗时</th><th style="' + bd + '">实际</th></tr>';
      r.results.forEach(function(s){
        var c = s.status === 'pass' ? '#4caf50' : (s.status === 'fail' ? '#ef5350' : '#8aa0b4');
        html += '<tr><td style="' + bd + '">' + (s.index + 1) + '</td>'
          + '<td style="' + bd + '">' + esc(s.type) + '</td>'
          + '<td style="' + bd + ';color:' + c + '">' + esc(s.status) + '</td>'
          + '<td style="' + bd + '">' + s.ms + 'ms</td>'
          + '<td style="' + bd + '">' + esc(s.actual + (s.error ? ' | ' + s.error : '')) + '</td></tr>';
      });
      html += '</table>';
    }
    html += '</div>';
  });
  el.innerHTML = html;
}
function aiSaveScenario(){
  var name = prompt('场景名（保存后可在上方场景回放）\n只允许中文/字母/数字/下划线/横线，长度 1-64');
  if (!name) return;
  name = name.trim();
  if (!name || name.length > 64 || !/^[\w\u4e00-\u9fff-]+$/.test(name)) { alert('场景名只能包含中文、字母、数字、下划线、横线（不能含空格、点号等），长度 1-64'); return; }
  fetch('/api/ai/save', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({ name: name }) })
    .then(function(r){ return r.json().catch(function(){ return {ok:false, error:'保存失败（HTTP ' + r.status + '）'}; }); })
    .then(function(j){ if (j.ok) { alert('已保存 ' + j.steps + ' 步，可回放'); auLoad(); } else alert(j.error || '保存失败'); })
    .catch(function(e){ alert('保存请求失败: ' + e); });
}
function renderHdrDev() {
  var html = '<option value="">未选择设备</option>';
  devices.forEach(function(d){
    html += '<option value="' + esc(d.id) + '" ' + (d.id === selected ? 'selected' : '') + '>'
      + (platformNames[d.platform] || d.platform) + ' · ' + esc(d.name) + '（' + esc(d.state) + '）</option>';
  });
  document.getElementById('hdrdev').innerHTML = html;
}
function refreshDevices(){ ws.send(JSON.stringify({type:'refresh'})); }
function refreshAll(){ refreshDevices(); refreshDaemon(); }
function selectDevice(id){ selected = id; ws.send(JSON.stringify({type:'select', id: id})); renderLogs(); renderHdrDev(); }
var osByPlatform = { android: 'android', ohos: 'ohos', 'ios-sim': 'ios', 'ios-real': 'ios' };
var logSeq = 0, logCursor = 0, logDebounce = null, logLastKey = null;
function logKws(){
  return document.getElementById('f-kw').value.trim().toLowerCase()
    .split(/\s+/).filter(function(s){ return s; });
}
function logKwInput(){ // 防抖：连续输入只重建一次
  if (logDebounce) clearTimeout(logDebounce);
  logDebounce = setTimeout(function(){ logDebounce = null; renderLogs(); }, 200);
}
function logParams() {
  var p = { wantDevice: document.getElementById('f-src-device').checked,
    wantFlutter: document.getElementById('f-src-flutter').checked, lv: {},
    kws: logKws(), vmFilter: vmFilter, selected: selected, devOs: null };
  document.querySelectorAll('.f-lv').forEach(function(c){ p.lv[c.value] = c.checked; });
  var dev = null;
  if (selected) { devices.forEach(function(d){ if (d.id === selected) dev = d; }); }
  p.devOs = dev ? osByPlatform[dev.platform] : null;
  // 过滤条件签名：条件没变时新日志可增量追加，条件变了才全量重建
  p.key = JSON.stringify([p.wantDevice, p.wantFlutter, p.kws, p.vmFilter, p.selected, p.devOs,
    Object.keys(p.lv).filter(function(k){ return p.lv[k]; }).sort()]);
  return p;
}
function logFilterOne(l, p) {
  var isFlutter = l.source && l.source.indexOf('flutter') === 0;
  // 过滤规则：未选 VM 也未选设备时不打印；选 VM 只看该会话的 Flutter 输出；
  // 选设备看该设备的日志及其上的 VM；都选则两个源并集（互不约束）。
  if (isFlutter) {
    if (!p.wantFlutter) return false;
    if (p.vmFilter) {
      // 选了 VM：仅该会话的输出（不再要求归属于选中设备）。
      if ((l.tag || '') !== p.vmFilter) return false;
    } else if (p.selected) {
      // 只选设备：仅属于该设备的 VM（来源带设备号则精确匹配，否则按平台推断）。
      var belong = (l.device && l.device === p.selected) ||
        (!l.device && p.devOs && l.os && l.os === p.devOs);
      if (!belong) return false;
    } else {
      return false;
    }
  } else {
    if (!p.wantDevice) return false;
    if (!p.lv[l.level]) return false;
    if (p.selected) {
      if ((l.device || '') !== p.selected) return false;
    } else {
      return false;
    }
  }
  // 多关键字 OR：包含任一关键字即保留
  if (p.kws.length) {
    var hay = ((l.msg || '') + ' ' + (l.tag || '') + ' ' + (l.app || '')).toLowerCase();
    var hit = false;
    for (var i = 0; i < p.kws.length; i++) { if (hay.indexOf(p.kws[i]) >= 0) { hit = true; break; } }
    if (!hit) return false;
  }
  return true;
}
function logLineHtml(l) {
  var t = l.ts || l.rcv || '';
  var src = l.source + (l.device ? '·' + l.device : '');
  return '<div class="lv-' + (l.level || 'I') + '"><span class="muted">' + esc(t) + '</span> <span class="src">[' + esc(src) + ']</span> <span class="tag">' + esc(l.app || vmApps[l.tag] || l.tag || '') + '</span> ' + esc(l.msg) + '</div>';
}
function renderLogs() {
  var view = document.getElementById('logview');
  var p = logParams();
  // 仅当原本贴底时才跟随滚动：用户往上翻/选中文字时不会被强制拉底
  var atBottom = view.scrollHeight - view.scrollTop - view.clientHeight < 40;
  var html = '';
  logs.forEach(function(l){
    if (l._seq === undefined) l._seq = ++logSeq;
    if (!logFilterOne(l, p)) return;
    html += logLineHtml(l);
  });
  view.innerHTML = html || (!vmFilter && !selected
    ? '<span class="muted">未选择 VM 或设备，不显示日志（请在页头右侧选择）</span>'
    : '<span class="muted">暂无日志</span>');
  logLastKey = p.key;
  logCursor = logs.length ? logs[logs.length - 1]._seq : 0;
  if (!paused && atBottom) view.scrollTop = view.scrollHeight;
}
function logFlushNew() {
  // 新日志到达：过滤条件未变且无截断缺口时只追加新命中行（DOM 不重建，
  // 保住选中文字/避免闪烁）；无命中行时 DOM 完全不动。条件已变或缓冲
  // 被截断（游标失效）则交由 renderLogs 全量重建。
  var view = document.getElementById('logview');
  var p = logParams();
  if (p.key !== logLastKey || (logs.length && logs[0]._seq > logCursor)) { renderLogs(); return; }
  var atBottom = view.scrollHeight - view.scrollTop - view.clientHeight < 40;
  var html = '';
  logs.forEach(function(l){
    if (l._seq <= logCursor) return;
    logCursor = l._seq;
    if (logFilterOne(l, p)) html += logLineHtml(l);
  });
  if (!html) return;
  view.insertAdjacentHTML('beforeend', html);
  if (atBottom) view.scrollTop = view.scrollHeight;
}
function togglePause(btn){ paused = !paused; btn.textContent = paused ? '继续' : '暂停'; if (!paused) renderLogs(); }
function copyLogs(btn) {
  // 复制当前框中显示的全部日志（直接读 DOM 渲染行，所见即所得）。
  // 不能从 logs 缓冲重算：5000 条全局缓冲会被其他来源（hilog/其他会话）
  // 高频挤占，选中会话的行被挤出后重算结果会少于框中显示甚至为空。
  var view = document.getElementById('logview');
  var lines = [];
  view.querySelectorAll('div[class^="lv-"]').forEach(function(d){ lines.push(d.innerText); });
  if (!lines.length) { btn.textContent = '无日志'; setTimeout(function(){ btn.textContent = '复制'; }, 1200); return; }
  var text = lines.join('\n');
  var done = function(){ btn.textContent = '已复制 ' + lines.length + ' 行'; setTimeout(function(){ btn.textContent = '复制'; }, 1500); };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done, function(){ copyLogsFallback(text); done(); });
  } else { copyLogsFallback(text); done(); }
}
function copyLogsFallback(text) { // 非安全上下文兑底：隐藏 textarea + execCommand
  var ta = document.createElement('textarea');
  ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
  document.body.appendChild(ta); ta.select();
  try { document.execCommand('copy'); } catch (e) {}
  document.body.removeChild(ta);
}
function logTop(){ var v = document.getElementById('logview'); v.scrollTop = 0; }
function logBottom(){
  // 到底后距底 <40px，增量追加的贴底跟随自动恢复（新日志持续可见）
  var v = document.getElementById('logview'); v.scrollTop = v.scrollHeight;
}
function clearLogs(){ logs = []; renderLogs(); }
function refreshDaemon(){
  fetch('/api/daemon').then(function(r){ return r.json(); }).then(function(d){
    var el = document.getElementById('daemon-status');
    var vm = document.getElementById('vmstat');
    var sel = document.getElementById('vmsel');
    if (!d.running) {
      el.innerHTML = '<span class="bad">未运行</span>（启动：dart run xb_ume:ide --install）';
      vm.style.display = ''; vm.textContent = 'VM 未连接'; vm.title = '守护进程未运行';
      sel.style.display = 'none';
    } else {
      var ss = d.sessions || [];
      var sess = ss.map(function(s){ return (s.app ? s.app + ' · ' : '') + esc(s.source) + ' → ' + esc(s.uri); }).join('<br>') || '<span class="muted">无已接入的调试会话</span>';
      el.innerHTML = '<span class="ok">运行中</span> pid=' + d.pid + '，已运行 ' + Math.floor(d.uptimeSec / 60) + ' 分 ' + (d.uptimeSec % 60) + ' 秒<br>调试会话：<br>' + sess;
      vm.style.display = 'none';
      sel.style.display = '';
      var html = '<option value="">未选择会话（共 ' + ss.length + ' 个）</option>';
      fpBySource = {};
      ss.forEach(function(s){
        var v = s.source || s.uri;
        if (s.app) vmApps[v] = s.app;
        vmUriBySource[v] = s.uri; // 沙盒 Tab 用来源找 uri
        if (s.fp) fpBySource[v] = s.fp;
        // 显示应用包名（如有），value 仍为会话来源，保证过滤匹配不变。
        var text = (s.app ? s.app + ' · ' : '') + v;
        html += '<option value="' + esc(v) + '">' + esc(text) + '</option>';
      });
      sel.innerHTML = html;
      // 保持用户选择：会话瞬断（如热重载导致 ws 抖动）不立即回退，
      // 连续 3 个周期（15s）仍缺失才回退到全部；重连后端口可能变化，
      // 按实例指纹（fp，端口无关）找回同一会话并更新到新来源。
      var prevVmFilter = vmFilter;
      var stillEntry = null;
      ss.forEach(function(s){ if ((s.source || s.uri) === vmFilter) stillEntry = s; });
      if (stillEntry && stillEntry.fp) vmFilterFp = stillEntry.fp;
      if (!vmFilter) {
        vmMiss = 0; vmFilterFp = '';
      } else if (stillEntry) {
        vmMiss = 0;
        sel.value = vmFilter;
      } else {
        var restored = vmFilterFp ? ss.find(function(s){ return s.fp === vmFilterFp; }) : null;
        if (restored) {
          vmFilter = restored.source || restored.uri;
          if (restored.fp) vmFilterFp = restored.fp;
          sel.value = vmFilter;
          vmMiss = 0;
        } else if (++vmMiss >= 3) {
          vmFilter = ''; vmFilterFp = '';
          vmMiss = 0;
        }
      }
      if (vmFilter !== prevVmFilter) {
        renderLogs(); sbRefresh(); rtRefresh(); nwRefresh(); stRefresh();
      }
      sel.title = ss.map(function(s){ return (s.source || s.uri) + ' → ' + s.uri; }).join('\n') || '无已接入的调试会话（电脑上运行 flutter run 后自动接入）';
    }
    var order = d.config && d.config.ideOrder;
    if (!order || !order.length) {
      document.getElementById('ide-order-list').innerHTML = '<li><span class="notinstalled">（读取配置失败，使用默认顺序）</span></li>';
    }
  }).catch(function(){ document.getElementById('daemon-status').textContent = '查询失败（GUI 服务异常）'; var vm = document.getElementById('vmstat'); vm.style.display = ''; vm.textContent = 'VM 未知'; document.getElementById('vmsel').style.display = 'none'; });
}
setInterval(refreshDaemon, 5000);
function setVmFilter(v){ vmFilter = v; vmFilterFp = fpBySource[v] || ''; sbPath = null; renderLogs(); sbRefresh(); rtRefresh(); nwRefresh(); stRefresh(); }

// -- 路由栈 Tab -------------------------------------------------------------
function rtActive(){ var t = document.querySelector('.tab.active'); return t && t.dataset.tab === 'routes'; }
function rtUri(){ return vmFilter ? (vmUriBySource[vmFilter] || '') : ''; }
function rtRefresh(){
  if (!rtActive()) return;
  var uri = rtUri();
  var body = document.getElementById('rt-body');
  if (!uri) {
    body.innerHTML = '<span class="muted">请先选择 VM（页头右侧会话下拉框；仅 debug 模式的调试会话可用）</span>';
    return;
  }
  body.innerHTML = '<span class="muted">加载中…</span>';
  fetch('/api/routestack?uri=' + encodeURIComponent(uri))
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { body.innerHTML = '<span class="bad">加载失败：' + esc(d.error) + '</span>'; return; }
      body.innerHTML = rtRender(d);
      // 清理不在新栈中的行：其 State 类记入已退出集合（泄漏检测候选），
      // 在 rtResolve 异步回填之前做，此时 rtInfoData 仍对应旧栈。
      var newKeys = {};
      (d.navigators || []).forEach(function(nav){
        (nav.routes || []).forEach(function(r, i){ newKeys[nav.index + '-' + i] = 1; });
      });
      for (var k in rtInfoData) {
        if (!newKeys[k]) {
          if (rtInfoData[k].state) rtSeenStates[rtInfoData[k].state] = rtInfoData[k].widget || '';
          delete rtInfoData[k];
        }
      }
      (d.navigators || []).forEach(function(nav){
        (nav.routes || []).forEach(function(r, i){ rtResolve(nav.index, i); });
      });
    })
    .catch(function(e){ body.innerHTML = '<span class="bad">加载失败：' + esc(String(e)) + '</span>'; });
}
function rtRender(d){
  var navs = d.navigators || [];
  if (!navs.length) return '<span class="muted">未找到 Navigator（应用可能尚未完成首帧构建）</span>';
  var html = '';
  navs.forEach(function(nav){
    var routes = nav.routes || [];
    html += '<div style="margin:8px 0 2px;display:flex;align-items:center;gap:8px;flex-wrap:wrap"><b>Navigator #' + (nav.index + 1) + '</b> <span class="muted">（' + routes.length + ' 个路由）</span>'
      + '<input id="rt-name-' + nav.index + '" placeholder="pushNamed 路由名，如 /" style="width:200px;margin-left:10px" onkeydown="if(event.key===\'Enter\')rtPush(' + nav.index + ')">'
      + '<button onclick="rtPush(' + nav.index + ')" title="在 app 内经 Navigator.pushNamed 压入指定名字的路由">pushNamed</button>'
      + '<span id="rt-pushmsg-' + nav.index + '" class="muted"></span></div>';
    if (!routes.length) { html += '<span class="muted">空栈</span>'; return; }
    html += '<table class="sbtable"><tr><th>栈序</th><th>路由名</th><th>Widget / State / Notifier</th><th>文件</th><th>类型</th><th>参数</th><th>定位</th><th>操作</th></tr>';
    routes.forEach(function(r, i){
      var pos = i === 0 ? '栈底' : (i === routes.length - 1 ? '栈顶' : '');
      var name = r.name ? esc(r.name) : '<span class="muted">&lt;unnamed&gt;</span>';
      var cur = r.current ? ' <span style="color:var(--acc);font-weight:600">● 当前</span>' : '';
      var fileCell = '<td id="rtf-' + nav.index + '-' + i + '"><span class="muted">…</span></td>';
      var args = r.argsType
        ? '<span title="' + esc(r.argsType + (r.args ? ' ' + r.args : '')) + '">' + esc((r.args || '').length > 60 ? r.args.substring(0, 60) + '…' : (r.args || '空')) + ' <span class="muted">(' + esc(r.argsType) + ')</span></span>'
        : '<span class="muted">—</span>';
      // Widget/State/Notifier 三列：名称由 rtResolve→rtInfo 静态解析后填充，
      // 空显示 \；点击名称跳到实例 Tab 自动查找。
      var instCell = '<td id="rti-' + nav.index + '-' + i + '" style="white-space:nowrap"><span class="muted">…</span></td>';
      var jump = '<a href="javascript:void(0)" onclick="rtJump(' + nav.index + ',' + i + ',this)" title="在 IDE 中打开该页面对应的源码文件">跳转</a>';
      // 操作列：pop 仅栈顶且非唯一路由（走转场）；remove 任意非唯一路由（直接出栈）。
      var ops = '';
      if (i === routes.length - 1 && routes.length > 1) {
        ops += '<a href="javascript:void(0)" onclick="rtOp(' + nav.index + ',' + i + ',\'pop\',this)" title="pop 该路由（仅栈顶可用，走转场动画）">pop</a>';
      }
      if (routes.length > 1) {
        ops += (ops ? ' <span class="muted">·</span> ' : '') + '<a href="javascript:void(0)" onclick="rtOp(' + nav.index + ',' + i + ',\'remove\',this)" title="直接从栈中移除该路由（无转场）">remove</a>';
      }
      html += '<tr><td>' + (i + 1) + (pos ? ' <span class="muted">' + pos + '</span>' : '') + '</td><td>' + name + cur + '</td>' + instCell + fileCell + '<td>' + esc(r.type) + '</td><td>' + args + '</td><td>' + jump + '</td><td style="white-space:nowrap">' + (ops || '<span class="muted">—</span>') + '</td></tr>';
    });
    html += '</table>';
  });
  return html;
}
// Widget/State/Notifier 名称单元格：无则显示 \\，有则可点击跳实例 Tab。
function rtInstLink(name, tip){
  if (!name) return '<span class="muted" title="未找到">\\</span>';
  return '<a href="javascript:void(0)" style="font-family:monospace" title="' + esc(tip) + '：点击跳到「实例」Tab 自动查找 ' + esc(name) + '" onclick="rtToInstances(\'' + esc(name).replace(/'/g, "\\'") + '\')">' + esc(name) + '</a>';
}
// 跳到实例 Tab 并自动查找指定类名。
function rtToInstances(name){
  if (!name) return;
  var tab = document.querySelector('.tab[data-tab="instances"]');
  if (tab) tab.click();
  document.getElementById('in-cls').value = name;
  inFind();
}
function rtResolve(nav, i){
  var uri = rtUri();
  if (!uri) return;
  fetch('/api/routelocate?uri=' + encodeURIComponent(uri) + '&nav=' + nav + '&idx=' + i + '&open=0')
    .then(function(r){ return r.json(); })
    .then(function(d){
      var cell = document.getElementById('rtf-' + nav + '-' + i);
      if (!cell) return;
      if (d.error || !d.file) { cell.innerHTML = '<span class="muted" title="' + esc(d.error || '未定位到文件') + '">—</span>'; var re = document.getElementById('rti-' + nav + '-' + i); if (re) re.innerHTML = '<span class="muted">\\</span>'; return; }
      var fileName = d.file.split('/').pop();
      var pos = fileName + (d.line ? ':' + d.line : '');
      cell.innerHTML = '<span title="' + esc(d.file + (d.className ? '（' + d.className + '）' : '')) + '">' + esc(pos) + '</span>';
      // 已定位到用户 widget 类的源文件：静态解析 State / ChangeNotifier 名。
      if (d.className && d.file) rtInfo(nav, i, d.className, d.file);
      else { var rc = document.getElementById('rti-' + nav + '-' + i); if (rc) rc.innerHTML = '<span class="muted" title="未定位到用户代码 Widget">\\</span>'; }
    })
    .catch(function(){ var cell = document.getElementById('rtf-' + nav + '-' + i); if (cell) cell.innerHTML = '<span class="muted">—</span>'; var rc = document.getElementById('rti-' + nav + '-' + i); if (rc) rc.innerHTML = '<span class="muted">\\</span>'; });
}
// 用 routelocate 已定位到的 widget 类与源文件静态解析 State / ChangeNotifier 名。
function rtInfo(nav, i, widgetCls, file){
  fetch('/api/routeinfo?class=' + encodeURIComponent(widgetCls) + '&file=' + encodeURIComponent(file))
    .then(function(r){ return r.json(); })
    .then(function(d){
      var cell = document.getElementById('rti-' + nav + '-' + i);
      if (!cell) return;
      if (!d || !d.ok) { cell.innerHTML = '<span class="muted">\\</span>'; return; }
      // Widget/State/多个 ChangeNotifier（controller2/3/4…）全部可点击。
      var parts = [rtInstLink(d.widget, 'Widget 实例（堆扫描）'), rtInstLink(d.state, 'State 实例（Element 树 + 堆扫描）')];
      (d.cn || []).forEach(function(c){ parts.push(rtInstLink(c, 'ChangeNotifier 实例（堆扫描）')); });
      cell.innerHTML = parts.join(' <span class="muted">/</span> ');
      // 记录本行解析结果：泄漏检测的类名来源（当前栈 + 历史已退出集合）。
      rtInfoData[nav + '-' + i] = { widget: d.widget || '', state: d.state || '', cn: d.cn || [] };
      if (d.state) rtSeenStates[d.state] = d.widget || '';
    })
    .catch(function(){ var c = document.getElementById('rti-' + nav + '-' + i); if (c) c.innerHTML = '<span class="muted">\\</span>'; });
}
function rtJump(nav, idx, a){
  var uri = rtUri();
  if (!uri) return;
  var td = a.parentElement;
  var orig = '<a href="javascript:void(0)" onclick="rtJump(' + nav + ',' + idx + ',this)" title="在 IDE 中打开该页面对应的源码文件">跳转</a>';
  a.textContent = '定位中…';
  fetch('/api/routelocate?uri=' + encodeURIComponent(uri) + '&nav=' + nav + '&idx=' + idx)
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { td.innerHTML = '<span class="bad" title="' + esc(d.error) + '">失败</span>'; return; }
      var fileName = (d.file || '').split('/').pop();
      var pos = fileName + (d.line ? ':' + d.line : '');
      var tip = (d.file || '') + (d.line ? ':' + d.line : '') + (d.className ? '（' + d.className + '）' : '');
      td.innerHTML = '<span style="color:var(--ok,#7ee787)" title="' + esc(tip + (d.message ? '；' + d.message : '')) + '">✓ 已打开</span>';
      // 2 秒后重置回可再次点击的「跳转」。
      setTimeout(function(){ td.innerHTML = orig; }, 2000);
    })
    .catch(function(e){ td.innerHTML = '<span class="bad">' + esc(String(e)) + '</span>'; });
}
// 路由操作结果码 → 友好提示。
function rtOpMsg(m){
  if (m === 'NO_ROOT') return 'app 尚未完成首帧';
  if (m === 'BAD_NAV' || m === 'BAD_IDX') return '路由栈已变化，请刷新后重试';
  if (m === 'NOT_TOP') return '仅栈顶路由可 pop（非栈顶请用 remove）';
  if (m === 'LAST_ROUTE') return '栈里只剩一条路由，不能移除';
  if (m === 'UNKNOWN') return '该 Navigator 无法生成此名字的路由（名字未注册或未配置 routes/onGenerateRoute）';
  if (m === 'NO_ROUTE_TABLE') return '该 Navigator 未配置 routes/onGenerateRoute，pushNamed 不可用';
  if (m.indexOf('ERR:') === 0) return 'app 内执行报错（' + m.substring(4) + '）：常见原因是路由名未注册，框架路由插件对未知名字会抛错而非返回 null';
  return m;
}
// 路由栈行尾操作：pop / remove（成功后延迟刷新，留出转场时间）。
function rtOp(nav, idx, op, a){
  var uri = rtUri();
  if (!uri) return;
  a.textContent = '…';
  fetch('/api/routeop?uri=' + encodeURIComponent(uri) + '&op=' + op + '&nav=' + nav + '&idx=' + idx, {method:'POST'})
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { a.textContent = '✗'; a.title = rtOpMsg(d.error); return; }
      var m = d.result || '';
      // 双次延迟刷新：remove/pop 的出栈在 app 端可能要等一帧才真正
      // purge（转场调度），单次 400ms 刷新实测会拉到旧栈（竞态）。
      if (m === 'OK') { setTimeout(rtRefresh, 600); setTimeout(rtRefresh, 1500); return; }
      a.textContent = '✗';
      a.title = rtOpMsg(m);
    })
    .catch(function(e){ a.textContent = '✗ ' + esc(String(e)); });
}
// 分组头部的 pushNamed：在 app 内压入指定名字的路由。
function rtPush(nav){
  var uri = rtUri();
  if (!uri) return;
  var input = document.getElementById('rt-name-' + nav);
  var msg = document.getElementById('rt-pushmsg-' + nav);
  if (!input || !msg) return;
  var name = (input.value || '').trim();
  if (!name) { msg.textContent = '请输入路由名'; return; }
  msg.textContent = 'push 中…';
  fetch('/api/routeop?uri=' + encodeURIComponent(uri) + '&op=push&nav=' + nav + '&name=' + encodeURIComponent(name), {method:'POST'})
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { msg.textContent = '失败：' + d.error; return; }
      var m = d.result || '';
      if (m === 'OK') { input.value = ''; msg.textContent = '✓ 已 push'; setTimeout(rtRefresh, 600); setTimeout(rtRefresh, 1500); return; }
      msg.textContent = '✗ ' + rtOpMsg(m);
    })
    .catch(function(e){ msg.textContent = '失败：' + String(e); });
}

// -- 泄漏检测：退出页 State → GC → 树上/堆上双计数 --------------------------
// rtInfoData：'nav-idx' -> 本行 rtInfo 解析结果（当前栈的类名来源）；
// rtSeenStates：历史见过的 State 类名 -> 页面 Widget 名（含已退出的），
// 由 rtRefresh 清理行时与 rtInfo 回调共同累积，仅内存态（刷新页面重置）。
var rtInfoData = {}, rtSeenStates = {};
function leakCheck(){
  var uri = rtUri();
  var out = document.getElementById('rt-leak');
  if (!out) return;
  if (!uri) { out.innerHTML = '<span class="muted">请先选择 VM</span>'; return; }
  // 类名集合：手动输入 + 当前栈解析结果 + 历史见过；inStack 用于区分「栈中存活」与「已退出」。
  var inStack = {}, classes = {};
  (document.getElementById('rt-leak-cls').value || '').split(',').forEach(function(s){
    s = s.trim(); if (s) classes[s] = classes[s] || '';
  });
  for (var k in rtInfoData) {
    var v = rtInfoData[k];
    if (v.state) { classes[v.state] = v.widget; inStack[v.state] = 1; }
  }
  for (var s in rtSeenStates) { if (!classes[s]) classes[s] = rtSeenStates[s]; }
  var list = Object.keys(classes);
  if (!list.length) { out.innerHTML = '<span class="muted">暂无可检测的 State 类：先浏览路由栈让 Widget/State 解析完成（会自动累积已退出页面的记录），或在输入框手动填类名</span>'; return; }
  out.innerHTML = '<span class="muted">检测中（GC + ' + list.length + ' 个类堆扫描，约数秒）…</span>';
  fetch('/api/leakcheck?uri=' + encodeURIComponent(uri) + '&classes=' + encodeURIComponent(list.join(',')), {method:'POST'})
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { out.innerHTML = '<span class="bad">检测失败：' + esc(d.error) + '</span>'; return; }
      var rows = '';
      (d.items || []).forEach(function(it){
        var concl;
        if (inStack[it.cls]) {
          concl = '<span style="color:#7ee787">✓ 栈中存活（树上 ' + it.tree + '）</span>';
        } else if (it.tree > 0) {
          concl = '<span style="color:#7ee787">✓ 树上存活（' + it.tree + '，同名类被活跃页面使用）</span>';
        } else if (it.heap > 0) {
          concl = '<span class="bad">⚠ 疑似泄漏：不在路由栈中，堆上仍有 ' + it.heap + ' 个实例</span>';
        } else {
          concl = '<span class="muted">✓ 已释放（堆上 0）</span>';
        }
        rows += '<tr><td style="font-family:monospace">' + esc(it.cls) + '</td><td>' + esc(classes[it.cls] || '') + '</td><td>' + it.tree + '</td><td>' + it.heap + '</td><td>' + concl + '</td></tr>';
      });
      out.innerHTML = '<table class="sbtable"><tr><th>State 类</th><th>页面 Widget</th><th>树上</th><th>堆上</th><th>结论</th></tr>' + rows + '</table>'
        + '<div class="muted" style="margin-top:4px">已先触发 GC 再扫描；已退出但堆上仍有实例的 State 为疑似泄漏（静态变量/监听器/动画/全局 key 等持有），可配合「实例」Tab 定位引用链。注意：页面被上层不透明页面覆盖时其元素会从树上临时卸载（State 仍由 Route 正常持有），树上计 0 属正常；对已确认退出的页面，堆上仍有实例才是泄漏。同名类可能被其它页面共用，误报时手动定点排查。</div>';
    })
    .catch(function(e){ out.innerHTML = '<span class="bad">检测失败：' + esc(String(e)) + '</span>'; });
}

// -- 状态 Tab：ChangeNotifier 类聚合 ----------------------------------------
function cnScan(){
  var uri = rtUri();
  var body = document.getElementById('cn-body');
  if (!body) return;
  if (!uri) { body.innerHTML = '<span class="muted">请先选择 VM</span>'; return; }
  body.innerHTML = '<span class="muted">扫描中（树上 CN 收集 + 逐类堆扫描，约数秒）…</span>';
  var manual = (document.getElementById('cn-cls').value || '').trim();
  fetch('/api/status/cn?uri=' + encodeURIComponent(uri) + (manual ? '&classes=' + encodeURIComponent(manual) : ''))
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { body.innerHTML = '<span class="bad">扫描失败：' + esc(d.error) + '</span>'; return; }
      var items = d.items || [];
      if (!items.length) { body.innerHTML = '<span class="muted">未发现 ChangeNotifier 实例（可在输入框手动填类名补充扫描）</span>'; return; }
      var rows = '';
      items.forEach(function(it){
        var listeners = it.listeners < 0 ? '<span class="muted">?</span>' : it.listeners;
        rows += '<tr><td>' + rtInstLink(it.cls, 'CN 实例（堆扫描首个）')
          + '</td><td class="muted">' + esc(it.src || '') + '</td><td>' + it.count + '</td><td>' + listeners
          + '</td><td style="font-size:12px" class="muted">' + esc((it.fields || []).join('  ')) + '</td></tr>';
      });
      body.innerHTML = '<table class="sbtable"><tr><th>CN 类</th><th>来源</th><th>实例数</th><th>监听者</th><th>字段摘要（首个实例）</th></tr>' + rows + '</table>';
    })
    .catch(function(e){ body.innerHTML = '<span class="bad">扫描失败：' + esc(String(e)) + '</span>'; });
}

// -- Network Tab ------------------------------------------------------------
var nwItems = [], nwDetails = {}, nwOpen = {}, nwReplays = {}, nwFetching = {}, nwEditOpen = {}, nwEditVals = {};
function nwActive(){ var t = document.querySelector('.tab.active'); return t && t.dataset.tab === 'network'; }
function nwUri(){ return vmFilter ? (vmUriBySource[vmFilter] || '') : ''; }
function nwRefresh(){
  if (!nwActive()) return;
  var uri = nwUri();
  var body = document.getElementById('nw-body');
  if (!uri) { body.innerHTML = '<span class="muted">请先选择 VM（页头右侧会话下拉框；需 app 接入 xb_ume）</span>'; return; }
  body.innerHTML = '<span class="muted">加载中…</span>';
  fetch('/api/network?uri=' + encodeURIComponent(uri))
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { body.innerHTML = '<span class="bad">加载失败：' + esc(d.error) + '</span>'; return; }
      nwItems = d.items || [];
      nwRender();
    })
    .catch(function(e){ body.innerHTML = '<span class="bad">加载失败：' + esc(String(e)) + '</span>';
  });
}
function nwStatusColor(s, code){
  if (s === 'failure' || s === 'cancelled') return 'var(--bad,#f85149)';
  if (s === 'pending') return 'var(--muted,#8b949e)';
  if (code >= 200 && code < 400) return 'var(--ok,#7ee787)';
  return 'var(--bad,#f85149)';
}
function nwRender(){
  var body = document.getElementById('nw-body');
  var kw = (document.getElementById('nw-kw').value || '').toLowerCase();
  var rows = nwItems.filter(function(it){
    if (!kw) return true;
    return ((it.method || '') + ' ' + (it.url || '') + ' ' + (it.statusCode || '') + ' ' + (it.error || '')).toLowerCase().indexOf(kw) >= 0;
  });
  if (!rows.length) { body.innerHTML = '<span class="muted">' + (nwItems.length ? '无匹配请求' : '暂无请求（触发一次网络请求后点刷新）') + '</span>'; return; }
  var html = '<div class="muted" style="margin:2px 0">共 ' + rows.length + ' 条</div>';
  html += '<table class="sbtable"><tr><th>时间</th><th>方法</th><th>URL</th><th>状态</th><th>耗时</th><th>操作</th></tr>';
  rows.forEach(function(it, i){
    var code = parseInt(it.statusCode, 10);
    var codeHtml = isNaN(code) ? '<span class="muted">…</span>' : '<span style="color:' + nwStatusColor(it.status, code) + '">' + code + '</span>';
    var t = (it.time || '').replace('T', ' ').substring(5);
    var url = it.url || '';
    var short = url.length > 80 ? url.substring(0, 80) + '…' : url;
    var open = !!nwOpen[it.id];
    html += '<tr style="cursor:pointer;' + (open ? 'background:var(--bg2,#161b22)' : '') + '" onclick="nwToggle(\'' + esc(it.id) + '\')">'
      + '<td>' + esc(t) + '</td><td>' + esc(it.method) + '</td>'
      + '<td title="' + esc(url) + '">' + esc(short) + '</td>'
      + '<td>' + codeHtml + '</td><td>' + (it.durationMs ? it.durationMs + 'ms' : '') + '</td>'
      + '<td onclick="event.stopPropagation()">'
      + '<a href="javascript:void(0)" onclick="nwCurl(\'' + esc(it.id) + '\',this)">cURL</a> '
      + '<a href="javascript:void(0)" onclick="nwReplay(\'' + esc(it.id) + '\',this)">重发</a></td></tr>';
    // 展开行：详情内嵌在该行下方，多条互不影响。
    if (open) html += '<tr><td colspan="6" id="nwd-' + esc(it.id) + '" style="padding:8px 12px;background:var(--bg2,#161b22)">' + nwDetailRowHtml(it.id) + '</td></tr>';
  });
  html += '</table>';
  body.innerHTML = html;
}
function nwDetailHtml(id, d){
  function kvTable(rows){
    if (!rows || !rows.length) return '<span class="muted">—</span>';
    return '<table class="sbtable">' + rows.map(function(r){ return '<tr><td style="white-space:nowrap">' + esc(r.k) + '</td><td style="word-break:break-all">' + esc(r.v) + '</td></tr>'; }).join('') + '</table>';
  }
  function pretty(s){
    if (!s) return '<span class="muted">—</span>';
    try { var o = JSON.parse(s); return '<pre style="white-space:pre-wrap;word-break:break-all;margin:0">' + esc(JSON.stringify(o, null, 2)) + '</pre>'; }
    catch (_) { return '<pre style="white-space:pre-wrap;word-break:break-all;margin:0">' + esc(s) + '</pre>';
    }
  }
  var sec = function(title, inner){ return '<div style="margin:8px 0 2px"><b>' + title + '</b></div>' + inner; };
  var html = '<div class="card">';
  html += sec('Query', kvTable(d.query));
  html += sec('请求头', kvTable(d.requestHeaders));
  html += sec('请求体', pretty(d.requestBody));
  html += sec('响应头', kvTable(d.responseHeaders));
  html += sec('响应体', pretty(d.responseBody));
  if (d.stack) html += sec('错误堆栈', pretty(d.stack));
  return html + '</div>';
}
function nwDetailRowHtml(id){
  var it = nwItems.filter(function(x){ return x.id === id; })[0] || {};
  var d = nwDetails[id];
  var head = '<div style="margin:2px 0 6px"><b>' + esc(it.method + ' ' + (it.url || '')) + '</b> '
    + '<a href="javascript:void(0)" onclick="nwCurl(\'' + esc(id) + '\',this)">复制 cURL</a> '
    + '<a href="javascript:void(0)" onclick="nwReplay(\'' + esc(id) + '\',this)">重发</a> '
    + '<a href="javascript:void(0)" onclick="nwEditReplay(\'' + esc(id) + '\',this)" title="可改 URL/请求头/请求体后重放，结果自动与原响应逐字段 diff">编辑重放</a></div>';
  if (d && d.error) return head + '<span class="bad">' + esc(d.error) + '</span>';
  if (!d) { nwFetchDetail(id); return head + '<span class="muted">加载详情…</span>'; }
  var rep = nwReplays[id];
  var repHtml = '';
  if (rep) {
    if (rep.error) {
      repHtml = '<div style="margin:8px 0 2px"><b>重发响应</b></div><span class="bad">重发失败：' + esc(rep.error) + '</span>';
    } else {
      var bodyHtml;
      try { bodyHtml = '<pre style="white-space:pre-wrap;word-break:break-all;margin:0">' + esc(JSON.stringify(JSON.parse(rep.body), null, 2)) + '</pre>'; }
      catch (_) { bodyHtml = '<pre style="white-space:pre-wrap;word-break:break-all;margin:0">' + esc(rep.body || '') + '</pre>'; }
      repHtml = '<div style="margin:8px 0 2px"><b>重发响应</b>（电脑直发，不经手机）</div>'
        + '<div class="card"><div><b>状态码：</b><span style="color:' + nwStatusColor('success', rep.statusCode) + '">' + rep.statusCode + '</span></div>'
        + '<div style="margin:6px 0 2px"><b>响应头</b></div><table class="sbtable">'
        + Object.keys(rep.headers || {}).map(function(k){ return '<tr><td>' + esc(k) + '</td><td>' + esc((rep.headers[k] || []).join(', ')) + '</td></tr>'; }).join('')
        + '</table><div style="margin:6px 0 2px"><b>响应体</b></div>' + bodyHtml
        + '<div style="margin:8px 0 2px"><b>与原响应 diff</b></div>' + nwDiffHtml(d.responseBody || '', rep.body || '') + '</div>';
    }
  }
  var editHtml = nwEditOpen[id] ? nwEditFormHtml(id) : '';
  return head + editHtml + nwDetailHtml(id, d) + repHtml;
}
function nwEditFormHtml(id){
  var it = nwItems.filter(function(x){ return x.id === id; })[0] || {};
  var d = nwDetails[id] || {};
  // 重放后重渲染会重建表单，编辑过的内容从缓存恢复，避免丢失。
  var ev = nwEditVals[id] || {};
  var urlVal = ev.url !== undefined ? ev.url : (it.url || '');
  var hdrVal = ev.hdr !== undefined ? ev.hdr : (d.requestHeaders || []).filter(function(h){ return h.k; }).map(function(h){ return h.k + ': ' + (h.v || ''); }).join('\n');
  var bodyVal = ev.body !== undefined ? ev.body : (d.requestBody || '');
  return '<div class="card" style="margin:6px 0">'
    + '<div style="margin:4px 0"><b>编辑后重放</b><span class="muted">（电脑直发，不经 app；method 固定为 ' + esc(it.method || 'GET') + '）</span></div>'
    + '<div style="margin:4px 0">URL：<input id="nwe-url-' + esc(id) + '" style="width:78%;font-family:monospace" value="' + esc(urlVal) + '"></div>'
    + '<div style="margin:4px 0">请求头（每行 k: v）：<br><textarea id="nwe-hdr-' + esc(id) + '" rows="4" style="width:95%;font-family:monospace">' + esc(hdrVal) + '</textarea></div>'
    + '<div style="margin:4px 0">请求体：<br><textarea id="nwe-body-' + esc(id) + '" rows="8" style="width:95%;font-family:monospace">' + esc(bodyVal) + '</textarea></div>'
    + '<button class="primary" onclick="nwDoReplay(\'' + esc(id) + '\',this)">执行重放</button> '
    + '<a href="javascript:void(0)" onclick="nwEditReplay(\'' + esc(id) + '\',this)">收起</a>'
    + '</div>';
}
// JSON 逐字段递归 diff：返回 [{path, type: chg|add|del, oldV, newV}]。
function nwDiffRows(a, b){
  var rows = [];
  function isObj(x){ return x !== null && typeof x === 'object'; }
  function short(x){ return JSON.stringify(x); }
  function walk(p, x, y){
    if (isObj(x) && isObj(y) && Array.isArray(x) === Array.isArray(y)) {
      var i, k, keys = {};
      if (Array.isArray(x)) {
        var n = Math.max(x.length, y.length);
        for (i = 0; i < n; i++) {
          var ip = p + '[' + i + ']';
          if (i >= x.length) rows.push({ path: ip, type: 'add', newV: short(y[i]) });
          else if (i >= y.length) rows.push({ path: ip, type: 'del', oldV: short(x[i]) });
          else walk(ip, x[i], y[i]);
        }
      } else {
        for (k in x) keys[k] = 1;
        for (k in y) keys[k] = 1;
        Object.keys(keys).sort().forEach(function(k){
          var kp = p ? p + '.' + k : k;
          if (!(k in x)) rows.push({ path: kp, type: 'add', newV: short(y[k]) });
          else if (!(k in y)) rows.push({ path: kp, type: 'del', oldV: short(x[k]) });
          else walk(kp, x[k], y[k]);
        });
      }
    } else {
      var xs = short(x), ys = short(y);
      if (xs !== ys) rows.push({ path: p || '$', type: 'chg', oldV: xs, newV: ys });
    }
  }
  walk('', a, b);
  return rows;
}
function nwDiffHtml(oldBody, newBody){
  var a, b, rows;
  try { a = JSON.parse(oldBody); b = JSON.parse(newBody); } catch (_) {
    return '<span class="muted">原/新响应非 JSON，无法逐字段 diff（可人工比对上方两段响应体）</span>';
  }
  rows = nwDiffRows(a, b);
  if (!rows.length) return '<span style="color:#7ee787">✓ 与原响应完全一致</span>';
  var cnt = { chg: 0, add: 0, del: 0 };
  rows.forEach(function(r){ cnt[r.type]++; });
  var trs = rows.map(function(r){
    var mark = r.type === 'add' ? '<span style="color:#7ee787">+ 增</span>' : (r.type === 'del' ? '<span style="color:#f85149">− 删</span>' : '<span style="color:#d29922">● 改</span>');
    return '<tr><td style="font-family:monospace">' + esc(r.path) + '</td><td>' + mark + '</td>'
      + '<td style="word-break:break-all">' + (r.oldV !== undefined ? '<span style="text-decoration:line-through" class="muted">' + esc(r.oldV) + '</span>' : '<span class="muted">—</span>') + '</td>'
      + '<td style="word-break:break-all">' + (r.newV !== undefined ? esc(r.newV) : '<span class="muted">—</span>') + '</td></tr>';
  }).join('');
  return '<div class="muted" style="margin:2px 0">差异 ' + rows.length + ' 处（改 ' + cnt.chg + ' / 增 ' + cnt.add + ' / 删 ' + cnt.del + '）</div>'
    + '<table class="sbtable"><tr><th>字段路径</th><th>类型</th><th>原值</th><th>新值</th></tr>' + trs + '</table>';
}
function nwToggle(id){
  nwOpen[id] = !nwOpen[id];
  nwRender();
}
function nwFetchDetail(id){
  if (nwDetails[id] || nwFetching[id]) return;
  var uri = nwUri(); if (!uri) return;
  nwFetching[id] = true;
  var done = function(d){
    nwDetails[id] = d; delete nwFetching[id];
    var cell = document.getElementById('nwd-' + id);
    if (cell && nwOpen[id]) cell.innerHTML = nwDetailRowHtml(id);
  };
  fetch('/api/network/detail?uri=' + encodeURIComponent(uri) + '&id=' + encodeURIComponent(id))
    .then(function(r){ return r.json(); }).then(done)
    .catch(function(e){ done({ error: String(e) }); });
}
function nwGetDetail(id, cb){
  if (nwDetails[id]) { cb(nwDetails[id]); return; }
  var uri = nwUri(); if (!uri) return;
  fetch('/api/network/detail?uri=' + encodeURIComponent(uri) + '&id=' + encodeURIComponent(id))
    .then(function(r){ return r.json(); })
    .then(function(d){ if (d.error) { alert(d.error); return; } nwDetails[id] = d; cb(d); })
    .catch(function(e){ alert(String(e)); });
}
function nwCurl(id, a){
  var it = nwItems.filter(function(x){ return x.id === id; })[0];
  if (!it) return;
  nwGetDetail(id, function(d){
    var parts = ["curl -X " + (it.method || 'GET') + " '" + (it.url || '').replace(/'/g, "'\\''") + "'"];
    (d.requestHeaders || []).forEach(function(h){
      if (!h.k) return;
      parts.push("-H '" + h.k + ": " + (h.v || '').replace(/'/g, "'\\''") + "'");
    });
    if (d.requestBody) parts.push("--data '" + String(d.requestBody).replace(/'/g, "'\\''") + "'");
    var cmd = parts.join(' \\\n  ');
    if (navigator.clipboard) navigator.clipboard.writeText(cmd);
    var old = a.textContent; a.textContent = '已复制'; setTimeout(function(){ a.textContent = old; }, 1500);
  });
}
function nwReplay(id, a){
  var uri = nwUri(); if (!uri) return;
  var old = a.textContent; a.textContent = '发送中…';
  fetch('/api/network/replay?uri=' + encodeURIComponent(uri) + '&id=' + encodeURIComponent(id))
    .then(function(r){ return r.json(); })
    .then(function(d){
      a.textContent = old;
      nwReplays[id] = d.error ? { error: d.error } : d;
      var cell = document.getElementById('nwd-' + id);
      if (cell) { cell.innerHTML = nwDetailRowHtml(id); return; }
      nwOpen[id] = true;
      nwRender();
    })
    .catch(function(e){ a.textContent = old; alert(String(e)); });
}
function nwEditReplay(id, a){
  nwEditOpen[id] = !nwEditOpen[id];
  var cell = document.getElementById('nwd-' + id);
  if (cell && nwOpen[id]) { cell.innerHTML = nwDetailRowHtml(id); return; }
  nwOpen[id] = true;
  nwRender();
}
function nwDoReplay(id, a){
  var uri = nwUri(); if (!uri) return;
  var old = a.textContent; a.textContent = '重放中…';
  var headers = {};
  var hdrText = document.getElementById('nwe-hdr-' + id).value || '';
  hdrText.split('\n').forEach(function(line){
    var i = line.indexOf(':');
    if (i > 0) {
      var k = line.substring(0, i).trim();
      if (k) headers[k] = line.substring(i + 1).trim();
    }
  });
  // 缓存编辑内容：重放后重渲染时回填。
  nwEditVals[id] = {
    url: document.getElementById('nwe-url-' + id).value.trim(),
    hdr: hdrText,
    body: document.getElementById('nwe-body-' + id).value
  };
  fetch('/api/network/replay?uri=' + encodeURIComponent(uri) + '&id=' + encodeURIComponent(id), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      url: nwEditVals[id].url,
      headers: headers,
      body: nwEditVals[id].body
    })
  })
    .then(function(r){ return r.json(); })
    .then(function(d){
      a.textContent = old;
      nwReplays[id] = d.error ? { error: d.error } : d;
      var cell = document.getElementById('nwd-' + id);
      if (cell) cell.innerHTML = nwDetailRowHtml(id);
    })
    .catch(function(e){ a.textContent = old; alert(String(e)); });
}
function nwClear(){
  var uri = nwUri(); if (!uri) return;
  if (!confirm('清空 app 内 ume 的 Network 记录？')) return;
  fetch('/api/network/clear?uri=' + encodeURIComponent(uri))
    .then(function(r){ return r.json(); })
    .then(function(d){ if (d.error) { alert(d.error); return; } nwItems = []; nwDetails = {}; nwOpen = {}; nwReplays = {}; nwRender(); })
    .catch(function(e){ alert(String(e)); });
}

// -- Storage Tab（shared_prefs XML 直读直写）--------------------------------
var stFiles = [], stXml = '', stRows = [], stFile = '', stFmt = 'android';
function stActive(){ var t = document.querySelector('.tab.active'); return t && t.dataset.tab === 'storage'; }
function stUri(){ return vmFilter ? (vmUriBySource[vmFilter] || '') : ''; }
function escXml(s){
  return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}
function stRefresh(){
  if (!stActive()) return;
  var uri = stUri();
  var body = document.getElementById('st-body');
  if (!uri) { body.innerHTML = '<span class="muted">请先选择 VM（页头右侧会话下拉框；Android / 鸿蒙 / iOS debug 会话可用）</span>'; return; }
  body.innerHTML = '<span class="muted">加载中…</span>';
  fetch('/api/storage/list?uri=' + encodeURIComponent(uri))
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { body.innerHTML = '<span class="bad">加载失败：' + esc(d.error) + '</span>'; return; }
      stFiles = d.files || [];
      var sel = document.getElementById('st-file');
      sel.innerHTML = stFiles.length
        ? stFiles.map(function(f){ return '<option value="' + esc(f) + '">' + esc(f.split('/').pop()) + '</option>'; }).join('')
        : '<option value="">（无 shared_prefs 文件）</option>';
      if (!stFiles.length) { body.innerHTML = '<span class="muted">app 尚未写入过 shared_prefs（先在 app 里产生一次 preferences 写入）</span>'; return; }
      stLoad();
    })
    .catch(function(e){ body.innerHTML = '<span class="bad">加载失败：' + esc(String(e)) + '</span>'; });
}
function stLoad(){
  var uri = stUri(); if (!uri) return;
  stFile = document.getElementById('st-file').value || stFiles[0] || '';
  if (!stFile) return;
  var body = document.getElementById('st-body');
  body.innerHTML = '<span class="muted">读取中…</span>';
  fetch('/api/storage/read?uri=' + encodeURIComponent(uri) + '&file=' + encodeURIComponent(stFile))
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { body.innerHTML = '<span class="bad">读取失败：' + esc(d.error) + '</span>'; return; }
      stXml = d.xml || '';
      stParse();
      stRender();
    })
    .catch(function(e){ body.innerHTML = '<span class="bad">读取失败：' + esc(String(e)) + '</span>'; });
}
function stParse(){
  stRows = [];
  stFmt = 'android';
  var doc = new DOMParser().parseFromString(stXml, 'text/xml');
  if (doc.querySelector('parsererror')) { stRows = [{ name: '', type: 'raw', value: stXml }]; return; }
  var map = doc.documentElement;
  if (!map) return;
  // Android：根 <map>，name 属性；鸿蒙：根 <preferences>，key 属性；iOS：根 <plist>。
  stFmt = map.tagName === 'preferences' ? 'ohos' : (map.tagName === 'plist' ? 'ios' : 'android');
  if (stFmt === 'ios') {
    var dict = map.getElementsByTagName('dict')[0];
    var kids = dict ? dict.children : [];
    for (var j = 0; j + 1 < kids.length; j += 2) {
      if (kids[j].tagName !== 'key') break;
      var vEl = kids[j + 1], tag = vEl.tagName;
      var row = { name: kids[j].textContent, type: tag, value: '' };
      if (tag === 'true' || tag === 'false') { row.type = 'boolean'; row.value = tag; }
      else if (tag === 'array') row.value = Array.prototype.map.call(vEl.getElementsByTagName('string'), function(s){ return s.textContent; }).join(', ');
      else if (tag === 'string' || tag === 'integer' || tag === 'real') row.value = vEl.textContent;
      else { row.type = 'rawios'; row.raw = new XMLSerializer().serializeToString(vEl); }
      stRows.push(row);
    }
    return;
  }
  var attr = stFmt === 'ohos' ? 'key' : 'name';
  Array.prototype.forEach.call(map.children, function(el){
    var tag = el.tagName;
    var type = (stFmt === 'ohos' && tag === 'bool') ? 'boolean' : tag;
    var name = el.getAttribute(attr) || '';
    var value;
    if (tag === 'string') value = el.textContent;
    else if (tag === 'set' || tag === 'array') value = Array.prototype.map.call(el.getElementsByTagName('string'), function(s){ return s.textContent; }).join(', ');
    else value = el.getAttribute('value') || '';
    stRows.push({ name: name, type: type, value: value });
  });
}
function stHl(s, kw){
  // Storage 过滤命中高亮（单关键字，不区分大小写，包含匹配）。
  s = String(s);
  if (!kw) return esc(s);
  var l = s.toLowerCase(), out = '', i = 0;
  while (true) {
    var idx = l.indexOf(kw, i);
    if (idx < 0) { out += esc(s.substring(i)); break; }
    out += esc(s.substring(i, idx)) + '<mark>' + esc(s.substring(idx, idx + kw.length)) + '</mark>';
    i = idx + kw.length;
  }
  return out;
}
function stRender(){
  var body = document.getElementById('st-body');
  var kw = (document.getElementById('st-kw').value || '').toLowerCase();
  var rows = stRows.map(function(r, i){ return { r: r, i: i }; }).filter(function(x){
    return !kw || ((x.r.name || '') + ' ' + (x.r.value || '')).toLowerCase().indexOf(kw) >= 0;
  });
  var head = '<div class="muted sthead" style="margin:0">' + esc(stFile.split('/').pop()) + ' · ' + stRows.length + ' 项（'
    + (stFmt === 'ohos' ? '鸿蒙 preferences 格式' : stFmt === 'ios' ? 'iOS plist 格式' : 'Android shared_prefs 格式') + ' · 修改后点「保存写入」）</div>';
  if (stRows.length === 1 && stRows[0].type === 'raw') { body.innerHTML = head + '<pre style="white-space:pre-wrap;word-break:break-all">' + esc(stXml) + '</pre>'; return; }
  var html = '<table class="sbtable sttable"><tr><th>key</th><th>类型</th><th>值（可直接编辑）</th><th>操作</th></tr>';
  rows.forEach(function(x){
    var r = x.r, i = x.i;
    // key 不可修改（仅「新增」行可填写），过滤时高亮匹配片段。
    var keyCell = r.isNew
      ? '<input value="' + esc(r.name) + '" oninput="stSet(' + i + ',\'name\',this.value)" placeholder="填写 key" style="width:100%">'
      : '<span style="word-break:break-all">' + (kw ? stHl(r.name, kw) : esc(r.name)) + '</span>';
    var valHtml;
    if (r.type === 'rawios') {
      valHtml = '<span class="muted" title="iOS plist 复杂类型，保留原样">（不支持编辑）</span>';
    } else if (r.type === 'boolean') {
      valHtml = '<select onchange="stSet(' + i + ',\'value\',this.value)"><option value="true"' + (r.value === 'true' ? ' selected' : '') + '>true</option><option value="false"' + (r.value !== 'true' ? ' selected' : '') + '>false</option></select>';
    } else {
      var tip = r.type === 'set' ? 'set 类型，逗号分隔各成员' : '';
      valHtml = kw
        ? '<span title="' + tip + (tip ? '；' : '') + '清除过滤后可编辑" style="word-break:break-all">' + stHl(r.value, kw) + '</span>'
        : '<input value="' + esc(r.value).replace(/"/g, '&quot;') + '" oninput="stSet(' + i + ',\'value\',this.value)" title="' + tip + '" style="width:100%">';
    }
    html += '<tr><td>' + keyCell + '</td>'
      + '<td><select onchange="stSet(' + i + ',\'type\',this.value)"' + (r.type === 'rawios' || !r.isNew ? ' disabled title="类型由文件解析决定，不可修改"' : '') + '>'
      + (stFmt === 'ohos' ? ['string','boolean','int','long','float','double'] : stFmt === 'ios' ? ['string','integer','real','boolean','array'] : ['string','boolean','int','long','float','set']).map(function(t){
          return '<option' + (t === r.type ? ' selected' : '') + '>' + t + '</option>'; }).join('') + '</select></td>'
      + '<td>' + valHtml + '</td>'
      + '<td><a href="javascript:void(0)" onclick="stDel(' + i + ')" class="bad">删除</a></td></tr>';
  });
  html += '</table>';
  html += '<div style="margin-top:8px"><button onclick="stSave()">保存写入（写回手机）</button></div>';
  body.innerHTML = head + html;
  // 表头/信息行的 sticky top 依赖工具栏实际高度，渲染后实测写入，避免写死对不齐。
  requestAnimationFrame(function(){
    var tb = document.getElementById('st-toolbar');
    var hd = body.querySelector('.sthead');
    var ths = body.querySelectorAll('.sttable th');
    if (!tb || !ths.length) return;
    var hTop = tb.offsetHeight, tTop = hTop + (hd ? hd.offsetHeight : 0);
    if (hd) hd.style.top = hTop + 'px';
    for (var k = 0; k < ths.length; k++) ths[k].style.top = tTop + 'px';
  });
}
function stSet(i, k, v){ if (stRows[i]) stRows[i][k] = v; }
function stDel(i){ stRows.splice(i, 1); stRender(); }
function stAddRow(){ stRows.push({ name: '', type: 'string', value: '', isNew: true }); stRender(); }
function stSave(){
  var uri = stUri(); if (!uri || !stFile) return;
  var rows = stRows.filter(function(r){ return r.type !== 'raw' && (r.name || '').trim(); });
  var xml;
  if (stFmt === 'ios') {
    var items = rows.map(function(r){
      var k = '<key>' + escXml(r.name.trim()) + '</key>';
      if (r.type === 'rawios') return k + r.raw;
      if (r.type === 'boolean') return k + (r.value === 'true' ? '<true/>' : '<false/>');
      if (r.type === 'integer' || r.type === 'real') return k + '<' + r.type + '>' + escXml(r.value) + '</' + r.type + '>';
      if (r.type === 'array') {
        var ms = String(r.value || '').split(',').map(function(s){ return s.trim(); }).filter(Boolean);
        return k + '<array>' + ms.map(function(m){ return '<string>' + escXml(m) + '</string>'; }).join('') + '</array>';
      }
      return k + '<string>' + escXml(r.value) + '</string>';
    });
    xml = '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n'
      + items.join('\n') + '\n</dict>\n</plist>';
  } else {
    var ohos = stFmt === 'ohos';
    var attr = ohos ? 'key' : 'name';
    var lines = rows.map(function(r){
      var n = escXml(r.name.trim());
      if (r.type === 'string') return '<string ' + attr + '="' + n + '">' + escXml(r.value) + '</string>';
      if (r.type === 'set' || r.type === 'array') {
        var members = String(r.value || '').split(',').map(function(s){ return s.trim(); }).filter(Boolean);
        var inner = members.map(function(m){ return '<string>' + escXml(m) + '</string>'; }).join('');
        return '<' + (ohos ? 'array' : 'set') + ' ' + attr + '="' + n + '">' + inner + '</' + (ohos ? 'array' : 'set') + '>';
      }
      if (r.type === 'boolean') return '<' + (ohos ? 'bool' : 'boolean') + ' ' + attr + '="' + n + '" value="' + (r.value === 'true' ? 'true' : 'false') + '" />';
      return '<' + r.type + ' ' + attr + '="' + n + '" value="' + escXml(r.value) + '" />';
    });
    xml = ohos
      ? '<?xml version="1.0" encoding="UTF-8"?>\n<preferences version="1.0">' + lines.join('') + '</preferences>'
      : "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n" + lines.join('\n') + '\n</map>';
  }
  fetch('/api/storage/write?uri=' + encodeURIComponent(uri) + '&file=' + encodeURIComponent(stFile), {
    method: 'POST', body: xml
  })
    .then(function(r){ return r.json(); })
    .then(function(d){
      var btn = document.getElementById('st-body').querySelector('button');
      if (d.error) { alert('写入失败：' + d.error); return; }
      if (btn) { btn.textContent = '✓ 已写入（重启 app 生效）'; setTimeout(function(){ btn.textContent = '保存写入（写回手机）'; }, 2000); }
    })
    .catch(function(e){ alert(String(e)); });
}

// -- 应用沙盒 Tab -----------------------------------------------------------
var sbPath = null, sbOs = '', sbHome = '', sbRoot = '', sbRoots = [];
function sbEntryLinks(){
  if (!sbRoots || sbRoots.length < 2) return '';
  var links = sbRoots.map(function(r){
    var name = r.split('/').filter(Boolean).pop() || r;
    return '<a href="javascript:void(0)" data-p="' + encodeURIComponent(r) + '" onclick="sbGoBtn(this)">' + esc(name) + '</a>';
  });
  return '<div class="muted" style="margin:4px 0">入口：' + links.join(' · ') + '</div>';
}
function sbError(msg, raw){
  var body = document.getElementById('sb-body');
  var html = '<span class="bad">' + esc(msg) + '</span>';
  if (raw) html += '<div class="muted" style="margin-top:4px;word-break:break-all">' + esc(raw) + '</div>';
  if (sbOs === 'android' && /Permission denied|errno = 13|Operation not permitted/.test(raw || msg)) {
    html += '<div class="muted" style="margin-top:4px">提示：Android 分区存储限制，应用无法列出其他应用的目录（含 /storage/emulated/0/Android/data 顶层）；本应用沙盒已预填为默认入口。</div>';
  }
  if (sbRoots && sbRoots.length) {
    var links = sbRoots.map(function(r){
      var name = r.split('/').filter(Boolean).pop() || r;
      return '<a href="javascript:void(0)" data-p="' + encodeURIComponent(r) + '" onclick="sbGoBtn(this)">' + esc(name) + '</a>';
    });
    html += '<div style="margin-top:6px">可尝试其他入口：' + links.join(' · ') + '</div>';
  }
  body.innerHTML = html;
}
function sbActive(){ var t = document.querySelector('.tab.active'); return t && t.dataset.tab === 'sandbox'; }
function sbUri(){ return vmFilter ? (vmUriBySource[vmFilter] || '') : ''; }
function sbOpenSub(mode, btn){
  window.open('/' + mode + '?uri=' + encodeURIComponent(sbUri()) + '&path=' + encodeURIComponent(decodeURIComponent(btn.dataset.p)));
}
var sbUpTarget = '';
function sbUpload(btn){
  var p = decodeURIComponent(btn.dataset.p);
  sbUpTarget = btn.dataset.dir === '1' ? p : p.replace(/[/\\][^/\\]*$/, '') || '/';
  var inp = document.getElementById('sb-up-file');
  inp.value = '';
  inp.click();
}
function sbUploadPick(inp){
  var f = inp.files && inp.files[0];
  if (!f) return;
  var tip = document.getElementById('sb-up-tip');
  tip.style.display = '';
  tip.textContent = '上传中：' + f.name + '（' + fmtSize(f.size) + '）→ ' + sbUpTarget;
  var rd = new FileReader();
  rd.onload = function(){
    var b64 = String(rd.result).split(',')[1] || '';
    if (b64.length > (16 << 20)) {
      tip.textContent = '上传失败：文件过大（上限 12MB）';
      return;
    }
    fetch('/api/sandbox/upload?uri=' + encodeURIComponent(sbUri()) + '&path=' + encodeURIComponent(sbUpTarget), {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({name: f.name, b64: b64})
    }).then(function(r){ return r.json(); })
      .then(function(d){
        if (d.ok) {
          tip.textContent = '已上传：' + d.path + '（' + fmtSize(d.size) + '）';
          setTimeout(function(){ tip.style.display = 'none'; }, 4000);
          sbRefresh();
        } else { tip.textContent = '上传失败：' + (d.error || d); }
      })
      .catch(function(e){ tip.textContent = '上传失败：' + e; });
  };
  rd.onerror = function(){ tip.textContent = '读取本地文件失败'; };
  rd.readAsDataURL(f);
}
function sbDelete(btn){
  var p = decodeURIComponent(btn.dataset.p);
  var name = btn.dataset.name;
  var isDir = btn.dataset.dir === '1';
  var kind = isDir ? '文件夹（含全部内容，递归删除）' : '文件';
  if (!confirm('确认删除' + kind + '「' + name + '」？\n\n' + p + '\n\n此操作不可恢复！')) return;
  fetch('/api/sandbox/delete?uri=' + encodeURIComponent(sbUri()) + '&path=' + encodeURIComponent(p), {method: 'POST'})
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.ok) { sbRefresh(); }
      else { alert('删除失败：' + (d.error || d.result || d)); }
    })
    .catch(function(e){ alert('删除失败：' + e); });
}
function sbRefresh(){
  if (!sbActive()) return;
  var uri = sbUri();
  var body = document.getElementById('sb-body');
  if (!uri) {
    body.innerHTML = '<span class="muted">请先选择 VM（页头右侧会话下拉框；仅 debug 模式的调试会话可用）</span>';
    return;
  }
  sbLoad(sbPath == null ? '' : sbPath);
}
function sbLoad(p){
  var uri = sbUri();
  if (!uri) return;
  var body = document.getElementById('sb-body');
  body.innerHTML = '<span class="muted">加载中…</span>';
  fetch('/api/sandbox/list?uri=' + encodeURIComponent(uri) + '&path=' + encodeURIComponent(p))
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) {
        var perm = /Operation not permitted|errno = 1|Permission denied/.test(d.error);
        sbError(perm ? '无权限访问该目录（app 进程访问受限）' : '加载失败', d.error);
        return;
      }
      sbHome = d.home || sbHome; sbOs = d.os || sbOs;
      if (p === '') {
        sbRoots = d.roots || [];
        if (!sbRoots.length) {
          sbError('无法定位可访问的目录：app 进程的文件系统访问受限（HOME=' + sbHome + '）');
          return;
        }
        sbRoot = d.root || sbRoots[0]; sbPath = sbRoot;
        body.innerHTML = sbEntryLinks() + sbRender(d);
        return;
      }
      sbRoot = sbRoot || d.root || sbHome;
      sbPath = p;
      body.innerHTML = sbEntryLinks() + sbRender(d);
    })
    .catch(function(e){ sbError('加载失败', String(e)); });
}
function sbGoBtn(el){ sbLoad(decodeURIComponent(el.dataset.p)); }
function fmtSize(n){
  if (n == null || n < 0) return '—';
  if (n < 1024) return n + ' B';
  var u = ['KB', 'MB', 'GB', 'TB']; var i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
  return n.toFixed(1) + ' ' + u[i];
}
function sbRender(d){
  var sep = sbOs === 'windows' ? '\\' : '/';
  var root = sbRoot || sbHome || sbPath;
  var rootName = (root.split(sep).filter(Boolean).pop()) || '根目录';
  var rel = (root && sbPath.indexOf(root) === 0) ? sbPath.substring(root.length) : sbPath;
  var segs = rel.split(sep).filter(Boolean);
  var crumb = '<a href="javascript:void(0)" onclick="sbGoBtn(this)" data-p="' + encodeURIComponent(root) + '">' + esc(rootName) + '</a>';
  var acc = root;
  segs.forEach(function(s){
    acc = acc.endsWith(sep) ? acc + s : acc + sep + s;
    crumb += ' / <a href="javascript:void(0)" onclick="sbGoBtn(this)" data-p="' + encodeURIComponent(acc) + '">' + esc(s) + '</a>';
  });
  var html = '<div class="sbcrumb">' + crumb
    + ' <a href="javascript:void(0)" onclick="sbRefresh()" style="margin-left:10px" title="重新读取当前目录">↻ 刷新</a></div>';
  if (!d.entries || !d.entries.length) { html += '<span class="muted">空目录</span>'; return html; }
  html += '<table class="sbtable"><tr><th>名称</th><th>大小</th><th>修改时间</th><th></th></tr>';
  d.entries.forEach(function(e){
    var q = encodeURIComponent(sbUri()), p = encodeURIComponent(e.path);
    var act = (e.dir
      ? '<a href="/api/sandbox/downloadDir?uri=' + q + '&path=' + p + '"><button title="递归打包为 tar（无压缩）下载">下载 .tar</button></a>'
      : '<a href="javascript:void(0)" onclick="sbOpenSub(\'view\',this)" data-p="' + p + '"><button title="新标签页展示文件内容">查看</button></a>'
        + ' <a href="javascript:void(0)" onclick="sbOpenSub(\'tail\',this)" data-p="' + p + '"><button title="新标签页实时监听文件新增内容">监听</button></a>'
        + ' <a href="/api/sandbox/download?uri=' + q + '&path=' + p + '"><button>下载</button></a>')
      + ' <a href="javascript:void(0)" onclick="sbUpload(this)" data-p="' + p + '" data-dir="' + (e.dir ? '1' : '0') + '" title="上传本地文件到此' + (e.dir ? '目录' : '文件所在目录') + '">上传</a>'
      + ' <a href="javascript:void(0)" class="bad" onclick="sbDelete(this)" data-p="' + p + '" data-name="' + esc(e.name) + '" data-dir="' + (e.dir ? '1' : '0') + '" style="margin-left:6px" title="删除（不可恢复）">删除</a>';
    var name = e.dir
      ? '<a href="javascript:void(0)" data-p="' + p + '" onclick="sbGoBtn(this)">' + esc(e.name) + '/</a>'
      : esc(e.name) + (e.link ? ' <span class="muted">[链接]</span>' : '');
    html += '<tr><td>' + name + '</td><td>' + (e.dir ? '目录' : fmtSize(e.size)) + '</td><td class="muted">' + (e.mtime ? new Date(e.mtime).toLocaleString() : '') + '</td><td>' + act + '</td></tr>';
  });
  return html + '</table>';
}
function syncGroup(){
  var on = document.getElementById('f-src-device').checked;
  var g = document.getElementById('vlv');
  g.classList.toggle('dim', !on);
  g.querySelectorAll('input').forEach(function(c){ c.disabled = !on; });
}
syncGroup();
function restartDaemon(){
  if (!confirm('重启守护进程？正在进行的调试会话会自动重连。')) return;
  fetch('/api/daemon/restart', {method: 'POST'}).then(function(r){ return r.json(); }).then(function(d){ alert(d.message); refreshDaemon(); });
}
// ── P9 Widget 树浏览 + 截图高亮 ──
var wtNodes = [], wtDpr = 1, wtPhysW = 0, wtPhysH = 0, wtSel = -1, wtExpand = {}, wtFilter = '', wtParents = [];
var wtPickRect = null; // P9b 点截图反查到的业务组件逻辑 rect（pick 精确值，优先于树节点 bounds）
// P9b SDK 组件名单：仅用于树中淡化展示（opacity .5），不影响点截图反查判定
var wtSdkTypes = {};
(function(){
  var names = 'Padding,SizedBox,ConstrainedBox,Align,Center,FittedBox,AspectRatio,FractionallySizedBox,LimitedBox,IntrinsicWidth,IntrinsicHeight,Opacity,Transform,ClipRect,ClipRRect,ClipOval,ClipPath,Column,Row,Stack,Flex,Wrap,IndexedStack,Expanded,Flexible,Spacer,Positioned,Semantics,IndexedSemantics,Listener,GestureDetector,RawGestureDetector,MouseRegion,Builder,LayoutBuilder,KeyedSubtree,RepaintBoundary,Offstage,Visibility,AbsorbPointer,IgnorePointer,Container,DecoratedBox,ColoredBox,Material,Scaffold,AppBar,Text,RichText,EditableText,DefaultTextStyle,Icon,Image,RawImage,Placeholder,CustomPaint,PhysicalModel,PhysicalShape,MediaQuery,Directionality,Focus,FocusScope,FocusTraversalGroup,Title,Navigator,Router,TickerMode,AutomaticKeepAlive,KeepAlive,Scrollbar,ScrollView,ListView,GridView,SliverPadding,SliverList,SliverGrid,SliverToBoxAdapter,BottomNavigationBar,TabBar,TabBarView,PageView,TextField,ButtonBar,ElevatedButton,TextButton,IconButton,InkWell,InkResponse,Tooltip,Divider,ListTile,CircleAvatar,Chip,Card,Dialog,AlertDialog,SnackBar,AnnotatedRegion,DefaultTabController,AnimatedSwitcher,AnimatedBuilder,FadeTransition,SlideTransition,ScaleTransition,RotationTransition,AnimatedOpacity,AnimatedContainer,AnimatedPositioned,Hero,WillPopScope,SafeArea,SingleChildScrollView,NestedScrollView,RefreshIndicator,RawView,View'.split(',');
  for (var i = 0; i < names.length; i++) wtSdkTypes[names[i]] = 1;
})();
function wtIsSdk(t){
  if (t.charAt(0) === '_') return 1;
  if (wtSdkTypes[t]) return 1;
  var g = t.indexOf('<');
  if (g > 0 && wtSdkTypes[t.substring(0, g)]) return 1;
  return 0;
}
function wtUri(){ return vmFilter ? (vmUriBySource[vmFilter] || '') : ''; }
function wtLoad(){
  var u = wtUri();
  if (!u) { alert('请先在页头选择 VM 会话'); return; }
  document.getElementById('wt-tip').textContent = '加载中…';
  fetch('/api/wtree?uri=' + encodeURIComponent(u))
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (!d.ok) { document.getElementById('wt-tip').textContent = '失败：' + (d.error || d); return; }
      wtNodes = d.nodes || []; wtDpr = d.dpr || 1; wtPhysW = d.physW || 0; wtPhysH = d.physH || 0;
      wtSel = -1; wtExpand = {}; wtParents = [];
      // 构建父指针：栈内保存每层最近节点 idx
      var st = [];
      for (var i = 0; i < wtNodes.length; i++) {
        var dd = wtNodes[i].d;
        while (st.length && wtNodes[st[st.length-1]].d >= dd) st.pop();
        wtParents.push(st.length ? st[st.length-1] : -1);
        st.push(i);
      }
      wtRender();
      var img = document.getElementById('wt-img');
      img.style.display = '';
      img.src = '/api/screenshot?uri=' + encodeURIComponent(u) + '&t=' + Date.now();
      img.onload = function(){ document.getElementById('wt-tip').textContent = ''; wtDrawBox(); };
      if (img.complete && img.naturalWidth) wtDrawBox();
    })
    .catch(function(e){ document.getElementById('wt-tip').textContent = '失败：' + e; });
}
function wtVisibleSet(){
  if (!wtFilter) return null;
  var vis = {}, st = [];
  for (var i = 0; i < wtNodes.length; i++) {
    var n = wtNodes[i];
    while (st.length && wtNodes[st[st.length-1]].d >= n.d) st.pop();
    var kw = wtFilter.toLowerCase();
    if (n.t.toLowerCase().indexOf(kw) >= 0 || (n.k && n.k.toLowerCase().indexOf(kw) >= 0)) {
      vis[i] = 1;
      for (var j = 0; j < st.length; j++) vis[st[j]] = 1;
    }
    st.push(i);
  }
  return vis;
}
function wtRender(){
  var el = document.getElementById('wt-body');
  if (!wtNodes.length) { el.innerHTML = '<span class="muted">请先选择 VM 并点击「刷新树 + 截图」</span>'; return; }
  var vis = wtVisibleSet();
  var html = '', skipD = -1;
  for (var i = 0; i < wtNodes.length; i++) {
    var n = wtNodes[i];
    if (vis) { if (!vis[i]) continue; }
    else {
      if (n.d <= skipD) skipD = -1;
      if (skipD >= 0 && n.d > skipD) continue;
    }
    var hasKids = i + 1 < wtNodes.length && wtNodes[i+1].d === n.d + 1;
    var open = hasKids && (wtExpand[i] !== undefined ? wtExpand[i] : n.d < 6);
    // 缩进封顶：超深层级不真实缩进（否则文字横向出视口，看似空白），改显父链尾
    var pad = Math.min(n.d, 24) * 14 + 4;
    var anc = '';
    if (n.d > 24 && wtParents.length) {
      var p1 = wtParents[i] >= 0 ? wtParents[i] : -1;
      var p2 = p1 >= 0 ? wtParents[p1] : -1;
      anc = (p2 >= 0 ? wtNodes[p2].t + '/' : '') + (p1 >= 0 ? wtNodes[p1].t + '/' : '');
    }
    html += '<div class="wtrow' + (i === wtSel ? ' wtsel' : '') + (wtIsSdk(n.t) ? ' wtsdk' : '') + '" id="wtn-' + i + '" style="padding-left:' + pad + 'px" onclick="wtSelect(' + i + ')">'
      + (hasKids ? '<a href="javascript:void(0)" class="wttgl" onclick="event.stopPropagation();wtToggle(' + i + ')">' + (open ? '▾' : '▸') + '</a>' : '<span class="wttgl">·</span>')
      + (anc ? '<span class="muted">' + esc(anc) + '</span>' : '')
      + '<b>' + esc(n.t) + '</b>' + (n.k ? ' <span class="muted">' + esc(n.k) + '</span>' : '')
      + '</div>';
    if (hasKids && !open) skipD = n.d;
  }
  el.innerHTML = html || '<span class="muted">无匹配节点</span>';
}
function wtToggle(i){
  var open = wtExpand[i] !== undefined ? wtExpand[i] : wtNodes[i].d < 6;
  wtExpand[i] = !open;
  wtRender();
}
function wtExpandAll(){ for (var i = 0; i < wtNodes.length; i++) wtExpand[i] = true; wtRender(); }
function wtCollapseAll(){ for (var i = 0; i < wtNodes.length; i++) wtExpand[i] = false; wtRender(); }
function wtDoFilter(v){ wtFilter = v.trim(); wtRender(); }
function wtSelect(i, scroll){
  wtPickRect = null;
  var rf = document.getElementById('wt-refs');
  if (rf) rf.innerHTML = '';
  var old = document.getElementById('wtn-' + wtSel);
  if (old) old.classList.remove('wtsel');
  wtSel = i;
  // 若目标行被折叠隐藏，展开其祖先链后重渲染
  if (!document.getElementById('wtn-' + i)) {
    var p = wtParents[i];
    while (p >= 0) { wtExpand[p] = true; p = wtParents[p]; }
    wtRender();
  }
  var row = document.getElementById('wtn-' + i);
  if (row) { row.classList.add('wtsel'); if (scroll) row.scrollIntoView({block: 'center'}); }
  var n = wtNodes[i];
  var info = '深度 ' + n.d + ' · ' + n.t + (n.k ? ' · ' + n.k : '');
  if (n.b) info += ' · bounds (' + n.b[0] + ',' + n.b[1] + ') ' + n.b[2] + '×' + n.b[3];
  document.getElementById('wt-info').textContent = info;
  wtDrawBox();
}
function wtDrawBox(){
  var box = document.getElementById('wt-box');
  var img = document.getElementById('wt-img');
  var b = wtPickRect;
  if (!b && wtSel >= 0 && wtNodes[wtSel]) b = wtNodes[wtSel].b;
  if (!b || !img.naturalWidth || !wtPhysW) { box.style.display = 'none'; return; }
  var scale = img.clientWidth / wtPhysW; // 显示像素 / 物理像素
  var d = wtDpr;                          // 物理像素 / 逻辑像素
  box.style.display = '';
  box.style.left = (b[0] * d * scale) + 'px';
  box.style.top = (b[1] * d * scale) + 'px';
  box.style.width = (b[2] * d * scale) + 'px';
  box.style.height = (b[3] * d * scale) + 'px';
}
function wtImgClick(ev){
  if (!wtPhysW) return;
  var rect = ev.target.getBoundingClientRect();
  var lx = (ev.clientX - rect.left) * (wtPhysW / rect.width) / wtDpr;
  var ly = (ev.clientY - rect.top) * (wtPhysH / rect.height) / wtDpr;
  var u = wtUri();
  if (!u) return;
  document.getElementById('wt-info').textContent = '反查中…';
  fetch('/api/wtree/pick?uri=' + encodeURIComponent(u) + '&x=' + lx.toFixed(1) + '&y=' + ly.toFixed(1), {method: 'POST'})
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (!d.ok) { document.getElementById('wt-info').textContent = '反查失败：' + (d.error || d); return; }
      var bs = (d.bounds || '').split(',').map(Number);
      wtPickRect = bs.length === 4 ? bs : null;
      var fb = (d.file || '').split('/').pop();
      var info = d.type + (wtPickRect ? ' · ' + wtPickRect[2] + '×' + wtPickRect[3] : '') + (fb ? ' · ' + fb + ':' + d.line + ':' + d.col : '');
      var sp = d.spacing || [];
      if (sp.length) info += ' · ' + sp.map(function(s){
        var a = s.dir === 'up' ? '↑' : s.dir === 'down' ? '↓' : s.dir === 'left' ? '←' : '→';
        return a + s.dist + '(' + s.type + ')';
      }).join(' ');
      document.getElementById('wt-info').textContent = info;
      wtDrawBox();
      // 树定位：type + bounds 匹配（同快照时精确命中）
      var hit = -1;
      if (wtPickRect) {
        for (var i = 0; i < wtNodes.length; i++) {
          var n = wtNodes[i];
          if (n.t !== d.type || !n.b) continue;
          if (n.b[0] === wtPickRect[0] && n.b[1] === wtPickRect[1] && n.b[2] === wtPickRect[2] && n.b[3] === wtPickRect[3]) { hit = i; break; }
        }
      }
      if (hit >= 0) {
        var old = document.getElementById('wtn-' + wtSel);
        if (old) old.classList.remove('wtsel');
        wtSel = hit;
        if (!document.getElementById('wtn-' + hit)) {
          var p = wtParents[hit];
          while (p >= 0) { wtExpand[p] = true; p = wtParents[p]; }
          wtRender();
        }
        var row = document.getElementById('wtn-' + hit);
        if (row) { row.classList.add('wtsel'); row.scrollIntoView({block: 'center'}); }
        wtDrawBox();
      }
      wtRefsRender(sp);
    })
    .catch(function(e){ document.getElementById('wt-info').textContent = '反查失败：' + e; });
}
function wtRefsRender(sp){
  var el = document.getElementById('wt-refs');
  var img = document.getElementById('wt-img');
  el.innerHTML = '';
  if (!sp.length || !wtPhysW || !img.naturalWidth) return;
  var scale = img.clientWidth / wtPhysW, d = wtDpr;
  var html = '';
  for (var i = 0; i < sp.length; i++) {
    var s = sp[i];
    if (!s.rect) continue;
    var r = s.rect.split(',').map(Number);
    if (r.length !== 4 || r[2] <= 0 || r[3] <= 0) continue;
    var arrow = s.dir === 'up' ? '↑' : s.dir === 'down' ? '↓' : s.dir === 'left' ? '←' : '→';
    html += '<div class="wtref" style="left:' + (r[0]*d*scale) + 'px;top:' + (r[1]*d*scale) + 'px;width:' + (r[2]*d*scale) + 'px;height:' + (r[3]*d*scale) + 'px"></div>';
    var mx, my;
    if (wtPickRect) {
      var pcx = wtPickRect[0] + wtPickRect[2]/2;
      var pcy = wtPickRect[1] + wtPickRect[3]/2;
      if (s.kind === 'parent') {
        // parent 参照：父容器包含目标，标注画在目标对应边与父容器对应边之间
        if (s.dir === 'up') { mx = pcx; my = (wtPickRect[1] + r[1]) / 2; }
        else if (s.dir === 'down') { mx = pcx; my = (wtPickRect[1] + wtPickRect[3] + r[1] + r[3]) / 2; }
        else if (s.dir === 'left') { mx = (wtPickRect[0] + r[0]) / 2; my = pcy; }
        else { mx = (wtPickRect[0] + wtPickRect[2] + r[0] + r[2]) / 2; my = pcy; }
      } else {
        // widget 参照：目标与参照不重叠，标注画在两面对应边之间
        if (s.dir === 'up') { mx = pcx; my = (wtPickRect[1] + r[1] + r[3]) / 2; }
        else if (s.dir === 'down') { mx = pcx; my = (wtPickRect[1] + wtPickRect[3] + r[1]) / 2; }
        else if (s.dir === 'left') { mx = (wtPickRect[0] + r[0] + r[2]) / 2; my = pcy; }
        else { mx = (wtPickRect[0] + wtPickRect[2] + r[0]) / 2; my = pcy; }
      }
    } else { mx = r[0]; my = r[1]; }
    html += '<div class="wtreflbl" style="left:' + (mx*d*scale) + 'px;top:' + (my*d*scale) + 'px">' + arrow + s.dist + ' ' + esc(s.type) + '</div>';
  }
  el.innerHTML = html;
}
window.addEventListener('resize', function(){ wtDrawBox(); });
function openConfig(){ fetch('/api/openconfig', {method: 'POST'}); }
var ideOrder = [], ideInstalled = [], ideDragIdx = -1;
function loadIdeOrder(){
  fetch('/api/ideorder').then(function(r){ return r.json(); }).then(function(d){
    if (!d.ok) return;
    ideOrder = d.order || []; ideInstalled = d.installed || [];
    renderIdeOrder();
    var tips = [];
    if (d.added && d.added.length) tips.push('检测到新安装的 IDE，已追加到末尾：' + d.added.join(', '));
    if (d.removed && d.removed.length) tips.push('已移除重复的等价别名：' + d.removed.join(', '));
    if (tips.length) document.getElementById('ide-order-tip').textContent = tips.join('；');
  }).catch(function(){});
}
function renderIdeOrder(){
  var ul = document.getElementById('ide-order-list');
  ul.innerHTML = '';
  ideOrder.forEach(function(name, idx){
    var li = document.createElement('li');
    li.draggable = true;
    li.dataset.idx = idx;
    var notInst = ideInstalled.indexOf(name) < 0;
    li.innerHTML = '<span class="handle">☰</span><span>' + esc(name) + '</span>'
      + (notInst ? '<span class="notinstalled">未安装</span>' : '');
    li.addEventListener('dragstart', function(e){
      ideDragIdx = idx;
      li.classList.add('dragging');
      try { e.dataTransfer.setData('text/plain', String(idx)); } catch(_) {}
      e.dataTransfer.effectAllowed = 'move';
    });
    li.addEventListener('dragover', function(e){ e.preventDefault(); li.classList.add('dragover'); });
    li.addEventListener('dragleave', function(){ li.classList.remove('dragover'); });
    li.addEventListener('drop', function(e){
      e.preventDefault();
      li.classList.remove('dragover');
      var from = ideDragIdx, to = idx;
      if (from < 0 || from === to) return;
      var item = ideOrder.splice(from, 1)[0];
      ideOrder.splice(to, 0, item);
      renderIdeOrder();
      saveIdeOrderList();
    });
    li.addEventListener('dragend', function(){ li.classList.remove('dragging'); ideDragIdx = -1; });
    ul.appendChild(li);
  });
}
function saveIdeOrderList(){
  var tip = document.getElementById('ide-order-tip');
  fetch('/api/ideorder', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ideOrder: ideOrder})})
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.ok) {
        tip.textContent = '已保存：' + (d.ideOrder || []).join(' → ');
      } else {
        tip.textContent = '保存失败：' + (d.message || d);
        loadIdeOrder(); // 校验失败时用服务端配置恢复显示
      }
    })
    .catch(function(e){ tip.textContent = '保存失败：' + e; });
}
function resetIdeOrder(){
  ideOrder = ['qodercn','qoder-cn','cursor','trae','windsurf','code','androidStudio'];
  renderIdeOrder();
  saveIdeOrderList();
}
// ── 实例 Tab：注册表/类名查找定位实例，字段树展开与编辑写回 ──
var inItems = [], inCurId = '', inCurName = '';
var inCurNode = null; // 当前字段树数据缓存（勾选切换时本地重渲染用）
function inUri(){ return vmFilter ? (vmUriBySource[vmFilter] || '') : ''; }
function inActive(){ var t = document.querySelector('.tab.active'); return t && t.dataset.tab === 'instances'; }
function inStat(s){ document.getElementById('in-stat').textContent = s; }
function inRefresh(){
  if (!inActive()) return;
  if (!inUri()) {
    document.getElementById('in-list').innerHTML = '<span class="muted">请先选择 VM（页头右侧会话下拉框）</span>';
    document.getElementById('in-tree').innerHTML = '';
  }
}
function inApi(path){
  var uri = inUri();
  if (!uri) return Promise.reject('请先选择 VM');
  return fetch(path + (path.indexOf('?') < 0 ? '?' : '&') + 'uri=' + encodeURIComponent(uri))
    .then(function(r){ return r.json(); });
}
function inLoadStores(){
  var list = document.getElementById('in-list');
  inStat('读取注册表…'); document.getElementById('in-tree').innerHTML = '';
  inApi('/api/instances/stores').then(function(d){
    if (!d.ok) { list.innerHTML = '<span class="bad">' + esc(d.error) + '</span>'; inStat('读取失败'); return; }
    inRenderList(d.items.map(function(it){ return { id: it.instId, cls: it.cls, source: 'store', name: it.id }; }), '注册表 ' + d.items.length + ' 项（未注册时请先在 app 内调 XBUme.registerStore）');
  }).catch(function(e){ list.innerHTML = '<span class="bad">' + esc(String(e)) + '</span>'; inStat('读取失败'); });
}
function inFind(){
  var cls = document.getElementById('in-cls').value.trim();
  if (!cls) { inStat('请输入类名'); return; }
  var list = document.getElementById('in-list');
  inStat('查找 ' + cls + ' …'); document.getElementById('in-tree').innerHTML = '';
  inApi('/api/instances/find?class=' + encodeURIComponent(cls)).then(function(d){
    if (!d.ok) { list.innerHTML = '<span class="bad">' + esc(d.error) + '</span>'; inStat('查找失败'); return; }
    inRenderList(d.items, '类 ' + cls + '：命中 ' + d.items.length + ' 个实例');
  }).catch(function(e){ list.innerHTML = '<span class="bad">' + esc(String(e)) + '</span>'; inStat('查找失败'); });
}
var inSourceNames = { store: 'Store', tree: 'Element 树', heap: '堆扫描' };
function inRenderList(items, msg){
  var list = document.getElementById('in-list');
  inStat(msg); inItems = items;
  if (!items.length) { list.innerHTML = '<span class="muted">无结果</span>'; return; }
  list.innerHTML = items.map(function(it, i){
    return '<div style="display:flex;align-items:center;gap:10px;padding:3px 0;border-bottom:1px solid var(--line)">'
      + '<span class="muted" style="font-size:12px;width:78px;flex:none">' + esc(inSourceNames[it.source] || it.source) + '</span>'
      + '<span style="width:240px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:none">' + esc(it.cls) + '</span>'
      + '<span class="muted" style="font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + esc(it.name ? it.name + ' · ' : '') + esc(String(it.id).slice(0, 14)) + '…</span>'
      + '<button style="flex:none" onclick="inShow(' + i + ')">查看字段</button>'
      + '</div>';
  }).join('');
}
function inShow(i){ var it = inItems[i]; if (it) inShowId(it.id, it.cls); }
// 字段树刷新对比：inSnap 保存上次渲染的叶子展示值（字段路径 → 值），
// 重新拉取时值变化的节点整行高亮并标注旧值；展开的子树也并入快照。
var inSnap = {}, inSnapId = '';
function inChildPath(path, name){ return path + '/' + (name || '?'); }
function inFlatten(n, path, out){
  out = out || {};
  var kind = n.kind || 'object';
  if (kind === 'value') out[path] = String(n.value);
  else if (kind === 'ref') out[path] = (n.value !== '' && n.value != null ? String(n.value) : '(' + (n.cls || '?') + ')');
  else if (kind === 'list' || kind === 'map') out[path] = '(' + kind + ' ' + (n.length || 0) + ' 项)';
  var kids = n.children || [];
  for (var i = 0; i < kids.length; i++) inFlatten(kids[i], inChildPath(path, kids[i].name), out);
  return out;
}
function inShowId(id, name){
  inCurId = id; inCurName = name;
  // 换实例时清空对比基线；同一实例的「刷新」保留基线，用于标注变化字段。
  if (inSnapId !== id) { inSnap = {}; inSnapId = id; }
  var tree = document.getElementById('in-tree');
  tree.innerHTML = '<span class="muted">加载字段树…</span>';
  inApi('/api/instances/tree?id=' + encodeURIComponent(id) + '&name=' + encodeURIComponent(name) + '&depth=3').then(function(d){
    if (!d.ok) { tree.innerHTML = '<span class="bad">' + esc(d.error) + '</span>'; return; }
    inCurNode = d.node;
    // 标题栏会随 innerHTML 重建，勾选框状态先从旧 DOM 读出来带回。
    var prevBox = document.getElementById('in-user-only');
    var userOnly = prevBox ? prevBox.checked : true;
    tree.innerHTML = '<div style="display:flex;align-items:center;gap:8px"><b>' + esc(name) + '</b>'
      + '<span class="muted" style="font-size:12px">' + esc(String(id).slice(0, 14)) + '…</span>'
      + '<label style="font-size:12px;display:flex;align-items:center;gap:3px" title="勾选时隐藏 Flutter/dart SDK 类声明的字段（如 ChangeNotifier 内部的 _count/_listeners），只看业务字段">'
      + '<input type="checkbox" id="in-user-only"' + (userOnly ? ' checked' : '') + ' onchange="inToggleUserOnly()"> 仅用户字段</label>'
      + '<button onclick="inShowId(inCurId, inCurName)" title="重新拉取；值有变化的字段会整行高亮并标注旧值">刷新</button></div>'
      + '<div id="in-tree-body" style="font-family:monospace;font-size:12.5px;margin-top:4px">' + inNode(inCurNode, 0, id, '') + '</div>';
    // 本次渲染结果合并进基线（保留已展开子树的深层字段，供下次刷新对比）。
    var fresh = inFlatten(d.node, '');
    for (var k in fresh) inSnap[k] = fresh[k];
  }).catch(function(e){ tree.innerHTML = '<span class="bad">' + esc(String(e)) + '</span>';
  });
}
// 勾选「仅用户字段」：用缓存的树数据本地重渲染（不重新请求、不重建标题栏）。
function inToggleUserOnly(){
  var body = document.getElementById('in-tree-body');
  if (body && inCurNode) body.innerHTML = inNode(inCurNode, 0, inCurId, '');
}
// VM 内部类名 → 友好类型名（int 在 VM 里的类是 _Smi/_Mint 等）。
function inTypeOf(cls){
  if (cls === '_Smi' || cls === '_Mint' || cls === 'int' || cls === '_Int64') return 'int';
  if (cls === '_Double' || cls === 'double' || cls === 'num') return 'double';
  if (cls === '_Bool' || cls === 'bool') return 'bool';
  if (cls === '_OneByteString' || cls === '_TwoByteString' || cls === 'String') return 'String';
  if (cls === 'Null') return 'null';
  return cls || '';
}
function inVTypeOf(cls){
  var t = inTypeOf(cls);
  if (t === 'int' || t === 'double' || t === 'bool' || t === 'null') return t;
  return 'string';
}
// 「仅用户字段」勾选状态；勾选框不存在时不过滤。
function inUserOnly(){
  var c = document.getElementById('in-user-only');
  return c ? c.checked : false;
}
// 渲染字段树节点。ownerId 为本节点字段的宿主对象 id（编辑写回的目标）。
function inNode(n, level, ownerId, path){
  var kind = n.kind || 'object';
  // 「仅用户字段」：SDK 类声明的字段（含其整个子树）不渲染。
  if (n.sdk && inUserOnly()) return '';
  var pad = 'padding-left:' + (level * 16) + 'px';
  var pathAttr = 'decodeURIComponent(\'' + encodeURIComponent(path || '') + '\')';
  // 与 inFlatten 一致的展示值；与上次快照不同则整行标注变更与旧值。
  var shownV = null;
  if (kind === 'value') shownV = String(n.value);
  else if (kind === 'ref') shownV = (n.value !== '' && n.value != null ? String(n.value) : '(' + (n.cls || '?') + ')');
  else if (kind === 'list' || kind === 'map') shownV = '(' + kind + ' ' + (n.length || 0) + ' 项)';
  var oldV = shownV == null ? undefined : inSnap[path];
  var changed = shownV != null && oldV !== undefined && oldV !== shownV;
  var nameAttr = 'decodeURIComponent(\'' + encodeURIComponent(n.name || '') + '\')';
  var ownerAttr = 'decodeURIComponent(\'' + encodeURIComponent(ownerId || '') + '\')';
  var head;
  if (kind === 'value') {
    var vtype = inVTypeOf(n.cls || '');
    var canEdit = (vtype === 'int' || vtype === 'double' || vtype === 'bool' || vtype === 'string') && n.name && ownerId;
    var vtypeName = inTypeOf(n.cls || '');
    head = (vtypeName && vtypeName !== 'null' ? '<span class="muted">' + esc(vtypeName) + '</span> ' : '')
      + '<span class="in-val" style="color:#79c0ff">' + esc(n.value) + '</span>'
      + (n.truncated ? '<span class="muted">（截断）</span>' : '')
      + (canEdit ? ' <a href="javascript:void(0)" style="font-size:12px" onclick="inEdit(this, ' + nameAttr + ', \'' + vtype + '\', ' + ownerAttr + ')">编辑</a>' : '');
  } else if (kind === 'list' || kind === 'map') {
    head = '<span style="color:#d2a8ff">' + esc(n.cls || (kind === 'map' ? 'Map' : 'List')) + '</span>（' + esc(n.length || '?') + ' 项）';
  } else if (kind === 'circular') {
    head = '<span class="muted">（循环引用）</span>';
  } else if (kind === 'expired') {
    head = '<span class="muted">（实例已回收）</span>';
  } else if (kind === 'ref') {
    var type = inTypeOf(n.cls || '');
    var primitive = type === 'int' || type === 'double' || type === 'bool' || type === 'String' || type === 'null';
    head = (type && type !== 'null' ? '<span class="muted">' + esc(type) + '</span> ' : '')
      + (n.value !== '' ? '<span class="in-val" style="color:#79c0ff">' + esc(n.value) + '</span>' : '<span class="muted">' + esc(n.cls || '?') + '</span>')
      + (!primitive && n.id ? ' <a href="javascript:void(0)" style="font-size:12px" onclick="inExpand(this, \'' + esc(n.id) + '\', ' + nameAttr + ', ' + pathAttr + ')">展开</a>' : '');
  } else if (kind === 'opaque') {
    head = '<span class="muted">' + esc(n.cls || '（无法展示）') + '</span>';
  } else {
    head = '<span style="color:#d2a8ff">' + esc(n.cls || '') + '</span>';
  }
  // 字段名所有节点类型都展示（ref/value 深度用尽时是大多数，隐藏名称会看不出字段）。
  var html = '<div style="' + pad + (changed ? ';background:rgba(255,159,10,.14)' : '') + '">'
    + (changed ? '<span style="color:#ff9f0a">● </span>' : '')
    + (n.name ? '<span class="muted">' + esc(n.name) + '</span> ' : '')
    + head
    + (changed ? ' <span class="muted" style="text-decoration:line-through">旧: ' + esc(oldV) + '</span>' : '')
    + '</div>';
  var kids = n.children || [];
  for (var i = 0; i < kids.length; i++) html += inNode(kids[i], level + 1, n.id, inChildPath(path, kids[i].name));
  return html;
}
// ref 节点二次展开：把该行替换为请求返回的子树（保留字段名）。
function inExpand(el, id, name, path){
  var holder = el.parentNode;
  var level = Math.round((parseInt(holder.style.paddingLeft || '0', 10) || 0) / 16);
  holder.innerHTML = '<span class="muted">展开中…</span>';
  inApi('/api/instances/tree?id=' + encodeURIComponent(id) + '&depth=2').then(function(d){
    if (!d.ok) { holder.innerHTML = '<span class="bad">' + esc(d.error) + '</span>'; return; }
    d.node.name = d.node.name || name || '';
    var tmp = document.createElement('div');
    tmp.innerHTML = inNode(d.node, level, id, path || '');
    // 展开的子树并入基线（渲染对比已用旧值完成，这里更新为最新拉取值）。
    var sub = inFlatten(d.node, path || '');
    for (var k in sub) inSnap[k] = sub[k];
    var frag = document.createDocumentFragment();
    while (tmp.firstChild) frag.appendChild(tmp.firstChild);
    holder.parentNode.replaceChild(frag, holder);
  }).catch(function(e){ holder.innerHTML = '<span class="bad">' + esc(String(e)) + '</span>'; });
}
function inEdit(el, name, vtype, ownerId){
  var row = el.parentNode;
  var cur = row.querySelector('.in-val') ? row.querySelector('.in-val').textContent : '';
  var nameAttr = 'decodeURIComponent(\'' + encodeURIComponent(name) + '\')';
  var ownerAttr = 'decodeURIComponent(\'' + encodeURIComponent(ownerId) + '\')';
  row.innerHTML = '<input style="width:200px;font-family:monospace"> '
    + '<span class="muted" style="font-size:12px">' + esc(vtype) + '</span> '
    + '<button class="primary" onclick="inSave(this, ' + nameAttr + ', \'' + vtype + '\', ' + ownerAttr + ')">保存</button> '
    + '<a href="javascript:void(0)" style="font-size:12px" onclick="inShowId(inCurId, inCurName)">取消</a>';
  var input = row.querySelector('input');
  input.value = cur;
  input.focus();
}
function inSave(el, name, vtype, ownerId){
  var val = el.parentNode.querySelector('input').value;
  if (vtype === 'int' || vtype === 'double') {
    if (isNaN(Number(val))) { inStat('值不是合法数字'); return; }
  }
  if (vtype === 'bool' && val !== 'true' && val !== 'false') { inStat('值必须是 true/false'); return; }
  inStat('写回中…');
  var uri = inUri();
  fetch('/api/instances/set?uri=' + encodeURIComponent(uri) + '&id=' + encodeURIComponent(ownerId)
      + '&field=' + encodeURIComponent(name) + '&value=' + encodeURIComponent(val) + '&vtype=' + vtype, { method: 'POST' })
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (!d.ok) { inStat('写回失败：' + (d.error || '')); return; }
      inStat('已写回' + (d.notified ? '，已 notifyListeners' : ''));
      inShowId(inCurId, inCurName);
    })
    .catch(function(e){ inStat('写回失败：' + String(e)); });
}
loadIdeOrder();
</script>
</body>
</html>
''';

/// 文件查看（view）/ 监听（tail）独立页面，新标签页打开。
/// __MODE__ 替换为 view / tail；与主页面同暗色主题，行数组全量保留在
/// 内存，搜索（高亮不过滤）与过滤（只留匹配行）在渲染时应用。
const String _fileViewerTemplate = r'''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>__TITLE__ · xb_ume 工具箱</title>
<style>
  * { box-sizing: border-box; }
  body { margin:0; background:#0d1117; color:#e6edf3; font:13px/1.5 -apple-system,'PingFang SC',sans-serif; height:100vh; display:flex; flex-direction:column; }
  header { flex:none; padding:8px 14px; border-bottom:1px solid #30363d; background:#0d1117; }
  header .row { display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-bottom:6px; }
  header b { color:#58a6ff; }
  #path { color:#8b949e; word-break:break-all; font-size:12px; }
  input[type=text] { background:#161b22; border:1px solid #30363d; color:#e6edf3; border-radius:6px; padding:5px 8px; width:210px; }
  input[type=text]:focus { outline:none; border-color:#58a6ff; }
  button { background:#21262d; border:1px solid #30363d; color:#e6edf3; border-radius:6px; padding:5px 12px; cursor:pointer; }
  #info { color:#8b949e; font-size:12px; }
  #status { color:#8b949e; font-size:12px; margin-left:auto; }
  #status.bad { color:#f85149; }
  label.chk { color:#c9d1d9; font-size:12px; display:flex; align-items:center; gap:4px; white-space:nowrap; cursor:pointer; }
  input[type=checkbox] { accent-color:#58a6ff; margin:0; vertical-align:middle; }
  #tailbtns { display:none; align-items:center; gap:8px; }
  #body { flex:1 1 0; min-height:0; overflow:auto; padding:10px 14px; white-space:pre-wrap; word-break:break-all; font:12px/1.6 Menlo,monospace; }
  mark { background:#e3b341; color:#24292f; border-radius:2px; }
  mark.mf { background:#3fb950; color:#0d1117; }
  mark.mb { background:#f0883e; color:#24292f; }
  .lg { color:#8b949e; font-size:12px; display:inline-flex; align-items:center; gap:4px; }
  .lg i { width:10px; height:10px; border-radius:2px; display:inline-block; }
  .ds { background:#e3b341; }
  .df { background:#3fb950; }
  .db { background:#f0883e; }
</style>
</head>
<body>
<header>
  <div class="row">
    <b>__TITLE__</b>
    <input type="text" id="search" placeholder="搜索（高亮，不过滤内容）">
    <input type="text" id="filter" placeholder="过滤（只保留匹配行）">
    <span class="lg"><i class="ds"></i>搜索</span>
    <span class="lg"><i class="df"></i>过滤</span>
    <span class="lg"><i class="db"></i>同时命中</span>
    <span id="info">-</span>
    <span id="tailbtns" style="display:none">
      <button id="pausebtn" onclick="togglePause()">暂停</button>
      <button id="restartbtn" onclick="restart()" style="display:none">重新开始</button>
      <label class="chk"><input type="checkbox" id="autoscroll" checked>自动滚动</label>
    </span>
    <button id="clearbtn" onclick="clearBody()">清屏</button>
    <span id="status">加载中…</span>
  </div>
  <div id="path"></div>
</header>
<div id="body"></div>
<script>
function $(id){ return document.getElementById(id); }
var MODE = '__MODE__';
var qs = new URLSearchParams(location.search);
var uri = qs.get('uri') || '', fpath = qs.get('path') || '';
$('path').textContent = fpath;
document.title = (fpath.split('/').pop() || 'file') + ' · __TITLE__';
if (MODE === 'tail') $('tailbtns').style.display = 'inline-flex';

var lines = [], pending = '';
// tail 模式行数上限：长时间监听高吞吐文件时丢弃最早行，防内存无限增长
// （完整内容看「查看」页或「下载」）；查看页不受限（一次性静态快照）。
var MAX_LINES = 50000, droppedLines = 0;
var searchKw = '', filterKw = '';
var offset = 0, started = false, stopped = false, paused = false;
var renderTimer = null;
var CHUNK = 1024 * 1024;

function esc(s){ return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function fmtSize(n){
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n/1024).toFixed(1) + ' KB';
  if (n < 1073741824) return (n/1048576).toFixed(1) + ' MB';
  return (n/1073741824).toFixed(2) + ' GB';
}
function setStatus(s, bad){ var el = $('status'); el.textContent = s; el.className = bad ? 'bad' : ''; }
function scheduleRender(){ if (renderTimer) return; renderTimer = setTimeout(function(){ renderTimer = null; render(); }, 200); }

function apiRead(off, max, cb){
  fetch('/api/sandbox/read?uri=' + encodeURIComponent(uri) + '&path=' + encodeURIComponent(fpath) + '&offset=' + off + '&max=' + max)
    .then(function(r){ return r.json(); }).then(cb)
    .catch(function(e){ setStatus('请求失败：' + e, true); });
}

function pushText(text){
  pending += text;
  var idx = pending.lastIndexOf('\n');
  if (idx < 0) return;
  var complete = pending.substring(0, idx);
  pending = pending.substring(idx + 1);
  var arr = complete.split('\n');
  for (var i = 0; i < arr.length; i++) lines.push(arr[i]);
  // 仅 tail 模式裁剪：超限丢弃最早行，丢弃量由 poll 的状态文本展示。
  if (MODE === 'tail' && lines.length > MAX_LINES) {
    droppedLines += lines.length - MAX_LINES;
    lines = lines.slice(lines.length - MAX_LINES);
  }
}
// tail 状态文本：附丢弃提示（有丢弃时用户能看到内存保护生效）。
function tailStatus(base){
  return base + (droppedLines ? '；已丢弃最早 ' + droppedLines.toLocaleString() + ' 行' : '');
}

function hlLine(line){
  // 搜索（黄）与过滤（绿）都高亮，同时命中用橙色；区间可能交叉，
  // 收集时携带来源（1=搜索 2=过滤 3=两者），合并同段后分别着色。
  var s = searchKw.toLowerCase(), f = filterKw.toLowerCase(), l = line.toLowerCase();
  if (!s && !f) return esc(line);
  var marks = [];
  function collect(kw, tag){
    if (!kw) return;
    var j = 0;
    while (true) { var k = l.indexOf(kw, j); if (k < 0) break; marks.push([k, k + kw.length, tag]); j = k + kw.length; }
  }
  collect(s, 1); collect(f, 2);
  if (!marks.length) return esc(line);
  marks.sort(function(a, b){ return a[0] - b[0] || a[1] - b[1]; });
  var merged = [];
  for (var i = 0; i < marks.length; i++) {
    var m = merged[merged.length - 1];
    if (m && marks[i][0] < m[1]) { if (marks[i][1] > m[1]) m[1] = marks[i][1]; m[2] |= marks[i][2]; }
    else merged.push([marks[i][0], marks[i][1], marks[i][2]]);
  }
  var out = '', i = 0;
  for (var j = 0; j < merged.length; j++) {
    var cls = merged[j][2] === 2 ? ' class="mf"' : (merged[j][2] === 3 ? ' class="mb"' : '');
    out += esc(line.substring(i, merged[j][0])) + '<mark' + cls + '>' + esc(line.substring(merged[j][0], merged[j][1])) + '</mark>';
    i = merged[j][1];
  }
  return out + esc(line.substring(i));
}

function render(){
  var f = filterKw.toLowerCase(), s = searchKw.toLowerCase();
  var hits = 0, shown = 0, parts = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (f && line.toLowerCase().indexOf(f) < 0) continue;
    shown++;
    if (s) {
      var l = line.toLowerCase(), j = 0;
      while (true) { var k = l.indexOf(s, j); if (k < 0) break; hits++; j = k + s.length; }
    }
    parts.push(hlLine(line));
  }
  $('info').textContent = '显示 ' + shown + ' 行 / 共 ' + lines.length + ' 行' + (s ? ' · 搜索命中 ' + hits + ' 处' : '');
  var el = $('body');
  var autoEl = $('autoscroll');
  var stick = (!autoEl || autoEl.checked) && (el.scrollTop + el.clientHeight >= el.scrollHeight - 40);
  el.innerHTML = parts.length ? parts.join('\n') : '<span style="color:#d29922">' + (lines.length ? '（无匹配行）' : '（暂无内容）') + '</span>';
  if (stick) el.scrollTop = el.scrollHeight;
}

$('search').addEventListener('input', function(){ searchKw = this.value; scheduleRender(); });
$('filter').addEventListener('input', function(){ filterKw = this.value; scheduleRender(); });
function clearBody(){ lines = []; pending = ''; render(); }
function togglePause(){
  if (MODE !== 'tail') return;
  paused = !paused;
  $('pausebtn').textContent = paused ? '继续' : '暂停';
  setStatus(paused ? '已暂停（不再拉取新内容）' : '监听中…');
  if (!paused) poll();
}
function restart(){
  stopped = false; started = false; offset = 0;
  $('restartbtn').style.display = 'none';
  setStatus('重新开始监听…');
  poll();
}

function poll(){
  if (MODE !== 'tail' || stopped || paused) return;
  if (!started) {
    apiRead(0, 0, function(d){
      if (!d.ok) {
        stopped = true;
        setStatus('打开失败：' + (d.error === 'missing' ? '文件不存在' : (d.error || d)), true);
        $('restartbtn').style.display = '';
        return;
      }
      started = true;
      offset = d.fileSize;
      setStatus(tailStatus('监听中…（从末尾开始，当前 ' + fmtSize(d.fileSize) + '）'));
      setTimeout(poll, 500);
    });
    return;
  }
  apiRead(offset, CHUNK, function(d){
    if (stopped || paused) return;
    if (!d.ok) {
      stopped = true;
      setStatus(d.error === 'missing' ? '文件已不存在（可能被删除或轮转），可等文件重建后点「重新开始」' : '监听中断：' + (d.error || d), true);
      $('restartbtn').style.display = '';
      return;
    }
    if (d.fileSize < offset) {
      lines = []; pending = ''; droppedLines = 0;
      lines.push('──── 检测到文件被重写，从头开始读取 ────');
      offset = 0;
      render();
      setTimeout(poll, 100);
      return;
    }
    if (d.nextOffset > offset) {
      pushText(d.text);
      offset = d.nextOffset;
      render();
    }
    if (offset < d.fileSize) { setTimeout(poll, 50); return; }
    setStatus(tailStatus('监听中…（已读 ' + fmtSize(offset) + '）'));
    setTimeout(poll, 2000);
  });
}

if (MODE === 'view') {
  // 查看页是静态快照，不需要清屏（监听页保留）。
  $('clearbtn').style.display = 'none';
  // 分块读整个文件（不限大小）；首块拿到 fileSize 后，剩余块并行预取
  // （并发 3），全部到齐后一次性渲染，避免逐块串行等待。
  var bufs = [], size = 0, failed = null;
  function setStatusProgress(){
    var loaded = 0;
    for (var i = 0; i < bufs.length; i++) if (bufs[i] != null) loaded += bufs[i].length;
    setStatus('读取中… ' + fmtSize(loaded) + ' / ' + fmtSize(size));
  }
  function finish(){
    pushText(bufs.join(''));
    if (pending) { lines.push(pending); pending = ''; }
    render();
    setStatus('共 ' + fmtSize(size));
  }
  apiRead(0, CHUNK, function(d0){
    if (!d0.ok) {
      setStatus('读取失败：' + (d0.error === 'missing' ? '文件不存在' : (d0.error || d0)), true);
      render();
      return;
    }
    bufs[0] = d0.text;
    size = d0.fileSize;
    if (!d0.truncated) { finish(); return; }
    setStatusProgress();
    var offs = [];
    for (var o = CHUNK; o < size; o += CHUNK) offs.push(o);
    var done = 0, idx = 0;
    function prog(){
      done++;
      setStatusProgress();
      if (failed) { setStatus('读取失败：' + failed, true); render(); return; }
      if (done === offs.length) finish();
    }
    function launch(){
      while (idx < offs.length && idx - done < 3) {
        (function(i){
          apiRead(offs[i], CHUNK, function(d){
            if (!d.ok && !failed) failed = (d.error === 'missing' ? '文件不存在' : (d.error || '未知错误'));
            bufs[i + 1] = d.ok ? d.text : '';
            prog();
            launch();
          });
        })(idx);
        idx++;
      }
    }
    launch();
  });
} else {
  poll();
}
</script>
</body>
</html>
''';

/// 渲染文件查看/监听页面（占位替换）。
String fileViewerPageHtml(String mode) => _fileViewerTemplate
    .replaceAll('__MODE__', mode)
    .replaceAll('__TITLE__', mode == 'tail' ? '文件监听' : '文件查看');
