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
        Future<Map<String, Object?>?> fetchItem() async {
          final raw = await evalNet(
            "XBUmeNetworkItem? e; "
            "for (final it in XBUme.controller.network) { if (it.id == '$id') { e = it; break; } } "
            "if (e == null) return 'NOT_FOUND'; "
            "String kv(Map<String, dynamic>? m) => m == null ? '' : "
            "m.entries.map((en) => en.key + '\\u0003' + en.value.toString()).join('\\u0004'); "
            "String toS(Object? v) => v == null ? '' : v.toString(); "
            "return [kv(e.queryParameters), kv(e.requestHeaders), toS(e.requestBody), "
            "kv(e.responseHeaders), toS(e.responseBody), e.stack ?? ''].join('\\u0001'); ",
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
        final mu = await evalNet(
          "XBUmeNetworkItem? e; "
          "for (final it in XBUme.controller.network) { if (it.id == '$id') { e = it; break; } } "
          "if (e == null) return 'NOT_FOUND'; "
          "return e.method + '\\u0001' + e.url; ",
        );
        if (mu == 'NOT_FOUND') throw '请求不存在（可能已被清除）';
        final sep = mu.indexOf('\u0001');
        final method = sep < 0 ? 'GET' : mu.substring(0, sep);
        final url = sep < 0 ? mu : mu.substring(sep + 1);
        final item = await fetchItem();
        final headers = <String, String>{
          for (final h in (item?['requestHeaders'] as List? ?? <Map<String, String>>[]))
            if ((h['k'] ?? '').toString().isNotEmpty)
              h['k']!.toString(): h['v']?.toString() ?? '',
        };
        final body = (item?['requestBody'] as String? ?? '');
        final client = HttpClient();
        try {
          final rq = await client.openUrl(method, Uri.parse(url));
          headers.forEach(rq.headers.set);
          if (body.isNotEmpty &&
              method != 'GET' &&
              method != 'HEAD') {
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

  /// 每台设备一个日志流进程（所有设备并行采集，选择器只做前端过滤）。
  final Map<String, Process> _deviceLogProcesses = <String, Process>{};
  final Set<String> _deviceLogStartFailed = <String>{};
  List<Map<String, String>> devices = <Map<String, String>>[];
  String? selectedId;

  /// 日志环形缓冲（供 HTTP 导出接口读取）。
  List<Map<String, Object?>> get buffer => _buffer;

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
      for (final stream in const <String>['Stdout', 'Stderr']) {
        final key = '$uri|$stream';
        if (_vmSessions.containsKey(key)) {
          continue;
        }
        // 多个 Flutter 应用同时接入时，用会话来源（如 adb:xxx）区分输出。
        final label = (labels[uri] != null && labels[uri]!.isNotEmpty)
            ? labels[uri]!
            : uri;
        late final _VmSession session;
        session = _VmSession(
          uri,
          stream,
          stream == 'Stderr',
          (line, isStderr) => _addFlutterLine(label, line, isStderr, session),
        )..connect();
        _vmSessions[key] = session;
      }
    }
    for (final key in _vmSessions.keys.toList()) {
      if (!uris.contains(key.split('|').first)) {
        _vmSessions.remove(key)!.close();
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
    _buffer.add(entry);
    if (_buffer.length > kMaxBufferLines) {
      _buffer.removeRange(0, _buffer.length - kMaxBufferLines);
    }
    _pending.add(entry);
  }

  void _flush() {
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
    // 新客户端立即全量同步（设备 + 已缓冲日志 + 当前选中）。
    ws.add(jsonEncode(<String, Object?>{
      'type': 'snapshot',
      'devices': devices,
      'selected': selectedId,
      'items': _buffer,
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
  _VmSession(this.uri, this.streamId, this.isStderr, this.onLine);

  final String uri;

  /// 订阅的流：Stdout / Stderr（WriteEvent 无 source 字段，
  /// 只能靠分别订阅两条流区分 stdout 与 stderr）。
  final String streamId;
  final bool isStderr;
  final void Function(String line, bool isStderr) onLine;
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

/// 路径嵌入 evaluate 表达式的转义（app 端普通字符串）。
String _escPath(String p) =>
    p.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

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

/// 取路径最后一段（os 为 app 端 Platform.operatingSystem）。
String _baseName(String p, String os) {
  final sep = os == 'windows' ? r'\' : '/';
  final idx = p.lastIndexOf(sep);
  return idx < 0 ? p : p.substring(idx + 1);
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
    if (await _guiRunChecked(cli, <String>['-g', '$path:$line'])) {
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
  main { flex:1; overflow:auto; padding:16px; }
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
  .sbtable th, .sbtable td { text-align:left; padding:4px 8px; border-bottom:1px solid var(--line); }
  .sbtable th { color:var(--dim); font-weight:600; }
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
</style>
</head>
<body>
<header>
  <h1>xb_ume 工具箱</h1>
  <div class="tab active" data-tab="daemon">守护进程</div>
  <div class="tab" data-tab="logs">日志</div>
  <div class="tab" data-tab="sandbox">应用沙盒</div>
  <div class="tab" data-tab="routes">路由栈</div>
  <div class="tab" data-tab="network">Network</div>
  <div class="tab" data-tab="storage">Storage</div>
  <div id="hdr-right">
    <span id="vmstat" class="bad" style="display:none"></span>
    <select id="vmsel" style="display:none" onchange="setVmFilter(this.value)" title="选择要查看哪个调试会话（Flutter 输出来源），IDE 跳转不受影响"></select>
    <select id="hdrdev" onchange="selectDevice(this.value)"></select>
    <button onclick="refreshAll()" title="立即扫描设备并刷新调试会话状态">刷新</button>
    <div id="wsdot" title="页面连接状态"></div>
  </div>
</header>
<main>
  <section class="page active" id="page-daemon">
    <div class="card">
      <div class="row"><b>守护进程状态</b><button onclick="refreshDaemon()">刷新</button><button class="primary" onclick="restartDaemon()">重启守护进程</button></div>
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
      <input id="f-kw" placeholder="关键字过滤" oninput="renderLogs()">
      <button onclick="togglePause(this)">暂停</button>
      <button onclick="clearLogs()">清屏</button>
      <a href="/api/logs.txt" target="_blank"><button>导出</button></a>
    </div>
    <div id="logview"><span class="muted">暂无日志</span></div>
    <div class="muted" style="margin-top:6px">打印规则：未选 VM 也未选设备时不打印；选 VM 打印该会话的 Flutter 输出；选设备打印该设备的设备日志及属于该设备的 VM 输出；都选则两个源都打印（互不约束）。「设备日志」= 已连接设备的全量系统日志（logcat/hilog/iOS log）；「Flutter 输出」= 调试会话的 stdout/stderr。</div>
  </section>
  <section class="page" id="page-sandbox">
    <div id="sb-body"><span class="muted">请先选择 VM</span></div>
    <div class="muted" style="margin-top:6px">通过 VM service 读取应用进程可见的文件系统（仅 debug 模式可用）；看哪个 app 的沙盒由页头右侧的会话选择决定。文件/文件夹均可下载（文件夹为 .tar，分段流式传输，无大小限制，超大文件耗时线性增长）。</div>
  </section>
  <section class="page" id="page-routes">
    <div style="display:flex;align-items:center;gap:10px">
      <button onclick="rtRefresh()" title="重新拉取当前会话的路由栈">刷新</button>
      <span class="muted">选中会话 app 的 Navigator 路由栈（栈底 → 栈顶，当前路由高亮）</span>
    </div>
    <div id="rt-body" style="margin-top:8px"><span class="muted">请先选择 VM</span></div>
    <div class="muted" style="margin-top:6px">通过 VM service 在 app 进程内读取 Navigator 路由栈（仅 debug 模式可用）；弹窗、BottomSheet 也是路由栈的一层；路由名取 settings.name，匿名 push 的页面显示 &lt;unnamed&gt;；嵌套 Navigator 分组展示。点击行内「跳转」会用配置的 IDE 打开该页面对应的源码文件（IDE 优先级与守护进程的 IDE 跳转一致，见 config.json 的 ideOrder）。</div>
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
    <div style="display:flex;align-items:center;gap:10px">
      <select id="st-file" onchange="stLoad()" style="max-width:420px"></select>
      <button onclick="stLoad()" title="重新读取选中的 shared_prefs 文件">刷新</button>
      <input id="st-kw" placeholder="关键字过滤" oninput="stRender()" style="width:180px">
      <button onclick="stAddRow()">新增</button>
      <span class="muted">shared_preferences 存储（shared_prefs XML）</span>
    </div>
    <div id="st-body" style="margin-top:8px"><span class="muted">请先选择 VM</span></div>
    <div class="muted" style="margin-top:6px">直接读写 app 的 shared_prefs XML 文件（Android；经 VM service 写回手机）。修改/删除/新增后立即写入文件，但 shared_preferences 插件在 app 内有内存缓存——重启 app 后生效。</div>
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
    if (msg.type === 'snapshot') { devices = msg.devices; selected = msg.selected; logs = msg.items; renderHdrDev(); renderLogs(); refreshDaemon(); }
    else if (msg.type === 'devices') { devices = msg.devices; renderHdrDev(); }
    else if (msg.type === 'logs') { logs = logs.concat(msg.items); if (logs.length > 5000) logs = logs.slice(-5000); if (!paused) renderLogs(); }
    else if (msg.type === 'cleared') { logs = []; renderLogs(); }
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
  };
});
function esc(s){ var d = document.createElement('div'); d.textContent = s == null ? '' : String(s); return d.innerHTML; }
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
function renderLogs() {
  var view = document.getElementById('logview');
  var wantDevice = document.getElementById('f-src-device').checked;
  var wantFlutter = document.getElementById('f-src-flutter').checked;
  var lv = {}; document.querySelectorAll('.f-lv').forEach(function(c){ lv[c.value] = c.checked; });
  var kw = document.getElementById('f-kw').value.toLowerCase();
  var html = '';
  var dev = null;
  if (selected) { devices.forEach(function(d){ if (d.id === selected) dev = d; }); }
  var devOs = dev ? osByPlatform[dev.platform] : null;
  logs.forEach(function(l){
    var isFlutter = l.source && l.source.indexOf('flutter') === 0;
    // 过滤规则：未选 VM 也未选设备时不打印；选 VM 只看该会话的 Flutter 输出；
    // 选设备看该设备的日志及其上的 VM；都选则两个源并集（互不约束）。
    if (isFlutter) {
      if (!wantFlutter) return;
      if (vmFilter) {
        // 选了 VM：仅该会话的输出（不再要求归属于选中设备）。
        if ((l.tag || '') !== vmFilter) return;
      } else if (selected) {
        // 只选设备：仅属于该设备的 VM（来源带设备号则精确匹配，否则按平台推断）。
        var belong = (l.device && l.device === selected) ||
          (!l.device && devOs && l.os && l.os === devOs);
        if (!belong) return;
      } else {
        return;
      }
    } else {
      if (!wantDevice) return;
      if (!lv[l.level]) return;
      if (selected) {
        if ((l.device || '') !== selected) return;
      } else {
        return;
      }
    }
    if (kw && ((l.msg || '') + ' ' + (l.tag || '') + ' ' + (l.app || '')).toLowerCase().indexOf(kw) < 0) return;
    var t = l.ts || l.rcv || '';
    var src = l.source + (l.device ? '·' + l.device : '');
    html += '<div class="lv-' + (l.level || 'I') + '"><span class="muted">' + esc(t) + '</span> <span class="src">[' + esc(src) + ']</span> <span class="tag">' + esc(l.app || vmApps[l.tag] || l.tag || '') + '</span> ' + esc(l.msg) + '</div>';
  });
  view.innerHTML = html || (!vmFilter && !selected
    ? '<span class="muted">未选择 VM 或设备，不显示日志（请在页头右侧选择）</span>'
    : '<span class="muted">暂无日志</span>');
  if (!paused) view.scrollTop = view.scrollHeight;
}
function togglePause(btn){ paused = !paused; btn.textContent = paused ? '继续' : '暂停'; if (!paused) renderLogs(); }
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
    html += '<div style="margin:8px 0 2px"><b>Navigator #' + (nav.index + 1) + '</b> <span class="muted">（' + routes.length + ' 个路由）</span></div>';
    if (!routes.length) { html += '<span class="muted">空栈</span>'; return; }
    html += '<table class="sbtable"><tr><th>栈序</th><th>路由名</th><th>文件</th><th>类型</th><th>参数</th><th>定位</th></tr>';
    routes.forEach(function(r, i){
      var pos = i === 0 ? '栈底' : (i === routes.length - 1 ? '栈顶' : '');
      var name = r.name ? esc(r.name) : '<span class="muted">&lt;unnamed&gt;</span>';
      var cur = r.current ? ' <span style="color:var(--acc);font-weight:600">● 当前</span>' : '';
      var fileCell = '<td id="rtf-' + nav.index + '-' + i + '"><span class="muted">…</span></td>';
      var args = r.argsType
        ? '<span title="' + esc(r.argsType + (r.args ? ' ' + r.args : '')) + '">' + esc((r.args || '').length > 60 ? r.args.substring(0, 60) + '…' : (r.args || '空')) + ' <span class="muted">(' + esc(r.argsType) + ')</span></span>'
        : '<span class="muted">—</span>';
      var jump = '<a href="javascript:void(0)" onclick="rtJump(' + nav.index + ',' + i + ',this)" title="在 IDE 中打开该页面对应的源码文件">跳转</a>';
      html += '<tr><td>' + (i + 1) + (pos ? ' <span class="muted">' + pos + '</span>' : '') + '</td><td>' + name + cur + '</td>' + fileCell + '<td>' + esc(r.type) + '</td><td>' + args + '</td><td>' + jump + '</td></tr>';
    });
    html += '</table>';
  });
  return html;
}
function rtResolve(nav, i){
  var uri = rtUri();
  if (!uri) return;
  fetch('/api/routelocate?uri=' + encodeURIComponent(uri) + '&nav=' + nav + '&idx=' + i + '&open=0')
    .then(function(r){ return r.json(); })
    .then(function(d){
      var cell = document.getElementById('rtf-' + nav + '-' + i);
      if (!cell) return;
      if (d.error || !d.file) { cell.innerHTML = '<span class="muted" title="' + esc(d.error || '未定位到文件') + '">—</span>'; return; }
      var fileName = d.file.split('/').pop();
      var pos = fileName + (d.line ? ':' + d.line : '');
      cell.innerHTML = '<span title="' + esc(d.file + (d.className ? '（' + d.className + '）' : '')) + '">' + esc(pos) + '</span>';
    })
    .catch(function(){ var cell = document.getElementById('rtf-' + nav + '-' + i); if (cell) cell.innerHTML = '<span class="muted">—</span>'; });
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

// -- Network Tab ------------------------------------------------------------
var nwItems = [], nwDetails = {}, nwOpen = {}, nwReplays = {}, nwFetching = {};
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
    + '<a href="javascript:void(0)" onclick="nwReplay(\'' + esc(id) + '\',this)">重发</a></div>';
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
        + '</table><div style="margin:6px 0 2px"><b>响应体</b></div>' + bodyHtml + '</div>';
    }
  }
  return head + nwDetailHtml(id, d) + repHtml;
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
function stRender(){
  var body = document.getElementById('st-body');
  var kw = (document.getElementById('st-kw').value || '').toLowerCase();
  var rows = stRows.map(function(r, i){ return { r: r, i: i }; }).filter(function(x){
    return !kw || ((x.r.name || '') + ' ' + (x.r.value || '')).toLowerCase().indexOf(kw) >= 0;
  });
  var head = '<div class="muted" style="margin:2px 0">' + esc(stFile.split('/').pop()) + ' · ' + stRows.length + ' 项（'
    + (stFmt === 'ohos' ? '鸿蒙 preferences 格式' : stFmt === 'ios' ? 'iOS plist 格式' : 'Android shared_prefs 格式') + ' · 修改后点「保存写入」）</div>';
  if (stRows.length === 1 && stRows[0].type === 'raw') { body.innerHTML = head + '<pre style="white-space:pre-wrap;word-break:break-all">' + esc(stXml) + '</pre>'; return; }
  var html = '<table class="sbtable"><tr><th>key</th><th>类型</th><th>值（可直接编辑）</th><th>操作</th></tr>';
  rows.forEach(function(x){
    var r = x.r, i = x.i;
    var valHtml;
    if (r.type === 'rawios') {
      valHtml = '<span class="muted" title="iOS plist 复杂类型，保留原样">（不支持编辑）</span>';
    } else if (r.type === 'boolean') {
      valHtml = '<select onchange="stSet(' + i + ',\'value\',this.value)"><option value="true"' + (r.value === 'true' ? ' selected' : '') + '>true</option><option value="false"' + (r.value !== 'true' ? ' selected' : '') + '>false</option></select>';
    } else {
      var tip = r.type === 'set' ? 'set 类型，逗号分隔各成员' : '';
      valHtml = '<input value="' + esc(r.value).replace(/"/g, '&quot;') + '" oninput="stSet(' + i + ',\'value\',this.value)" title="' + tip + '" style="width:100%">';
    }
    html += '<tr><td><input value="' + esc(r.name) + '" oninput="stSet(' + i + ',\'name\',this.value)" style="width:100%"></td>'
      + '<td><select onchange="stSet(' + i + ',\'type\',this.value)"' + (r.type === 'rawios' || !r.isNew ? ' disabled title="类型由文件解析决定，不可修改"' : '') + '>'
      + (stFmt === 'ohos' ? ['string','boolean','int','long','float','double'] : stFmt === 'ios' ? ['string','integer','real','boolean','array'] : ['string','boolean','int','long','float','set']).map(function(t){
          return '<option' + (t === r.type ? ' selected' : '') + '>' + t + '</option>'; }).join('') + '</select></td>'
      + '<td>' + valHtml + '</td>'
      + '<td><a href="javascript:void(0)" onclick="stDel(' + i + ')" class="bad">删除</a></td></tr>';
  });
  html += '</table>';
  html += '<div style="margin-top:8px"><button onclick="stSave()">保存写入（写回手机）</button></div>';
  body.innerHTML = head + html;
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
  label.chk { color:#c9d1d9; font-size:12px; display:flex; align-items:center; gap:4px; }
  #body { flex:1 1 0; min-height:0; overflow:auto; padding:10px 14px; white-space:pre-wrap; word-break:break-all; font:12px/1.6 Menlo,monospace; }
  mark { background:#e3b341; color:#24292f; border-radius:2px; }
</style>
</head>
<body>
<header>
  <div class="row">
    <b>__TITLE__</b>
    <input type="text" id="search" placeholder="搜索（高亮，不过滤内容）">
    <input type="text" id="filter" placeholder="过滤（只保留匹配行）">
    <span id="info">-</span>
    <span id="tailbtns" style="display:none">
      <button id="pausebtn" onclick="togglePause()">暂停</button>
      <button id="restartbtn" onclick="restart()" style="display:none">重新开始</button>
      <label class="chk"><input type="checkbox" id="autoscroll" checked>自动滚动</label>
    </span>
    <button onclick="clearBody()">清屏</button>
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
if (MODE === 'tail') $('tailbtns').style.display = '';

var lines = [], pending = '';
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
}

function hlLine(line){
  var s = searchKw.toLowerCase(), l = line.toLowerCase();
  if (!s) return esc(line);
  var out = '', i = 0;
  while (true) {
    var idx = l.indexOf(s, i);
    if (idx < 0) { out += esc(line.substring(i)); break; }
    out += esc(line.substring(i, idx)) + '<mark>' + esc(line.substring(idx, idx + s.length)) + '</mark>';
    i = idx + s.length;
  }
  return out;
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
      setStatus('监听中…（从末尾开始，当前 ' + fmtSize(d.fileSize) + '）');
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
      lines = []; pending = '';
      lines.push('──── 检测到文件被重写，从头开始读取 ────');
      offset = 0;
      render();
      return;
    }
    if (d.nextOffset > offset) {
      pushText(d.text);
      offset = d.nextOffset;
      render();
    }
    if (offset < d.fileSize) { setTimeout(poll, 50); return; }
    setStatus('监听中…（已读 ' + fmtSize(offset) + '）');
  });
}

if (MODE === 'view') {
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
