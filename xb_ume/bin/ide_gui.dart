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

/// 日志环形缓冲上限（内存保护）。
const int kMaxBufferLines = 5000;

final String _home =
    Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';

Future<void> main(List<String> args) async {
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
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => addDeviceLog(id, source, line));
      process.stderr
          .transform(utf8.decoder)
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
    final socket = await WebSocket.connect(uri);
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
    return completer.future.then((v) => v as Map<String, Object?>);
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
    final body = await response.transform(utf8.decoder).join();
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
      <div class="row"><b>IDE 优先级</b><button onclick="openConfig()">打开配置文件</button></div>
      <div id="ide-order" class="muted">-</div>
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
</main>
<script>
var ws = null, devices = [], selected = null, logs = [], paused = false, vmFilter = '';
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
    if (t.dataset.tab === 'daemon') refreshDaemon();
    else if (t.dataset.tab === 'sandbox') sbRefresh();
    else if (t.dataset.tab === 'routes') rtRefresh();
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
      ss.forEach(function(s){
        if (s.app) vmApps[s.source || s.uri] = s.app;
        vmUriBySource[s.source || s.uri] = s.uri; // 沙盒 Tab 用来源找 uri
        // 显示应用包名（如有），value 仍为会话来源，保证过滤匹配不变。
        var v = s.source || s.uri;
        var text = (s.app ? s.app + ' · ' : '') + v;
        html += '<option value="' + esc(v) + '" ' + (v === vmFilter ? 'selected' : '') + '>' + esc(text) + '</option>';
      });
      sel.innerHTML = html;
      var prevVmFilter = vmFilter;
      vmFilter = sel.value; // 选中会话消失时自动回退到全部
      if (vmFilter !== prevVmFilter) sbRefresh();
      sel.title = ss.map(function(s){ return (s.source || s.uri) + ' → ' + s.uri; }).join('\n') || '无已接入的调试会话（电脑上运行 flutter run 后自动接入）';
    }
    var order = d.config && d.config.ideOrder;
    document.getElementById('ide-order').textContent = (order && order.length) ? order.join(' → ') : '（默认顺序）';
  }).catch(function(){ document.getElementById('daemon-status').textContent = '查询失败（GUI 服务异常）'; var vm = document.getElementById('vmstat'); vm.style.display = ''; vm.textContent = 'VM 未知'; document.getElementById('vmsel').style.display = 'none'; });
}
setInterval(refreshDaemon, 5000);
function setVmFilter(v){ vmFilter = v; sbPath = null; renderLogs(); sbRefresh(); rtRefresh(); }

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
  var html = '<div class="sbcrumb">' + crumb + '</div>';
  if (!d.entries || !d.entries.length) { html += '<span class="muted">空目录</span>'; return html; }
  html += '<table class="sbtable"><tr><th>名称</th><th>大小</th><th>修改时间</th><th></th></tr>';
  d.entries.forEach(function(e){
    var q = encodeURIComponent(sbUri()), p = encodeURIComponent(e.path);
    var act = e.dir
      ? '<a href="/api/sandbox/downloadDir?uri=' + q + '&path=' + p + '"><button title="递归打包为 tar（无压缩）下载">下载 .tar</button></a>'
      : '<a href="/api/sandbox/download?uri=' + q + '&path=' + p + '"><button>下载</button></a>';
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
</script>
</body>
</html>
''';
