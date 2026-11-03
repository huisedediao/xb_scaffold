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
import 'dart:math';
import 'dart:typed_data';

import 'src/ai/prompt.dart';
// 调试中枢：flutter run 拉起/复用 + VM service 断点与步进（「调试」Tab 的后端）。
import 'src/debug/debug_client.dart' show DebugException;
import 'src/debug/debug_hub.dart';
// 「源码下断点」面板：列项目里的 .dart 并按行读源码（只读，不做语法高亮）。
import 'src/debug/source_view.dart';
// 只取常亮命令构造器：这两个文件里的 parseAdbDevices / parseHdcTargets
// 与本文件同名的本地解析器签名不同，不能整包导入。
import 'src/device/adb.dart' show adbKeepAwakeArgs;
import 'src/device/hdc.dart' show hdcKeepAwakeArgs;
import 'src/device/run_profile.dart' show runProfileFilePath;
// 服务控制：GUI / daemon 的启停、重启与重新部署（与 bin/ide.dart 共用同一
// 份实现，避免两边各写一套进程管理、再次和 LaunchAgent 的 KeepAlive 抢实例）。
import 'src/control/log_history.dart';
import 'src/control/svc_control.dart';
import 'src/perf/perf_metrics.dart';
// 只取 VM service 地址归一：前端各处的 uri 来源不一（flutter run 输出是
// http://，daemon 会话列表是 ws://），连 WebSocket 前统一成 ws(s)。
import 'src/scenario/vm_client.dart' show normalizeVmUri;

/// GUI 服务端口基数（被占用时向后顺延最多 10 个）。
const int kGuiPortBase = 46129;

/// 当前 GUI 的访问令牌与端口。
/// Cookie 名按端口区分（浏览器 Cookie 不区分端口，多实例会互相覆盖）。
String _guiToken = '';
int _guiPort = 0;

/// 服务控制串行化：避免连点产生多个接班人 / 并发重启 daemon。
bool _svcBusy = false;
String _svcBusyAction = '';

/// GUI 启动时间（/api/svc/status 展示运行时长）。
DateTime _guiStartedAt = DateTime.now();

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

// ---------------------------------------------------------------------------
// 安全工具（纯字符串/Uri，便于单测；部署时随 ide_gui.dart 单文件走）
// ---------------------------------------------------------------------------

/// 请求体统一上限（24MB）：先按 Content-Length 拒，chunked 由读取端兜底。
const int kGuiBodyLimitBytes = 24 << 20;

/// 生成一次性 GUI 访问令牌（32 字节随机，base64url 无填充）。
String generateGuiToken() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// Host 是否为本机 GUI（允许 127.0.0.1 / localhost / [::1]，可带端口）。
///
/// DNS rebinding 会把 Host 变成攻击者域名，这里直接拒绝；端口必须与
/// 当前 GUI 一致（不带端口的形式也放行，兼容代理剥离端口的场景）。
bool isLocalGuiHost(String? host, int port) {
  if (host == null) return false;
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return false;
  const hosts = <String>['127.0.0.1', 'localhost', '[::1]', '::1'];
  for (final base in hosts) {
    if (h == base || h == '$base:$port') return true;
  }
  return false;
}

/// Origin 是否允许。null/空表示非浏览器客户端（如本地脚本），
/// 由令牌校验兜底；浏览器一定带 Origin，跨站页面会被拒绝。
bool isAllowedGuiOrigin(String? origin, int port) {
  if (origin == null || origin.trim().isEmpty) return true;
  final u = Uri.tryParse(origin.trim());
  if (u == null || u.host.isEmpty) return false;
  if (u.scheme != 'http' && u.scheme != 'https') return false;
  final host = u.host.toLowerCase();
  if (host != '127.0.0.1' && host != 'localhost' && host != '::1') {
    return false;
  }
  return u.port == port;
}

/// 定长比较，避免令牌逐字符比较的时序差异。
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  final n = x.length > y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    final xv = i < x.length ? x[i] : 0;
    final yv = i < y.length ? y[i] : 0;
    diff |= xv ^ yv;
  }
  return diff == 0;
}

/// 任意文本嵌入 VM evaluate 表达式字符串字面量的转义。
/// 注意 $ 是 Dart 字符串插值符，必须一并转义。
String escapeEvalString(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll(r'$', r'\$')
    .replaceAll("'", r"\'")
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll('\t', r'\t');

/// 路径同样是 evaluate 里的字符串字面量，直接复用完整转义。
String escapeEvalPath(String p) => escapeEvalString(p);

final RegExp _vmTokenPattern = RegExp(
  r'((?:https?|wss?)://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/)([A-Za-z0-9_\-]{16,})(?=[/\s]|$)',
  caseSensitive: false,
);

/// 把 VM service URL 里的 auth token 打码（日志缓冲/导出用）。
/// 只匹配带端口的本机 URL，避免误伤普通文件路径。
String maskVmTokens(String text) =>
    text.replaceAllMapped(_vmTokenPattern, (m) => '${m[1]}***');

/// 重放时一旦 scheme/host/port 变化，原始请求里的凭据头必须剥离。
const Set<String> sensitiveReplayHeaders = <String>{
  'authorization',
  'cookie',
  'proxy-authorization',
  'host',
  'origin',
  'referer',
  'x-api-key',
  'x-auth-token',
  'x-xsrf-token',
};

/// 重放的新旧 URL 是否跨 host（scheme/host/port 任一不同）。
/// 解析失败按“跨 host”处理，宁可多剥离凭据头。
bool replayCrossHost(String original, String next) {
  final a = Uri.tryParse(original);
  final b = Uri.tryParse(next);
  if (a == null || b == null) return true;
  if (a.scheme.toLowerCase() != b.scheme.toLowerCase()) return true;
  if (a.host.toLowerCase() != b.host.toLowerCase()) return true;
  if (a.port != b.port) return true;
  return false;
}

/// 跨 host 重放时，按“原请求里的敏感值”剥离未改动的凭据头。
/// 用户把值改成了目标环境的新 token 时保留（值不再匹配）。
Map<String, String> stripReplayHeaders(
  Map<String, String> headers,
  Iterable<String> originalSensitiveValues,
) {
  final values = originalSensitiveValues.where((v) => v.isNotEmpty).toSet();
  headers.removeWhere(
    (k, v) =>
        sensitiveReplayHeaders.contains(k.toLowerCase()) && values.contains(v),
  );
  return headers;
}

/// 把一次性访问令牌写入 0600 文件，供本地脚本/CLI 调用受保护接口。
/// Windows 没有 POSIX 权限，跳过 chmod（用户目录 ACL 由系统兜底）。
void _writeGuiTokenFile() {
  if (_guiToken.isEmpty) return;
  try {
    final dir = Directory('$_home/.xb_ume_ide');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', <String>['700', dir.path]);
      } catch (_) {}
    }
    final f = File('${dir.path}/gui.token');
    f.writeAsStringSync('$_guiToken\n');
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', <String>['600', f.path]);
      } catch (_) {}
    }
  } catch (_) {
    // 令牌文件只服务本地脚本，写失败不影响 GUI 自身用 Cookie 访问。
  }
}

/// 测试专用：注入访问令牌与端口。真实启动时由随机令牌 + 实际监听端口
/// 覆盖这两个值；测试用内存 HttpServer 直接驱动 handleRequest 时调用。
void setGuiAuthForTest(String token, int port) {
  _guiToken = token;
  _guiPort = port;
}

Future<void> main(List<String> args) async {
  // 兜底：任何流回调/事件循环里的未捕获异常只记日志，不杀进程。
  return runZonedGuarded(() => _mainImpl(args), (e, st) {
    stderr.writeln('[uncaught] $e\n$st');
  });
}

/// 取命令行参数值（`--name value`）；缺失返回 null。
String? _cliValue(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i >= 0 && i + 1 < args.length) return args[i + 1];
  return null;
}

/// 进程是否还活着（kill -0 / tasklist，不发信号）。
bool _pidAlive(int p) {
  if (p <= 0) return false;
  try {
    final r = Process.runSync('kill', <String>['-0', '$p']);
    if (r.exitCode == 0) return true;
    // kill 不存在（Windows）时落到 tasklist。
    if (r.exitCode != 0 && !Platform.isWindows) return false;
  } catch (_) {}
  try {
    final r = Process.runSync('tasklist', <String>['/FI', 'PID eq $p', '/NH']);
    return r.stdout.toString().contains('$p');
  } catch (_) {
    return false;
  }
}

/// 等旧 GUI 退出（接班人模式）；超时返回 false 但仍继续尝试 bind。
Future<bool> _waitOwnerExit(int ownerPid, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (!_pidAlive(ownerPid)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return false;
}

/// 固定端口接管：旧实例刚退出时端口可能短暂占用，重试 10s。
///
/// 固定端口的目的是让页面地址不变（浏览器不用换 URL）；拿不到就放弃，
/// 宁可让用户双击工具箱，也不要顺延到 46130 后页面还指着 46129。
Future<HttpServer?> _bindFixedPort(int port) async {
  for (var i = 0; i < 40; i++) {
    try {
      return await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      if (i == 0 && await pingGui(port)) {
        print('[xbume-gui] 端口 $port 仍被旧实例占用，放弃接班。');
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
  return null;
}

Future<void> _mainImpl(List<String> args) async {
  // 接班人模式（由 /api/svc/restart 拉起）：等旧实例退出后按固定端口接管。
  // 旧实例要先关掉全部 VM 会话再 exit（防 DDS 死锁），最长 2s；这里绝不
  // 抢在它前面 bind，否则「已有实例」分支会开个浏览器就退出。
  final restartOwner =
      int.tryParse(_cliValue(args, '--restart-owner') ?? '') ?? 0;
  final fixedPort = int.tryParse(_cliValue(args, '--port') ?? '') ?? 0;
  HttpServer? server;
  var port = fixedPort > 0 ? fixedPort : kGuiPortBase;
  if (restartOwner > 0) {
    final gone = await _waitOwnerExit(restartOwner, const Duration(seconds: 15));
    print('[xbume-gui] 接管旧实例（pid=$restartOwner，已退出=$gone）端口 $port');
  }
  if (fixedPort > 0) {
    server = await _bindFixedPort(fixedPort);
    if (server == null) {
      print('[xbume-gui] 端口 $fixedPort 未释放，放弃这次重启；请双击工具箱手动打开。');
      exitCode = 1;
      return;
    }
  } else {
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
  }
  if (server == null) {
    print('[xbume-gui] 端口 $kGuiPortBase 起 10 个均不可用，退出。');
    exitCode = 1;
    return;
  }
  print('[xbume-gui] GUI 服务已启动: http://127.0.0.1:$port （Ctrl-C 退出）');
  _guiPort = port;
  _guiStartedAt = DateTime.now();
  _guiToken = generateGuiToken();
  _writeGuiTokenFile();
  print('[xbume-gui] 本地脚本访问令牌: $_home/.xb_ume_ide/gui.token');
  _routeDebugLog('boot', 'pid=$pid port=$port routelocate=subtree',
      trace: false);
  await openBrowser(port);
  final state = GuiState();
  state.start();
  // 顶层自动化函数（assertLog / AI 增量日志上下文）共享同一份日志缓冲
  _guiLogBuffer = state.buffer;
  // 优雅退出：kill（SIGTERM）/Ctrl-C（SIGINT）/关闭终端（SIGHUP）时先
  // 关闭全部 VM 会话连接再退出。实测：持有流订阅（Stdout/Extension）的
  // 连接被硬切断后，DDS 会永久死锁（该会话此后对所有客户端无响应），必须
  // 主动 close 让 DDS 清理订阅状态；dispose 加超时兑底，避免 close 握手
  // 卡死退出。Windows 无法捕获控制台关闭事件，只能尽量在启动器侧先发
  // 终止信号；不支持的信号 watch() 会抛 SignalException，这里统一吞掉。
  Future<void> shutdown() async {
    await gracefulShutdown(state);
  }

  for (final signal in <ProcessSignal>[
    ProcessSignal.sigterm,
    ProcessSignal.sigint,
    ProcessSignal.sighup,
  ]) {
    try {
      signal.watch().first.then((_) {
        unawaited(shutdown());
      }).catchError((_) {});
    } catch (_) {
      // 当前平台不支持该信号：跳过。
    }
  }
  // 「随工具箱启动」：配置里开了就把 MCP HTTP 服务拉起来。失败只记一行日志
  // （端口被占、部署副本缺失等），不影响 GUI 本身。
  if (readMcpAutoStart()) {
    unawaited(startMcp().then((r) {
      print('[xbume-gui] MCP 自动启动：${r['message'] ?? r}');
    }));
  }
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
    // 统一安全响应头：禁止被任意网页 iframe 嵌入（点击劫持）。
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.headers.set('X-Frame-Options', 'DENY');
      req.response.headers.set('X-Content-Type-Options', 'nosniff');
      req.response.headers.set(
        'Content-Security-Policy',
        "frame-ancestors 'none'",
      );
      req.response.headers.set('Referrer-Policy', 'no-referrer');
    }
    // Host/Origin 第一层拦截：DNS rebinding 与跨站页面在这里就被拒绝。
    if (!isLocalGuiHost(req.headers.host, _guiPort)) {
      await _rejectRequest(req, HttpStatus.forbidden, 'Host 不被允许');
      return;
    }
    final origin = req.headers.value('origin');
    if (!isAllowedGuiOrigin(origin, _guiPort)) {
      await _rejectRequest(req, HttpStatus.forbidden, 'Origin 不被允许');
      return;
    }
    // Content-Length 可提前判断；chunked 由 _readBodyText 的累计上限兜底。
    if ((req.method == 'POST' || req.method == 'PUT') &&
        req.contentLength > kGuiBodyLimitBytes) {
      await _rejectRequest(
        req,
        HttpStatus.requestEntityTooLarge,
        '请求体超过 24MB 上限',
      );
      return;
    }
    if (path == '/ping') {
      req.response.write('xbume-gui');
      await req.response.close();
      return;
    }
    if (path == '/') {
      // 页面禁缓存：GUI 迭代频繁，避免浏览器磁盘缓存拿到旧版 HTML/JS。
      // 根页面负责签发 Cookie；其余路径（含 /view、/ws、/api/*）一律校验令牌。
      req.response.cookies.add(
        Cookie('xbume_gui_$_guiPort', _guiToken)
          ..httpOnly = true
          ..sameSite = SameSite.strict
          ..path = '/',
      );
      req.response.headers.set('Cache-Control', 'no-store');
      req.response.headers.contentType = ContentType.html;
      req.response.write(guiHtml.replaceAll('__XBUME_TOKEN__', _guiToken));
      await req.response.close();
      return;
    }
    if (!_isGuiAuthorized(req)) {
      await _rejectRequest(req, HttpStatus.forbidden, '未授权：请从 GUI 页面访问');
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
    if (path == '/api/version') {
      // 部署自检：GUI 是单文件部署（~/.xb_ume_ide/ide_gui.dart），出现
      // 「改了没生效」时先确认浏览器连到的是哪个脚本、哪个进程。
      final scriptPath = Platform.script.toFilePath();
      final f = File(scriptPath);
      final stat = f.existsSync() ? f.statSync() : null;
      final src = f.existsSync() ? f.readAsStringSync() : '';
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{
        'script': scriptPath,
        'mtime': stat?.modified.toIso8601String(),
        'size': stat?.size,
        'pid': pid,
        'port': _guiPort,
        'features': <String>[
          if (src.contains('fileUriToLocalPath')) 'windows-path',
          if (src.contains('_guiWindowsVscodeAppClis')) 'windows-ide',
        ],
      }));
      await req.response.close();
      return;
    }
    if (path == '/api/daemon') {
      final status = await queryDaemonStatus();
      // 合并 GUI 侧解析的应用包名（daemon 只知道 uri/source，不知道应用名）。
      final sessions = ((status?['sessions'] as List?) ?? <Object?>[]).map((s) {
        if (s is Map) {
          final uri = s['uri']?.toString();
          final app = uri == null ? null : state.appNameFor(uri);
          // 项目根也带上：「调试」页接入会话时要用它解析断点的相对路径。
          final root = uri == null ? null : state.projectRootForVmUri(uri);
          return <String, Object?>{
            ...s,
            if (app != null && app.isNotEmpty) 'app': app,
            if (root != null) 'projectRoot': root,
          };
        }
        return s;
      }).toList();
      // 会话集合变化落盘（掉选排查）：只在增/减时记一行，避免 5s 轮询噪声
      final sig = sessions
          .whereType<Map>()
          .map((s) => '${s['source'] ?? ''}|${s['fp'] ?? ''}')
          .toList()
        ..sort();
      final sigStr = sig.join(',');
      if (sigStr != _lastDaemonSessionsSig) {
        final prev = _lastDaemonSessionsSig.isEmpty
            ? <String>[]
            : _lastDaemonSessionsSig.split(',');
        final added = sig.where((e) => !prev.contains(e)).toList();
        final removed = prev.where((e) => !sig.contains(e)).toList();
        _vmSelLog('daemon',
            'running=${status != null} 会话变化 +$added -$removed 当前 ${sig.length} 个');
        _lastDaemonSessionsSig = sigStr;
      }
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
    if (path == '/api/debug/op') {
      // 调试中枢：启动/复用 flutter run + VM 断点、栈、步进、热重载。
      // GET 只读（status）；写操作走 POST JSON：{"op":"...", ...}。
      final args = <String, Object?>{};
      if (req.method == 'POST' || req.method == 'PUT') {
        try {
          final raw = await _readBodyText(req);
          final parsed = raw.isEmpty ? null : jsonDecode(raw);
          if (parsed is Map) {
            for (final e in parsed.entries) {
              args['${e.key}'] = e.value;
            }
          }
        } catch (_) {
          // 空体 / 非 JSON：按 status 处理（前端轮询也会用 GET）。
        }
      }
      for (final e in req.uri.queryParameters.entries) {
        args.putIfAbsent(e.key, () => e.value);
      }
      final op = (args['op']?.toString().trim().isNotEmpty ?? false)
          ? args['op'].toString().trim()
          : 'status';
      final result = await state.debugHub.handle(op, args);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(result));
      await req.response.close();
      return;
    }
    if (path == '/api/mcp') {
      final status = await probeMcpStatus();
      // 启停能力与自动开关随探测一起下发：卡片据此决定显示「启动」还是「停止」。
      status['autoStart'] = readMcpAutoStart();
      status['allowEval'] = readMcpAllowEval();
      status['launchable'] =
          File('$_home/.xb_ume_ide/mcp.dart').existsSync();
      final rec = readMcpPidRecord();
      if (rec['pid'] != null) status['managedPid'] = rec['pid'];
      // 凭据只在用户点「复制 MCP 配置」时下发（?token=1），常态轮询不把 token
      // 放进页面：HTTP 模式必须带它，否则客户端沿用默认配置会 401。
      if (req.uri.queryParameters['token'] == '1' && status['mode'] == 'http') {
        status['token'] = readMcpToken();
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(status));
      await req.response.close();
      return;
    }
    if (path == '/api/mcp/start' && req.method == 'POST') {
      final r = await startMcp();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(r));
      await req.response.close();
      return;
    }
    if (path == '/api/mcp/stop' && req.method == 'POST') {
      final r = await stopMcp();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(r));
      await req.response.close();
      return;
    }
    if (path == '/api/mcp/auto' && req.method == 'POST') {
      final on = (req.uri.queryParameters['on'] ?? '1') == '1';
      await writeMcpAutoStart(on);
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode(<String, Object?>{'ok': true, 'autoStart': on}),
      );
      await req.response.close();
      return;
    }
    if (path == '/api/mcp/eval' && req.method == 'POST') {
      // 只写配置：--allow-eval 是启动参数，正在跑的进程不会因此改变，
      // 前端据此提示「重启服务后生效」。「随工具箱启动」下次拉起时自动带上。
      final on = (req.uri.queryParameters['on'] ?? '1') == '1';
      await writeMcpAllowEval(on);
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode(<String, Object?>{'ok': true, 'allowEval': on}),
      );
      await req.response.close();
      return;
    }
    if (path == '/api/keepawake' && req.method == 'POST') {
      // 调试期间保持屏幕常亮（防长场景 / AI 循环中途熄屏）。
      // 只做运行时覆盖，不写系统设置、不需要 root：
      //   hdc  → power-shell timeout -o|-r（手机重启 / powmgr 重启后失效）
      //   adb  → svc power stayon true|false（仅充电时生效）
      req.response.headers.contentType = ContentType.json;
      Map<dynamic, dynamic>? body;
      try {
        final raw = await _readBodyText(req);
        final j = raw.isEmpty ? null : jsonDecode(raw);
        if (j is Map) body = j;
      } catch (_) {}
      final deviceId = (body?['deviceId'] ?? '').toString().trim();
      final on = body?['on'] == true;
      Map<String, String>? target;
      for (final d in state.devices) {
        if (d['id'] == deviceId) {
          target = d;
          break;
        }
      }
      final platform = target?['platform'] ?? '';
      if (deviceId.isEmpty || target == null ||
          (platform != 'ohos' && platform != 'android')) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': false,
          'message': deviceId.isEmpty
              ? '缺少 deviceId'
              : (target == null
                  ? '设备不在当前列表：$deviceId'
                  : '该设备不支持常亮（仅 Android / 鸿蒙）'),
        }));
        await req.response.close();
        return;
      }
      final args = platform == 'ohos'
          ? <String>[
              '-t',
              deviceId,
              ...hdcKeepAwakeArgs(on),
            ]
          : <String>['-s', deviceId, ...adbKeepAwakeArgs(on)];
      try {
        final r = await _runTool(platform == 'ohos' ? 'hdc' : 'adb', args);
        final text = '${r.stdout}\n${r.stderr}'.trim();
        final lower = text.toLowerCase();
        // hdc 的 power-shell 对不支持的子命令也返回 0，只能看输出。
        if (r.exitCode != 0 ||
            lower.contains('error') ||
            lower.contains('fail')) {
          req.response.statusCode = HttpStatus.badGateway;
          req.response.write(jsonEncode(<String, Object?>{
            'ok': false,
            'message': text.isEmpty ? '命令失败（退出码 ${r.exitCode}）' : text,
          }));
        } else {
          state.setKeepAwakeLocal(deviceId, on);
          req.response.write(jsonEncode(<String, Object?>{
            'ok': true,
            'on': on,
            'detail': text,
          }));
        }
      } catch (e) {
        req.response.statusCode = HttpStatus.badGateway;
        req.response.write(jsonEncode(<String, Object?>{'ok': false, 'message': '$e'}));
      }
      await req.response.close();
      return;
    }
    if (path == '/api/fs/dirs') {
      // 「AI 调试」页的项目目录选择器：浏览器拿不到本地绝对路径（file 选择框只给
      // 相对名），所以由后台在这台机器上列子目录，前端只负责展示与跳转。
      // 只列目录、不读文件内容；空 path 从用户主目录开始。
      final q = (req.uri.queryParameters['path'] ?? '').trim();
      req.response.headers.contentType = ContentType.json;
      try {
        final start = q.isEmpty ? _home : q;
        if (!Directory(start).existsSync()) {
          req.response.write(jsonEncode(<String, Object?>{
            'ok': false,
            'message': '目录不存在或不可读：$start',
          }));
          await req.response.close();
          return;
        }
        // 归一符号链接：macOS 的 /tmp → /private/tmp，否则来回点会攒出一串等价路径。
        final cur = Directory(start).resolveSymbolicLinksSync();
        final entries = <Map<String, Object?>>[];
        try {
          for (final e in Directory(cur).listSync(followLinks: false)) {
            if (e is! Directory) continue;
            final name = e.path.split(Platform.pathSeparator).last;
            // 隐藏目录（.git / .dart_tool / .gradle …）对挑项目根没帮助，全跳过。
            if (name.isEmpty || name.startsWith('.')) continue;
            entries.add(<String, Object?>{
              'name': name,
              'path': e.path,
              'flutter': File(
                '${e.path}${Platform.pathSeparator}pubspec.yaml',
              ).existsSync(),
            });
            if (entries.length >= 500) break;
          }
        } catch (e) {
          // 单个子目录没权限不该让整层失败：已读到的照常返回。
          _vmSelLog('fs', 'list $cur: $e');
        }
        // Flutter 项目排前面（选这个目录就是为了挑项目根），其余按名字。
        int rank(Map<String, Object?> m) => m['flutter'] == true ? 0 : 1;
        entries.sort((a, b) {
          final d = rank(a) - rank(b);
          if (d != 0) return d;
          return '${a['name']}'.toLowerCase().compareTo(
            '${b['name']}'.toLowerCase(),
          );
        });
        final up = Directory(cur).parent.path;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': true,
          'path': cur,
          'parent': up == cur ? '' : up,
          'flutter': File(
            '$cur${Platform.pathSeparator}pubspec.yaml',
          ).existsSync(),
          'entries': entries,
        }));
      } catch (e) {
        req.response.write(jsonEncode(<String, Object?>{
          'ok': false,
          'message': '$e',
        }));
      }
      await req.response.close();
      return;
    }
    if (path == '/api/fs/dartfiles') {
      // 「源码下断点」的文件候选：列项目里的 .dart（只列路径，不读内容）。
      // 只服务调试页选文件，跳过 .dart_tool / build / 隐藏目录，上限 2000 个。
      final root = (req.uri.queryParameters['root'] ?? '').trim();
      req.response.headers.contentType = ContentType.json;
      try {
        if (root.isEmpty) throw DebugException('缺少项目根 root');
        final files = listDartFiles(root);
        req.response.write(jsonEncode(<String, Object?>{
          'ok': true,
          'root': Directory(root).resolveSymbolicLinksSync(),
          'files': files,
        }));
      } catch (e) {
        req.response.write(jsonEncode(<String, Object?>{
          'ok': false,
          'message': debugErrorText(e),
        }));
      }
      await req.response.close();
      return;
    }
    if (path == '/api/fs/file') {
      // 读某个 .dart 的源码行：给「点行号下断点」与「单步跟随当前帧」用，只读、不搜、不监听。
      // - `root` + `path`：项目内的文件（相对项目根）；
      // - `path=package:...`：依赖包 / Flutter SDK（按项目 package_config 解析）；
      // - `abs`：项目外的绝对路径，与上一条一样只读展示、不许下断点。
      final q = req.uri.queryParameters;
      final root = (q['root'] ?? '').trim();
      final rel = (q['path'] ?? '').trim();
      final abs = (q['abs'] ?? '').trim();
      req.response.headers.contentType = ContentType.json;
      try {
        SourceFileView view;
        if (abs.isNotEmpty) {
          view = readSourceFileOutside(abs);
        } else if (rel.startsWith('package:')) {
          final local = resolvePackageSourcePath(rel, root);
          if (local == null) {
            throw DebugException('找不到依赖包源码：$rel（先在项目里跑一次 flutter pub get）');
          }
          view = readSourceFileOutside(local);
        } else {
          view = readSourceFile(root, rel);
        }
        req.response.write(jsonEncode(<String, Object?>{
          'ok': true,
          ...view.toJson(),
        }));
      } catch (e) {
        req.response.write(jsonEncode(<String, Object?>{
          'ok': false,
          'message': debugErrorText(e),
        }));
      }
      await req.response.close();
      return;
    }
    if (path == '/api/ai/config') {
      final cfg = _guiReadConfigRaw();
      final recent = <String>[
        for (final e in (cfg['aiRecentDirs'] as List? ?? const <Object?>[]))
          if ('$e'.trim().isNotEmpty) '$e'.trim(),
      ];
      // 桌面端不在设备发现结果里（发现只扫 adb/hdc/simctl/idevice），但它是
      // AI 调试最常用的目标：`flutter run -d macos` / `-d windows`。
      final devs = <Map<String, String>>[...state.devices];
      final desktop = Platform.isMacOS
          ? <String, String>{
              'id': 'macos',
              'name': 'macOS 桌面',
              'state': '本机',
              'platform': 'macos',
            }
          : Platform.isWindows
              ? <String, String>{
                  'id': 'windows',
                  'name': 'Windows 桌面',
                  'state': '本机',
                  'platform': 'windows',
                }
              : null;
      if (desktop != null && !devs.any((d) => d['id'] == desktop['id'])) {
        devs.add(desktop);
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{
        'projectDir': cfg['aiProjectDir'] ?? '',
        'device': cfg['aiDevice'] ?? '',
        // 候选项：当前调试会话反推的项目根 + 最近用过的目录。
        'sessionDirs': state.sessionProjectRoots,
        'recentDirs': recent,
        'devices': devs,
        'selectedDevice': state.selectedId ?? '',
      }));
      await req.response.close();
      return;
    }
    if (path == '/api/ai/setup' && req.method == 'POST') {
      final r = await _aiSetup(await _readBodyText(req));
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(r));
      await req.response.close();
      return;
    }
    if (path == '/api/clientlog' && req.method == 'POST') {
      // 前端事件上报（会话选择链路排障）：{tag,msg} → vm_sel.log
      try {
        final body = await _readBodyText(req);
        final j = body.isEmpty ? null : jsonDecode(body);
        if (j is Map && j['msg'] != null) {
          _vmSelLog('web', '${j['tag'] ?? ''} ${j['msg']}');
        }
      } catch (_) {}
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': true}));
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
    // 服务控制（顶栏「服务」菜单）：GUI / daemon 的启停与重启。
    // 变更类操作走 POST；status / log 只读，用 GET 不会误触发副作用。
    if (path == '/api/svc/status') {
      await _writeJson(req, await svcStatusSnapshot());
      return;
    }
    if (path == '/api/svc/log') {
      await _writeJson(req, readInstallLog(req.uri.queryParameters['offset']));
      return;
    }
    if (path.startsWith('/api/svc/') && req.method == 'POST') {
      await handleSvcAction(state, req, path.substring('/api/svc/'.length));
      return;
    }
    if (path == '/api/openconfig' && req.method == 'POST') {
      // file=run 打开项目运行配置（预启动命令 / 额外参数 / 停止清理）；
      // 文件不存在时先建一个空壳，避免系统编辑器打开失败。
      final which = req.uri.queryParameters['file'] ?? '';
      var target = '$_home/.xb_ume_ide/config.json';
      if (which == 'run') {
        target = runProfileFilePath();
        final f = File(target);
        if (!f.existsSync()) {
          f.parent.createSync(recursive: true);
          f.writeAsStringSync('{\n  "version": 1,\n  "projects": {}\n}\n');
        }
      }
      await openWithSystemApp(target);
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();
      return;
    }
    if (path == '/api/ideorder' && req.method == 'GET') {
      // 进入「守护进程」页时调用：只扫描/合并不落盘（GET 无副作用）。
      // 前端收到 added/removed 后再用 POST 保存；只追加，不删已卸载的，
      // daemon 唤起时自会跳过。
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
        final body = await _readBodyText(req, lenient: true);
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
        // 导出前二次打码：避免 VM service token 随日志外泄。
        final msg = maskVmTokens('${entry['msg']}');
        req.response.write(
          '$time [${entry['source']}] '
          '${entry['level']}/${entry['app'] ?? entry['tag']}: $msg\n',
        );
      }
      await req.response.close();
      return;
    }
    // -- 日志历史分页（JSON） -------------------------------------------------
    // /api/logs.txt 是整包导出（人工看），这里是给 AI / 脚本的：关键字、来源、
    // 时间窗过滤 + 两个游标（nextOffset 翻页、nextSinceMs 增量），一行都不用少。
    if (path == '/api/logs') {
      final page = queryGuiLog(
        state.buffer,
        GuiLogQuery(
          keyword: req.uri.queryParameters['keyword'],
          source: req.uri.queryParameters['source'],
          sinceMs: int.tryParse(req.uri.queryParameters['sinceMs'] ?? ''),
          offset: int.tryParse(req.uri.queryParameters['offset'] ?? '0') ?? 0,
          limit: (int.tryParse(req.uri.queryParameters['limit'] ?? '') ?? 200)
              .clamp(1, 1000),
          tail: (req.uri.queryParameters['tail'] ?? '1') != '0',
          maxChars: (int.tryParse(req.uri.queryParameters['maxChars'] ?? '') ?? 400)
              .clamp(40, 4000),
        ),
      );
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode(<String, Object?>{
          'ok': true,
          'total': page.total,
          'count': page.items.length,
          // 与 /api/logs.txt 一致：VM service token 不外泄。
          'items': <Object?>[
            for (final item in page.items)
              <String, Object?>{
                ...item,
                if (item['msg'] != null) 'msg': maskVmTokens('${item['msg']}'),
              },
          ],
          'nextOffset': page.nextOffset,
          'hasMore': page.hasMore,
          'nextSinceMs': page.nextSinceMs,
          'sources': page.sources,
        }),
      );
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
      final sw = Stopwatch()..start();
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
        final routeCount = navigators.fold<int>(
            0, (n, m) => n + ((m['routes'] as List?)?.length ?? 0));
        _routeDebugLog('routestack',
            'port=${_vmPortTag(uri)} navs=${navigators.length} routes=$routeCount ms=${sw.elapsedMilliseconds}');
      } catch (e) {
        _routeDebugLog('routestack',
            'port=${_vmPortTag(uri)} error=${_oneLine(e)} ms=${sw.elapsedMilliseconds}');
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
      final sw = Stopwatch()..start();
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
                // 转场/构建过程中调用 pop/push 会触发 Navigator 断言，_debugLocked
                // 是它与自身导航操作互斥的现成标记（debug 模式 eval 可见）。
                "if (navigators[$nav]._debugLocked) return 'BUSY'; "
                "final h = navigators[$nav]._history; "
                "if ($idx < 0 || $idx >= h.length) return 'BAD_IDX'; "
                "if ($idx != h.length - 1) return 'NOT_TOP'; "
                "navigators[$nav].pop(); return 'OK'; })()";
          case 'remove':
            expr = "(() { $walk"
                "if ($nav < 0 || $nav >= navigators.length) return 'BAD_NAV'; "
                "if (navigators[$nav]._debugLocked) return 'BUSY'; "
                "final h = navigators[$nav]._history; "
                "if ($idx < 0 || $idx >= h.length) return 'BAD_IDX'; "
                // 栈里只剩一条（初始路由）时不允许移除，避免整窗白屏。
                "if (h.length <= 1) return 'LAST_ROUTE'; "
                "navigators[$nav].removeRoute(h[$idx].route); return 'OK'; })()";
          default: // push（入口已校验 name 非空）
            final escName = _escEvalString(name);
            expr = "(() { $walk"
                "if ($nav < 0 || $nav >= navigators.length) return 'BAD_NAV'; "
                "if (navigators[$nav]._debugLocked) return 'BUSY'; "
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
        _routeDebugLog('routeop',
            'port=${_vmPortTag(uri)} op=$op nav=$nav idx=$idx name=${name.isEmpty ? '-' : name} -> $reply ms=${sw.elapsedMilliseconds}');
      } catch (e) {
        _routeDebugLog('routeop',
            'port=${_vmPortTag(uri)} op=$op nav=$nav idx=$idx error=${_oneLine(e)} ms=${sw.elapsedMilliseconds}');
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
              "if (s != null && s.runtimeType.toString() == '${_escEvalString(cls)}') { n++; } "
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
                final inner =
                    n.substring(n.indexOf('<') + 1, n.lastIndexOf('>'));
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
                    (set['instances'] as List? ?? const <Object?>[])
                        .isNotEmpty) {
                  instId = ((set['instances'] as List).first as Map)['id']
                          ?.toString() ??
                      '';
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
                  final fname = ((f['decl'] as Map?)?['name'] ?? '').toString();
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
                              (e['class'] as Map?)?['name']?.toString() !=
                                  'Null')
                          .length;
                    } catch (_) {
                      listeners = -1;
                    }
                  } else if (fname == '_count') {
                    final n =
                        int.tryParse(v['valueAsString']?.toString() ?? '');
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
                        (v['class'] as Map?)?['name']?.toString() ??
                        '?';
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
    // -- 路由的 State / XBVM / ChangeNotifier 解析 --------------------------
    // 纯静态解析（不再连 VM）：routelocate 已定位到路由子树中第一个用户
    // widget 类的源文件，State 名取该类 createState() 的返回类型；
    // VM 名取 widget 声明处泛型实参（extends XBPage<HomeVM>）、generateVM
    // 的返回类型/构造调用、State 字段与 Provider 泛型实参；其余沿 extends
    // 链能到 ChangeNotifier 的类型归入 Notifier（仅搜本机项目源码）。
    if (path == '/api/routeinfo') {
      final file = req.uri.queryParameters['file'] ?? '';
      final cls = req.uri.queryParameters['class']?.trim() ?? '';
      if (file.isEmpty || cls.isEmpty || !File(file).existsSync()) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      String state = '';
      List<String> vmList = const <String>[];
      List<String> cnList = const <String>[];
      try {
        (state, vmList, cnList) = _routeStateAndNotifier(file, cls);
      } catch (_) {}
      // 每个类的声明位置：断点卡片的路由栈小节要“点名字就在下方源码面板
      // 打开并定位”（点行号即下断点）。只有名字没法开文件，所以一并给出。
      var loc = const <String, Map<String, Object?>>{};
      try {
        loc = _classLocations(file, cls, state, vmList, cnList);
      } catch (_) {}
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{
        'ok': true,
        'widget': cls,
        'state': state,
        'vm': vmList,
        'cn': cnList,
        'loc': loc,
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
      final sw = Stopwatch()..start();
      // 诊断中间值提到 try 外：失败日志要能区分「项目根找错」「包根没读到」
      // 与「库确实不在本机」，否则只能看到一句笼统的未解析。
      String? projectRoot;
      var fileUris = const <String>[];
      var lastLibUri = '';
      var scanned = 0;
      var framework = 0;
      try {
        // 第 1 步：收集该路由子树的候选 widget（浅→深；单行 IIFE）。
        // 只从该路由自己的 ModalRoute.subtreeContext 往下扫，不再用
        // ModalRoute.of(e) 遍历整棵树：后者会给树里每个 Element 注册
        // _ModalScopeStatus 依赖（相当于让全树的 didChangeDependencies
        // 在每次路由状态变化时被触发），可能诱发业务代码在构建/转场期间
        // 执行导航或换桶，出现 framework 的「check that it really is our
        // descendant」断言（UnmanagedRestorationScope.notifyClients）。
        final expr =
            "(() { final root = WidgetsBinding.instance.renderViewElement; "
            "if (root == null) return 'NO_ROOT'; "
            "final navigators = <NavigatorState>[]; "
            "void walkN(Element e) { final w = e.widget; "
            "if (w is Navigator && e is StatefulElement && e.state is NavigatorState) { navigators.add(e.state as NavigatorState); } "
            "e.visitChildren(walkN); } "
            "root.visitChildren(walkN); "
            "if ($nav < 0 || $nav >= navigators.length) return 'BAD_NAV'; "
            "final h = navigators[$nav]._history; "
            "if ($idx < 0 || $idx >= h.length) return 'BAD_IDX'; "
            "final route = h[$idx].route; "
            "if (route is! ModalRoute) return 'NO_SUBTREE'; "
            "final ctx = route.subtreeContext; "
            "if (ctx is! Element || !ctx.mounted) return 'NO_SUBTREE'; "
            "final cands = <Widget>[]; "
            "void walk(Element e) { cands.add(e.widget); e.visitChildren(walk); } "
            "walk(ctx); "
            "return cands.length > 250 ? cands.sublist(0, 250) : cands; })()";
        final libId =
            await rpc.libraryId('package:flutter/src/widgets/navigator.dart');
        final isoId = await rpc.isolateId();
        final listRes = await rpc.rawRpc('evaluate', {
          'isolateId': isoId,
          'targetId': libId,
          'expression': expr,
        });
        final listKind = listRes['kind']?.toString();
        if (listKind == 'String') {
          // NO_ROOT / BAD_NAV / BAD_IDX / NO_SUBTREE：直接作为错误提示。
          final why = listRes['valueAsString']?.toString() ?? '定位失败';
          _routeDebugLog('routelocate',
              'port=${_vmPortTag(uri)} nav=$nav idx=$idx open=${open ? 1 : 0} -> $why ms=${sw.elapsedMilliseconds}');
          throw why;
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
        fileUris = ((iso['libraries'] as List? ?? <Object?>[])
                .whereType<Map>()
                .map((l) => l['uri']?.toString() ?? '')
                .where((u) => u.startsWith('file:///'))
                .toList())
            .cast<String>();
        projectRoot = projectRootForLibraries(fileUris);
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
          lastLibUri = libUri;
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
          _routeDebugLog('routelocate',
              'port=${_vmPortTag(uri)} nav=$nav idx=$idx open=${open ? 1 : 0} -> $clsName ($file:$line) scanned=$scanned fw=$framework ms=${sw.elapsedMilliseconds}');
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
        if (scanned == 0) {
          throw '未找到该路由的页面元素（路由可能尚未构建完成）';
        }
        if (projectRoot == null) {
          throw '无法定位：未能从 VM 的库列表推断项目根（release 包或纯 AOT 调试不支持）';
        }
        if ((_pkgRootsCache[projectRoot]?.length ?? 0) == 0) {
          throw '无法定位：$projectRoot 下没有读到 .dart_tool/package_config.json（确认该目录执行过 flutter pub get）';
        }
        throw '无法定位：扫描 $scanned 个候选类（其中框架类 $framework 个），均未解析到本机文件（最近一个：$lastLibUri）';
      } catch (e, st) {
        stderr.writeln('[routelocate] $e\n$st');
        _routeDebugLog(
            'routelocate',
            'port=${_vmPortTag(uri)} nav=$nav idx=$idx open=${open ? 1 : 0} error=${_oneLine(e)} ms=${sw.elapsedMilliseconds}'
                ' root=${projectRoot ?? '-'}'
                ' cfg=${projectRoot != null && File('$projectRoot/.dart_tool/package_config.json').existsSync()}'
                ' pkg=${projectRoot == null ? 0 : (_pkgRootsCache[projectRoot]?.length ?? 0)}'
                ' libs=${fileUris.length}'
                ' lastLib=${lastLibUri.isEmpty ? '-' : lastLibUri}'
                ' scanned=$scanned fw=$framework');
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
          (path != '/api/network' &&
              path != '/api/network/clear' &&
              id.isEmpty)) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      // clear/replay 有副作用，只允许 POST：避免 <img>/跨站表单直接触发。
      if ((path == '/api/network/clear' || path == '/api/network/replay') &&
          req.method != 'POST') {
        req.response.statusCode = HttpStatus.methodNotAllowed;
        req.response.headers.set('Allow', 'POST');
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': '该接口仅支持 POST'}));
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
              'id': p[0],
              'time': p[1],
              'method': p[2],
              'url': p[3],
              'statusCode': p[4],
              'durationMs': p[5],
              'status': p[6],
              'error': p[7],
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
              "(v is Map || v is List ? js(v) : v.toString()); "
              // 动态取发起位置字段：兼容未升级的 app 端（旧版无该字段，
              // 直接静态访问会编译失败，dynamic + try/catch 降级为空）。
              "String initi(dynamic e) { try { return e.initiator ?? ''; } catch (_) { return ''; } } "
              "String initiStack(dynamic e) { try { return e.initiatorStack ?? ''; } catch (_) { return ''; } } ";
          final raw = await evalNet(
            "$jsHelpers"
            "XBUmeNetworkItem? e; "
            "for (final it in XBUme.controller.network) { if (it.id == '${_escEvalString(id)}') { e = it; break; } } "
            "if (e == null) return 'NOT_FOUND'; "
            "String kv(Map<String, dynamic>? m) => m == null ? '' : "
            "m.entries.map((en) => en.key + '\u0003' + en.value.toString()).join('\u0004'); "
            "return [kv(e.queryParameters), kv(e.requestHeaders), toS(e.requestBody), "
            "kv(e.responseHeaders), toS(e.responseBody), e.stack ?? '', "
            "initi(e), initiStack(e)].join('\u0001'); ",
          );
          if (raw == 'NOT_FOUND') return null;
          final p = raw.split('\u0001');
          List<Map<String, String>> parseKv(String s) => s.isEmpty
              ? <Map<String, String>>[]
              : s.split('\u0004').map((e) {
                  final i = e.indexOf('\u0003');
                  return <String, String>{
                    'k': i < 0 ? e : e.substring(0, i),
                    'v': i < 0 ? '' : e.substring(i + 1),
                  };
                }).toList();
          final initiatorStack = p.length > 7 ? p[7] : '';
          final initiatorFrames = initiatorStack
              .split('\n')
              .where((line) => line.trim().isNotEmpty)
              .map(_excParseFrame)
              .toList();
          return <String, Object?>{
            'query': parseKv(p.isNotEmpty ? p[0] : ''),
            'requestHeaders': parseKv(p.length > 1 ? p[1] : ''),
            'requestBody': p.length > 2 ? p[2] : '',
            'responseHeaders': parseKv(p.length > 3 ? p[3] : ''),
            'responseBody': p.length > 4 ? p[4] : '',
            'stack': p.length > 5 ? p[5] : '',
            'initiator': p.length > 6 ? p[6] : '',
            'initiatorFrames': initiatorFrames,
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
        // 仅接受 POST（GET 重放会被 <img>/跨站表单触发）；body 可覆盖
        // url/headers/body；URL 跨 host 时剥离原请求的凭据头。
        Map<String, Object?>? edit;
        if (req.method == 'POST') {
          final raw = await _readBodyText(req);
          if (raw.isNotEmpty) edit = jsonDecode(raw) as Map<String, Object?>;
        }
        final mu = await evalNet(
          "XBUmeNetworkItem? e; "
          "for (final it in XBUme.controller.network) { if (it.id == '${_escEvalString(id)}') { e = it; break; } } "
          "if (e == null) return 'NOT_FOUND'; "
          "return e.method + '\u0001' + e.url; ",
        );
        if (mu == 'NOT_FOUND') throw '请求不存在（可能已被清除）';
        final sep = mu.indexOf('\u0001');
        final method = sep < 0 ? 'GET' : mu.substring(0, sep);
        var url = sep < 0 ? mu : mu.substring(sep + 1);
        final item = await fetchItem();
        var headers = <String, String>{
          for (final h
              in (item?['requestHeaders'] as List? ?? <Map<String, String>>[]))
            if ((h['k'] ?? '').toString().isNotEmpty)
              h['k']!.toString(): h['v']?.toString() ?? '',
        };
        var body = (item?['requestBody'] as String? ?? '');
        if (edit != null) {
          final eu = edit['url']?.toString().trim() ?? '';
          final eh = edit['headers'];
          final crossHost =
              eu.isNotEmpty && eu != url && replayCrossHost(url, eu);
          if (eu.isNotEmpty && eu != url) {
            final next = Uri.tryParse(eu);
            if (next == null || !next.hasScheme || next.host.isEmpty) {
              throw 'URL 不合法：$eu';
            }
            url = eu;
          }
          if (eh is Map) {
            headers = {
              for (final e in eh.entries)
                e.key.toString(): e.value?.toString() ?? '',
            };
            if (crossHost) {
              // 编辑重放时前端会把原 headers 预填回表单；跨 host 下值没改的
              // 凭据头仍按“原样外发”处理，这里按原值匹配后剥离。用户改成
              // 新值（例如目标环境的 token）则保留。
              final originalSensitiveValues =
                  (item?['requestHeaders'] as List? ?? <Object?>[])
                      .whereType<Map>()
                      .where((h) => sensitiveReplayHeaders
                          .contains((h['k'] ?? '').toString().toLowerCase()))
                      .map((h) => (h['v'] ?? '').toString())
                      .toList();
              stripReplayHeaders(headers, originalSensitiveValues);
            }
          } else if (crossHost) {
            headers.removeWhere(
              (k, _) => sensitiveReplayHeaders.contains(k.toLowerCase()),
            );
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
            rq.headers
                .set('content-length', utf8.encode(body).length.toString());
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
    // -- Storage 刷新 app 内缓存（shared_preferences reload）：改过文件后让
    // app 重新读一次存储，不重启也能读到新值（平台层仍缓存时无效）----------
    if (path == '/api/storage/reload') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      if (uri.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      final rpc = _SandboxRpc(uri);
      try {
        final inst = await _findSharedPrefsInstance(rpc);
        if (inst == null) {
          throw 'app 内没有 SharedPreferences 实例（app 尚未读写过 preferences？）';
        }
        final ok = await _reloadSharedPrefs(rpc, inst);
        if (!ok) {
          throw '该实例没有 reload()/reloadCache()'
              '（SharedPreferencesAsync 无缓存，无需刷新）';
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final iso = await rpc.isolateId();
        final r = await rpc.rawRpc('evaluate', {
          'isolateId': iso,
          'targetId': inst,
          'expression': 'getKeys().length',
        });
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': true,
          'keys': int.tryParse(r['valueAsString']?.toString() ?? ''),
        }));
        await req.response.close();
      } catch (e, st) {
        stderr.writeln('[$path] $e\n$st');
        req.response.statusCode = HttpStatus.badGateway;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      } finally {
        await rpc.close();
      }
      return;
    }
    // -- Storage（shared_prefs XML 直读直写；保存时可经 app 内 API 立即生效）--
    if (path == '/api/storage/list' ||
        path == '/api/storage/read' ||
        path == '/api/storage/write') {
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
        ))
            .trim();
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
          // 真机/模拟器上 Platform.environment['HOME'] 可能为空（iOS 不注入
          // HOME），退回 Directory.systemTemp（<sandbox>/tmp）的父目录。
          home = (await rpc.evalString(
            "(() { final h = Platform.environment['HOME'] ?? ''; "
            'if (h.isNotEmpty) return h; '
            'return Directory.systemTemp.parent.path; })()',
          ))
              .trim();
          if (home.isEmpty) throw '无法获取 app 沙盒 HOME（iOS）';
          prefsDirs = <String>['$home/Library/Preferences'];
          ext = '.plist';
        } else {
          prefsDirs = <String>['/data/data/$pkg/shared_prefs'];
          ext = '.xml';
        }
        final dirList = prefsDirs.map((d) => "'${_escPath(d)}'").join(',');
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
                '-convert',
                'xml1',
                '-o',
                tmpXml,
                tmpBin.path,
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
              try {
                await tmpBin.delete();
              } catch (_) {}
              try {
                await File(tmpXml).delete();
              } catch (_) {}
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
        // write：body 为 JSON {xml, dirty}（新前端）；纯 XML 全文（旧前端）也兼容。
        // 先写文件（临时文件 + 分块 + rename），再尝试经 app 内 SharedPreferences
        // API 同步改动项——Dart 缓存与原生存储一起更新，保存后立即生效。
        final raw = await _readBodyText(req, lenient: true);
        var xml = raw;
        var dirty = <Map>[];
        if (raw.trimLeft().startsWith('{')) {
          final j = jsonDecode(raw);
          if (j is Map) {
            xml = (j['xml'] ?? '').toString();
            final ds = j['dirty'];
            if (ds is List) dirty = ds.whereType<Map>().toList();
          }
        }
        if (xml.isEmpty) throw '写入内容为空';
        List<int> bytes;
        if (os == 'ios') {
          // XML plist → 本机 plutil 转 binary plist → 字节写回。
          final tmpXml = File(
            '${Directory.systemTemp.path}/xbume_pref_'
            '${DateTime.now().microsecondsSinceEpoch}.xml',
          );
          final tmpBin = '${tmpXml.path}.bplist';
          try {
            await tmpXml.writeAsString(xml);
            final pr = await Process.run('plutil', <String>[
              '-convert',
              'binary1',
              '-o',
              tmpBin,
              tmpXml.path,
            ]);
            if (pr.exitCode != 0) {
              throw 'plutil 转换失败（XML plist 可能非法）：${pr.stderr}';
            }
            bytes = await File(tmpBin).readAsBytes();
          } finally {
            try {
              await tmpXml.delete();
            } catch (_) {}
            try {
              await File(tmpBin).delete();
            } catch (_) {}
          }
        } else {
          bytes = utf8.encode(xml);
        }
        await _writeAppFileBytes(rpc, file, bytes);
        // 立即生效：经 app 内实例把改动项写回（找不到实例时 live=null）。
        Map<String, Object?>? live;
        Object? liveError;
        try {
          live = await _sharedPrefsLiveSync(rpc, dirty);
        } catch (e) {
          liveError = e.toString();
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': true,
          'bytes': bytes.length,
          'live': live,
          'liveError': liveError,
        }));
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
      String listExpr(String d) => "(() { final sb = StringBuffer(); "
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
          final quoted = candidates.map((c) => "'${_escPath(c)}'").join(',');
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
          roots = rootsRaw.split('\n').where((l) => l.isNotEmpty).toList();
          if (roots.isNotEmpty) {
            listing = await rpc.evalString(listExpr(roots.first));
          }
        } else {
          listing = await rpc.evalString(listExpr(dir));
        }
        final actualRoot =
            dir.isEmpty ? (roots.isEmpty ? '' : roots.first) : dir;
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
      final offset =
          int.tryParse(req.uri.queryParameters['offset'] ?? '0') ?? 0;
      final max = int.tryParse(req.uri.queryParameters['max'] ?? '0') ?? 0;
      if (uri.isEmpty ||
          target.isEmpty ||
          offset < 0 ||
          max < 0 ||
          max > (1 << 21)) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(
          <String, Object?>{
            'ok': false,
            'error': 'bad request（参数不合法或单次请求超 1MB）'
          },
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
          final bytes =
              dataRaw.isEmpty ? <int>[] : gzip.decode(base64.decode(dataRaw));
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
      } finally {
        // 必须显式关闭：该端点被监听页按 50ms~2s 轮询，不关会持续泄漏
        // WebSocket（本地与 app 进程两侧各占一个 fd）。
        await rpc.close();
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
        req.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      } finally {
        await rpc.close();
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
          jsonEncode(<String, Object?>{
            'ok': false,
            'error': 'bad request（uri/path 必填）'
          }),
        );
        await req.response.close();
        return;
      }
      Map<String, Object?> body;
      try {
        final raw = await _readBodyText(req);
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
          jsonEncode(
              <String, Object?>{'ok': false, 'error': 'b64 字段不是合法 base64'}),
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
        for (var off = 0; off < bytes.length || off == 0; off += chunk) {
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
        req.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      } finally {
        await rpc.close();
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
      final rpc = _SandboxRpc(uri);
      try {
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
      } finally {
        await rpc.close();
      }
      return;
    }
    // ── 性能指标：Dart 堆/外部内存、进程内存构成、isolate CPU 采样 ──
    if (path == '/api/perf' && req.method == 'GET') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      if (uri.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }
      // 采样窗口：前端按刷新间隔传入，限制在 0.5–5 秒，避免一次拉回过多样本。
      final windowMs =
          (int.tryParse(req.uri.queryParameters['windowMs'] ?? '') ?? 2000)
              .clamp(500, 5000)
              .toInt();
      final windowUs = windowMs * 1000;
      final rpc = _SandboxRpc(uri);
      try {
        final iso = await rpc.isolateId();
        final vm = rpc.vm ?? const <String, Object?>{};
        final isolates = vm['isolates'];
        final payload = <String, Object?>{
          'ok': true,
          'ts': DateTime.now().millisecondsSinceEpoch,
          'windowMs': windowMs,
          'vm': <String, Object?>{
            'name': vm['name']?.toString() ?? '',
            'os': vm['operatingSystem']?.toString() ?? '',
            'version': vm['version']?.toString() ?? '',
            'isolates': isolates is List ? isolates.length : 0,
          },
        };
        // Dart 堆内存（heapUsage/heapCapacity）与堆外内存。
        try {
          final mem = await rpc.rawRpc('getMemoryUsage', {'isolateId': iso});
          payload['heap'] = <String, Object?>{
            'used': (mem['heapUsage'] as num?)?.toInt() ?? 0,
            'capacity': (mem['heapCapacity'] as num?)?.toInt() ?? 0,
            'external': (mem['externalUsage'] as num?)?.toInt() ?? 0,
          };
        } catch (e) {
          payload['heapError'] = e.toString();
        }
        // 进程内存构成（部分平台/VM 版本不支持，失败不影响其余指标）。
        try {
          final proc = await rpc.rawRpc('getProcessMemoryUsage');
          payload['process'] = perfProcessMemory(proc);
        } catch (e) {
          payload['processError'] = e.toString();
        }
        // CPU：取 VM 单调时钟窗口内的采样数 × 采样周期作为忙时占比。
        // 部分平台的 flutter run 不给引擎传 --enable-dart-profiling（实测 OHOS
        // 用 `aa start` 启动，不带引擎参数），此时 getCpuSamples 报
        // 「Profiler is disabled」。debug 构建可在运行时用 setFlag 打开采样后
        // 重试一次；product 构建会被拒，保持只读失败提示。
        try {
          final now = await rpc.rawRpc('getVMTimelineMicros');
          final nowUs = (now['timestamp'] as num?)?.toInt() ?? 0;
          if (nowUs <= 0) throw '无法读取 VM 单调时钟';
          Map<String, Object?> window() => <String, Object?>{
                'isolateId': iso,
                'timeOriginMicros': nowUs - windowUs,
                'timeExtentMicros': windowUs,
              };
          Map<String, Object?> samples;
          try {
            samples = await rpc.rawRpc('getCpuSamples', window());
          } catch (e) {
            if (!e.toString().contains('Profiler is disabled')) rethrow;
            try {
              await rpc.rawRpc('setFlag',
                  <String, Object?>{'name': 'profiler', 'value': 'true'});
            } catch (e2) {
              throw '该构建未开启 CPU 采样（运行时开启失败：$e2）';
            }
            payload['cpuAutoEnabled'] = true;
            samples = await rpc.rawRpc('getCpuSamples', window());
          }
          payload['cpu'] = perfCpuFromSamples(samples);
        } catch (e) {
          final err = e.toString();
          payload['cpuError'] = err.contains('Profiler is disabled')
              ? '该构建未开启 CPU 采样，无法获取 CPU'
              : err;
        }
        // 进程级 CPU / footprint（与 Xcode 调试导航器同口径）：由 app 端
        // xb_ume 注册的 ext.xbume.processStats 提供；旧版 SDK 未注册时静默
        // 跳过，前端继续用上面的 isolate 采样值。
        try {
          final ext = await rpc.rawRpc(
              'ext.xbume.processStats', <String, Object?>{'isolateId': iso});
          final stats = perfExtensionData(ext);
          if (stats != null && stats['supported'] == true) {
            payload['processStats'] = stats;
          }
        } catch (_) {}
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(payload));
        await req.response.close();
      } catch (e) {
        req.response.statusCode = HttpStatus.badGateway;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}),
        );
        await req.response.close();
      } finally {
        await rpc.close();
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
      final rpc = _SandboxRpc(uri);
      try {
        final r = await rpc.rawRpc('_flutter.screenshot');
        final b64 = (r['data'] ?? r['screenshot'])?.toString() ?? '';
        if (b64.isEmpty) throw '截图响应为空（app 需 debug 模式且前台运行）';
        req.response.headers.contentType = ContentType('image', 'png');
        req.response.headers.set('Cache-Control', 'no-store');
        req.response.add(base64Decode(b64));
        await req.response.close();
      } catch (e) {
        req.response.statusCode = HttpStatus.badGateway;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}),
        );
        await req.response.close();
      } finally {
        await rpc.close();
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
            jsonEncode(
                <String, Object?>{'ok': false, 'error': 'app 无渲染树（尚未运行首帧）'}),
          );
          await req.response.close();
          return;
        }
        final parts = s.split('\u0003');
        // 末两段为空行分隔与尾部元数据（dpr\u0001物理宽\u0001物理高）；
        // 输出异常（空/缺段）时按空树处理，避免 sublist 越界。
        final meta = parts.length >= 2
            ? parts[parts.length - 1].split('\u0001')
            : <String>[];
        final rows = parts.length >= 2
            ? parts.sublist(0, parts.length - 2)
            : const <String>[];
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
        req.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      } finally {
        await rpc.close();
      }
      await req.response.close();
      return;
    }
    // ── P9b：点截图反查业务组件（locator 同款 SDK 判定 + 四向间距）──
    if (path == '/api/wtree/pick' && req.method == 'POST') {
      final uri = req.uri.queryParameters['uri'] ?? '';
      final x = req.uri.queryParameters['x'] ?? '';
      final y = req.uri.queryParameters['y'] ?? '';
      if (uri.isEmpty ||
          double.tryParse(x) == null ||
          double.tryParse(y) == null) {
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
          req.response.write(
              jsonEncode(<String, Object?>{'ok': false, 'error': '响应格式异常'}));
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
        req.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      } finally {
        await rpc.close();
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
              'name':
                  f.uri.pathSegments.last.replaceAll(RegExp(r'\.json$'), ''),
              'steps': steps,
              'mtime': f.statSync().modified.toIso8601String(),
            });
          } catch (_) {}
        }
      }
      req.response.headers.contentType = ContentType.json;
      req.response
          .write(jsonEncode(<String, Object?>{'ok': true, 'items': items}));
      await req.response.close();
      return;
    }
    if (path == '/api/auto/get' || path == '/api/auto/delete') {
      final name = (req.uri.queryParameters['name'] ?? '').trim();
      final file = _autoScenarioFile(name);
      if (file == null) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(
            <String, Object?>{'ok': false, 'error': _autoNameError}));
        await req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType.json;
      if (path == '/api/auto/get') {
        if (!file.existsSync()) {
          req.response.write(
              jsonEncode(<String, Object?>{'ok': false, 'error': '场景不存在'}));
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
      final body = await _readBodyText(req);
      try {
        final j = jsonDecode(body) as Map<String, dynamic>;
        final file = _autoScenarioFile((j['name'] ?? '').toString());
        if (file == null) {
          req.response.statusCode = HttpStatus.badRequest;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(
              <String, Object?>{'ok': false, 'error': _autoNameError}));
          await req.response.close();
          return;
        }
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(j['steps'] ?? []));
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'ok': true}));
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      }
      await req.response.close();
      return;
    }
    if (path == '/api/auto/run' && req.method == 'POST') {
      if (_auto.running || _compare.running) {
        req.response.statusCode = HttpStatus.conflict;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': false,
          'error': _auto.running ? '已有场景在执行' : '对比任务在执行中，请稍后再试',
        }));
        await req.response.close();
        return;
      }
      final uri = req.uri.queryParameters['uri'] ?? '';
      String name = req.uri.queryParameters['name'] ?? '';
      List steps;
      final body = await _readBodyText(req);
      try {
        if (body.isNotEmpty) {
          final j = jsonDecode(body);
          steps = j is List
              ? j
              : (j is Map ? (j['steps'] as List? ?? <Object?>[]) : <Object?>[]);
          if (j is Map && name.isEmpty) name = (j['name'] ?? '').toString();
        } else if (name.isNotEmpty) {
          final file = _autoScenarioFile(name);
          if (file == null || !file.existsSync()) {
            req.response.headers.contentType = ContentType.json;
            req.response.write(
                jsonEncode(<String, Object?>{'ok': false, 'error': '场景不存在'}));
            await req.response.close();
            return;
          }
          steps = jsonDecode(file.readAsStringSync()) as List;
        } else {
          steps = <Object?>[];
        }
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': '步骤解析失败: $e'}));
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
      req.response.write(
          jsonEncode(<String, Object?>{'ok': true, 'total': steps.length}));
      await req.response.close();
      return;
    }
    if (path == '/api/auto/status') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(
          <String, Object?>{'ok': true}..addAll(_auto.statusJson())));
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
    // ── 多设备并排对比：同一场景在两个会话上并行执行 ──────────────────────
    if (path == '/api/compare/run' && req.method == 'POST') {
      if (_compare.running || _auto.running) {
        req.response.statusCode = HttpStatus.conflict;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': false,
          'error': _compare.running ? '已有对比任务在执行' : '场景正在执行，稍后再试',
        }));
        await req.response.close();
        return;
      }
      Map<String, dynamic> j = <String, dynamic>{};
      try {
        final body = await _readBodyText(req);
        if (body.isNotEmpty) j = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(
            <String, Object?>{'ok': false, 'error': '请求体不是合法 JSON'}));
        await req.response.close();
        return;
      }
      final uriA = (j['uriA'] ?? '').toString().trim();
      final uriB = (j['uriB'] ?? '').toString().trim();
      final labelA = (j['labelA'] ?? uriA).toString();
      final labelB = (j['labelB'] ?? uriB).toString();
      final name = (j['name'] ?? '').toString();
      List steps = j['steps'] is List ? j['steps'] as List : <Object?>[];
      if (steps.isEmpty && name.isNotEmpty) {
        final file = _autoScenarioFile(name);
        if (file == null || !file.existsSync()) {
          req.response.statusCode = HttpStatus.badRequest;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
              jsonEncode(<String, Object?>{'ok': false, 'error': '场景不存在'}));
          await req.response.close();
          return;
        }
        steps = jsonDecode(file.readAsStringSync()) as List;
      }
      String? bad;
      if (uriA.isEmpty || uriB.isEmpty) bad = '需要选择两个会话（A / B）';
      if (bad == null && uriA == uriB) bad = 'A / B 不能是同一个会话';
      if (bad == null && steps.isEmpty) bad = '场景为空';
      if (bad == null && steps.length > 500) bad = '步骤过多（最多 500 步）';
      if (bad != null) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response
            .write(jsonEncode(<String, Object?>{'ok': false, 'error': bad}));
        await req.response.close();
        return;
      }
      unawaited(_compareRunSteps(
        uriA: uriA,
        uriB: uriB,
        labelA: labelA,
        labelB: labelB,
        name: name,
        steps: steps,
        continueOnFail: (j['continueOnFail'] ?? true) == true,
        shotEveryStep: (j['shotEveryStep'] ?? true) == true,
      ));
      req.response.headers.contentType = ContentType.json;
      req.response.write(
          jsonEncode(<String, Object?>{'ok': true, 'total': steps.length}));
      await req.response.close();
      return;
    }
    if (path == '/api/compare/status') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(
          <String, Object?>{'ok': true}..addAll(_compare.statusJson())));
      await req.response.close();
      return;
    }
    if (path == '/api/compare/stop' && req.method == 'POST') {
      _compare.stopReq = true;
      final a = _compare.a;
      final b = _compare.b;
      if (a != null) a.stopReq = true;
      if (b != null) b.stopReq = true;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': true}));
      await req.response.close();
      return;
    }
    // 截图遥控：单步 tap/swipe/input，不占用场景执行状态、不落步骤截图；
    // 供截图 Tab 的点击/拖拽/输入使用，回放仍走 /api/auto/run。
    if (path == '/api/remote/op' && req.method == 'POST') {
      Map<String, dynamic> body = <String, dynamic>{};
      try {
        final raw = await _readBodyText(req);
        if (raw.isNotEmpty) body = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(
            <String, Object?>{'ok': false, 'error': '请求体不是合法 JSON'}));
        await req.response.close();
        return;
      }
      final uri = (body['uri'] ?? '').toString().trim();
      final rawStep = body['step'];
      final step = rawStep is Map
          ? Map<String, dynamic>.from(rawStep)
          : <String, dynamic>{};
      final type = (step['type'] ?? '').toString();
      String? bad;
      if (uri.isEmpty) bad = '缺少 uri';
      if (bad == null && !remoteOpAllowed(type)) {
        bad = '遥控只支持 tap / swipe / input';
      }
      if (bad == null &&
          type == 'input' &&
          (step['text'] ?? '').toString().length > 5000) {
        bad = '输入文本过长（最多 5000 字）';
      }
      if (bad != null) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response
            .write(jsonEncode(<String, Object?>{'ok': false, 'error': bad}));
        await req.response.close();
        return;
      }
      try {
        final (actual, err) = await _autoExecStep(uri, step);
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'ok': err.isEmpty,
          'actual': actual,
          'error': err
        }));
      } catch (e) {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.headers.contentType = ContentType.json;
        req.response
            .write(jsonEncode(<String, Object?>{'ok': false, 'error': '$e'}));
      }
      await req.response.close();
      return;
    }
    if (path == '/api/auto/artifact') {
      final f = req.uri.queryParameters['f'] ?? '';
      // 文件名防穿越：只允许 run-/ai-/cmp- 步骤截图与 watch-<ts>-<n>.png 监听截图
      if (f.isEmpty ||
          f.contains('/') ||
          f.contains('\\') ||
          (!RegExp(r'^(?:run|ai)-\d+-(?:step\d+|r\d+)\.png$').hasMatch(f) &&
              !RegExp(r'^cmp-\d+-[ab]-step\d+\.png$').hasMatch(f) &&
              !RegExp(r'^watch-\d+-\d+\.png$').hasMatch(f))) {
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
          final body = await _readBodyText(req);
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
          f.writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert(<String, Object?>{
            'baseUrl': (j['baseUrl'] ?? '').toString().trim(),
            'apiKey': newKey,
            'model': (j['model'] ?? '').toString().trim(),
            'ctx': <String, Object?>{
              'routes': cv(
                  cIn is Map ? cIn['routes'] : null, oldCtx['routes'] ?? true),
              'text':
                  cv(cIn is Map ? cIn['text'] : null, oldCtx['text'] ?? true),
              'net': cv(cIn is Map ? cIn['net'] : null, oldCtx['net'] ?? true),
              'log': cv(cIn is Map ? cIn['log'] : null, oldCtx['log'] ?? true),
              'elements': cv(cIn is Map ? cIn['elements'] : null,
                  oldCtx['elements'] ?? true),
            },
          }));
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, Object?>{'ok': true}));
        } catch (e) {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(
              <String, Object?>{'ok': false, 'error': e.toString()}));
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
        req.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': '已有任务在执行'}));
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
      req.response.write(
          jsonEncode(<String, Object?>{'ok': true, 'items': _aiGoalsLoad()}));
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
      req.response.write(
          jsonEncode(<String, Object?>{'ok': true}..addAll(_ai.statusJson())));
      await req.response.close();
      return;
    }
    // AI 运行测试报告下载：优先取运行结束落盘的文件，无文件时现场生成兜底
    if (path == '/api/ai/report') {
      final saved = _ai.runId.isEmpty
          ? null
          : File('$_autoScenariosDir/reports/${_ai.runId}.html');
      final hasSaved = saved != null && saved.existsSync();
      if (!hasSaved && _ai.rounds.isEmpty) {
        req.response.statusCode = HttpStatus.notFound;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(
            <String, Object?>{'ok': false, 'error': '暂无可导出的 AI 运行报告'}));
        await req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType.html;
      req.response.headers.set(
          'Content-Disposition',
          'attachment; filename="xb_ume_ai_report_'
              '${_ai.runId.isEmpty ? DateTime.now().millisecondsSinceEpoch : _ai.runId}.html"');
      if (hasSaved) {
        await saved.openRead().pipe(req.response);
      } else {
        req.response.write(_aiReportHtml());
      }
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
        final body = await _readBodyText(req);
        final j = jsonDecode(body) as Map<String, dynamic>;
        final file = _autoScenarioFile((j['name'] ?? '').toString());
        if (file == null) {
          req.response.statusCode = HttpStatus.badRequest;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(
              <String, Object?>{'ok': false, 'error': _autoNameError}));
          await req.response.close();
          return;
        }
        // 拍平各轮 AI 步骤（过滤掉本轮未执行完的尾部 skip 结果对应的步骤）
        final steps = <Object?>[];
        for (final r in _ai.rounds) {
          for (var i = 0; i < r.results.length && i < r.steps.length; i++) {
            if (r.results[i].status == 'pass' ||
                r.results[i].status == 'fail') {
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
        req.response.write(
            jsonEncode(<String, Object?>{'ok': true, 'steps': steps.length}));
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
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
    // ── 异常 AI 归因：栈帧源码 + 路由/页面/网络/日志 → 根因与修复建议 ──
    if (path == '/api/exc/analyze' && req.method == 'POST') {
      Map<String, Object?> body = <String, Object?>{};
      try {
        final raw = await _readBodyText(req);
        if (raw.isNotEmpty) {
          body = jsonDecode(raw) as Map<String, Object?>;
        }
      } catch (_) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(
            <String, Object?>{'ok': false, 'error': '请求体不是合法 JSON'}));
        await req.response.close();
        return;
      }
      final id = int.tryParse('${body['id']}');
      Map<String, Object?>? rec;
      if (id != null) {
        for (final item in state.exceptions) {
          if (item['id'] == id) {
            rec = item;
            break;
          }
        }
      }
      req.response.headers.contentType = ContentType.json;
      if (rec == null) {
        req.response.write(jsonEncode(<String, Object?>{
          'ok': false,
          'error': '异常记录不存在（可能已被清空或超出 200 条缓冲）',
        }));
        await req.response.close();
        return;
      }
      var uri = (body['uri'] ?? '').toString().trim();
      if (uri.isEmpty) uri = rec['wsUri']?.toString() ?? '';
      try {
        final result = await _excAnalyze(rec, uri);
        req.response.write(jsonEncode(result));
      } catch (e) {
        req.response
            .write(jsonEncode(<String, Object?>{'ok': false, 'error': '$e'}));
      }
      await req.response.close();
      return;
    }
    // ── 时间轴：路由/网络事件（日志与异常由前端本地合并，服务端不重复存）──
    if (path == '/api/timeline' && req.method == 'GET') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{
        'uri': state.timelineUri ?? '',
        'items': state.timelineItems,
      }));
      await req.response.close();
      return;
    }
    if (path == '/api/timeline/sub' && req.method == 'POST') {
      var uri = req.uri.queryParameters['uri'] ?? '';
      if (uri.isEmpty) {
        try {
          final raw = await _readBodyText(req);
          if (raw.isNotEmpty) {
            final body = jsonDecode(raw);
            if (body is Map) uri = body['uri']?.toString() ?? '';
          }
        } catch (_) {
          // body 不是 JSON：按空 uri 处理，下面返回 400
        }
      }
      if (uri.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{'error': '缺少 uri'}));
        await req.response.close();
        return;
      }
      final error = await state.startTimeline(uri);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{
        'ok': error == null,
        'error': error,
        'uri': uri,
        'items': state.timelineItems,
      }));
      await req.response.close();
      return;
    }
    if (path == '/api/timeline/off' && req.method == 'POST') {
      state.stopTimeline();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': true}));
      await req.response.close();
      return;
    }
    if (path == '/api/timeline/clear' && req.method == 'POST') {
      state.clearTimeline();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': true}));
      await req.response.close();
      return;
    }
    // ── P12 Watch：实例字段 / eval 表达式监听 → 变化写时间轴、条件命中截图 ──
    if (path == '/api/watch/list') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{
        'ok': true,
        'items': state.watchItems(req.uri.queryParameters['uri'] ?? ''),
      }));
      await req.response.close();
      return;
    }
    if (path == '/api/watch/events') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{
        'ok': true,
        'items': state.watchEvents(req.uri.queryParameters['uri'] ?? ''),
      }));
      await req.response.close();
      return;
    }
    if (path == '/api/watch/add' && req.method == 'POST') {
      Map<String, dynamic> body = <String, dynamic>{};
      try {
        final raw = await _readBodyText(req);
        if (raw.isNotEmpty) body = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(
          <String, Object?>{'ok': false, 'error': '请求体不是合法 JSON'},
        ));
        await req.response.close();
        return;
      }
      final r = state.addWatch(body);
      req.response.statusCode =
          r['ok'] == true ? HttpStatus.ok : HttpStatus.badRequest;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(r));
      await req.response.close();
      return;
    }
    if (path == '/api/watch/remove' && req.method == 'POST') {
      final ok = state.removeWatch(req.uri.queryParameters['id'] ?? '');
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': ok}));
      await req.response.close();
      return;
    }
    if (path == '/api/watch/pause' && req.method == 'POST') {
      final on = (req.uri.queryParameters['on'] ?? '1') == '1';
      final ok = state.pauseWatch(req.uri.queryParameters['id'] ?? '', on);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, Object?>{'ok': ok}));
      await req.response.close();
      return;
    }
    if (path == '/api/watch/clear' && req.method == 'POST') {
      state.clearWatchEvents();
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
      final limit = (int.tryParse(req.uri.queryParameters['limit'] ?? '') ?? 20)
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
              "if (s != null && s.runtimeType.toString() == '${_escEvalString(cls)}') { out.add(s); } "
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
        req.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
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
        req.response
            .write(jsonEncode(<String, Object?>{'ok': true, 'node': node}));
      } catch (e) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
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
      // 字段名会直接拼进 evaluate 表达式，只允许合法标识符（含 _ 私有字段）。
      if (!RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(field)) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(
          <String, Object?>{'ok': false, 'error': '字段名不合法：$field'},
        ));
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
            // 必须用 _escEvalString：值里的 $（字符串插值）、换行、制表符
            // 不转义会生成非法表达式或写错值。
            literal = "'${_escEvalString(value)}'";
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
              .split('\n')
              .take(3)
              .join(' ');
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
        req.response.write(
            jsonEncode(<String, Object?>{'ok': false, 'error': e.toString()}));
      }
      await rpc.close();
      await req.response.close();
      return;
    }
    // -- SQLite / DB 浏览器 -----------------------------------------------
    // 把 app 沙盒里的 .db 分段拉到本机缓存，再用 sqlite3 命令行只读查询；
    // app 端零改动。写操作由 -readonly 拒绝，SQL 限单条。
    if (path.startsWith('/api/db/') && path != '/api/db/download') {
      Future<void> fail(Object e, {int code = HttpStatus.badGateway}) async {
        req.response.statusCode = code;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': e.toString()}));
        await req.response.close();
      }

      Map<String, Object?> body = <String, Object?>{};
      if (req.method == 'POST') {
        try {
          final raw = await _readBodyText(req);
          if (raw.isNotEmpty) {
            body = (jsonDecode(raw) as Map).cast<String, Object?>();
          }
        } catch (_) {}
      }
      String param(String k) =>
          (body[k] ?? req.uri.queryParameters[k])?.toString() ?? '';

      try {
        if (path == '/api/db/open') {
          final uri = param('uri');
          final target = param('path');
          final force = body['force'] == true;
          if (uri.isEmpty || target.isEmpty) {
            await fail('缺少 uri/path', code: HttpStatus.badRequest);
            return;
          }
          final rpc = _SandboxRpc(uri);
          try {
            final stat = await rpc.evalString(
              "(() { final st = File('${_escPath(target)}').statSync(); "
              "return '\${st.size}\\t\${st.modified.millisecondsSinceEpoch}'; })()",
            );
            final parts = stat.split('\t');
            final size = int.tryParse(parts.first) ?? 0;
            final mtime = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
            if (size <= 0) {
              await fail('文件为空或不是普通文件', code: HttpStatus.badRequest);
              return;
            }
            if (size > 256 * 1024 * 1024) {
              await fail(
                  '数据库文件 ${(size / 1024 / 1024).toStringAsFixed(1)}MB '
                  '超过 256MB 上限',
                  code: HttpStatus.badRequest);
              return;
            }
            final id = dbCacheId(uri, target, size, mtime);
            final dir = Directory(dbCacheDir())..createSync(recursive: true);
            final file = File('${dir.path}/$id.db');
            final baseName = target.split(RegExp(r'[/\\]')).last;
            var cached = false;
            if (!force && file.existsSync() && file.lengthSync() == size) {
              cached = true;
            } else {
              final tmp = File('${file.path}.tmp');
              if (tmp.existsSync()) tmp.deleteSync();
              final raf = tmp.openSync(mode: FileMode.write);
              try {
                await _readSandboxFileChunks(rpc, target, raf.writeFromSync);
              } finally {
                raf.closeSync();
              }
              final got = tmp.lengthSync();
              if (got != size) {
                tmp.deleteSync();
                await fail('文件拉取不完整（$got/$size 字节），请重试');
                return;
              }
              tmp.renameSync(file.path);
            }
            final check = await dbRunSqlite(file.path, 'PRAGMA schema_version');
            if (check.exitCode != 0) {
              if (!cached) file.deleteSync();
              await fail('不是有效的 SQLite 数据库：${dbSqliteErrorText(check)}',
                  code: HttpStatus.badRequest);
              return;
            }
            final tables = await dbListTables(file.path);
            var sqliteVer = '';
            final ver =
                await dbRunSqlite(file.path, 'SELECT sqlite_version() AS v');
            if (ver.exitCode == 0) {
              final p = dbParseJsonRows(ver.stdout);
              final rows = (p['rows'] as List).cast<List<Object?>>();
              if (rows.isNotEmpty && rows.first.isNotEmpty) {
                sqliteVer = rows.first.first?.toString() ?? '';
              }
            }
            // 记录原库名，供 CSV 下载时命名（缓存命中也刷新）。
            try {
              File('${dir.path}/$id.name').writeAsStringSync(baseName);
            } catch (_) {}
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode(<String, Object?>{
              'dbId': id,
              'name': baseName,
              'path': target,
              'size': size,
              'mtime': mtime,
              'cached': cached,
              'sqlite': sqliteVer,
              'tables': tables,
            }));
            await req.response.close();
          } finally {
            await rpc.close();
          }
          return;
        }

        final dbId = param('dbId');
        if (!dbIdOk(dbId)) {
          await fail('dbId 非法', code: HttpStatus.badRequest);
          return;
        }
        final file = File('${dbCacheDir()}/$dbId.db');
        if (!file.existsSync()) {
          await fail('数据库缓存不存在，请重新打开', code: HttpStatus.notFound);
          return;
        }

        if (path == '/api/db/schema') {
          final table = param('table');
          if (table.isEmpty) {
            await fail('缺少 table', code: HttpStatus.badRequest);
            return;
          }
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(await dbTableInfo(file.path, table)));
          await req.response.close();
          return;
        }

        final sql = param('sql');
        final sqlErr = dbSqlError(sql);
        if (sqlErr != null) {
          await fail(sqlErr, code: HttpStatus.badRequest);
          return;
        }

        if (path == '/api/db/query') {
          final r = await dbRunSqlite(file.path, sql);
          if (r.exitCode != 0) {
            await fail(dbSqliteErrorText(r), code: HttpStatus.badRequest);
            return;
          }
          final parsed = dbParseJsonRows(r.stdout);
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, Object?>{
            'columns': parsed['columns'],
            'rows': parsed['rows'],
            'truncated': r.truncated,
            'ms': r.ms,
          }));
          await req.response.close();
          return;
        }

        if (path == '/api/db/csv') {
          final r = await dbRunSqlite(file.path, sql,
              csv: true, maxBytes: 64 * 1024 * 1024);
          if (r.exitCode != 0) {
            await fail(dbSqliteErrorText(r));
            return;
          }
          req.response.headers.contentType =
              ContentType('text', 'csv', charset: 'utf-8');
          final fileName = dbCsvFileName(dbId);
          req.response.headers.set(
            'Content-Disposition',
            'attachment; filename="$fileName"; filename*=UTF-8\'\''
                '${Uri.encodeComponent(fileName)}',
          );
          // BOM：让 Excel 正确识别 UTF-8 中文。
          req.response.add(utf8.encode('\uFEFF'));
          req.response.write(r.stdout);
          await req.response.close();
          return;
        }

        if (path == '/api/db/close') {
          if (file.existsSync()) file.deleteSync();
          final meta = File('${dbCacheDir()}/$dbId.name');
          if (meta.existsSync()) meta.deleteSync();
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(<String, Object?>{'ok': true}));
          await req.response.close();
          return;
        }

        await fail('未知的数据库接口', code: HttpStatus.notFound);
      } catch (e) {
        await fail(e);
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
          await _readSandboxFileChunks(rpc, target, req.response.add);
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
          final header =
              _tarHeader(_relativeTo(f[0], target, os), size, mtimeSec);
          if (header == null) {
            skipped++;
            continue;
          }
          req.response.add(header);
          await _readSandboxFileChunks(rpc, f[0], req.response.add);
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
  } on _PayloadTooLargeException {
    print('[xbume-gui] 请求体过大 $path');
    try {
      req.response.statusCode = HttpStatus.requestEntityTooLarge;
      await req.response.close();
    } catch (_) {
      // ignored
    }
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

/// GUI 访问令牌校验：X-XBUME-Token（fetch 包装器）> Cookie（页面自动携带）
/// > query token（WS 与命令行脚本），三选一，先命中先算。
bool _isGuiAuthorized(HttpRequest req) {
  if (_guiToken.isEmpty) return false;
  // 先看显式 header：页面重启后浏览器可能还带着上一份 Cookie（名字只含端口，
  // 新实例同名但值已变），不能让陈旧的 Cookie 压过请求里带的新令牌。
  String? supplied = req.headers.value('x-xbume-token');
  if (supplied == null || supplied.isEmpty) {
    try {
      for (final c in req.cookies) {
        if (c.name == 'xbume_gui_$_guiPort') {
          supplied = c.value;
          break;
        }
      }
    } catch (_) {}
  }
  supplied ??= req.uri.queryParameters['token'];
  if (supplied == null || supplied.isEmpty) return false;
  return constantTimeEquals(supplied, _guiToken);
}

Future<void> _rejectRequest(
  HttpRequest req,
  int status,
  String message,
) async {
  try {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(
      jsonEncode(<String, Object?>{'ok': false, 'error': message}),
    );
    await req.response.close();
  } catch (_) {
    // 连接可能已被对端关闭。
  }
}

/// 带累计上限的请求体读取：Content-Length 提前拒，chunked 在流式累计
/// 超限时中止，避免大 body 把 GUI 进程内存打满。
Future<String> _readBodyText(
  HttpRequest req, {
  int maxBytes = kGuiBodyLimitBytes,
  bool lenient = false,
}) async {
  if (req.contentLength > maxBytes) throw const _PayloadTooLargeException();
  final bytes = <int>[];
  var total = 0;
  await for (final chunk in req) {
    total += chunk.length;
    if (total > maxBytes) throw const _PayloadTooLargeException();
    bytes.addAll(chunk);
  }
  return lenient
      ? _lenientUtf8.decode(bytes)
      : utf8.decode(bytes, allowMalformed: true);
}

class _PayloadTooLargeException implements Exception {
  const _PayloadTooLargeException();
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

  /// poll 重入保护：3s 定时器与前端「刷新」都会触发 poll，设备命令变慢时
  /// 两轮并发会重复启动设备日志进程（后者覆盖 map，前者成孤儿进程）。
  bool _polling = false;

  /// 异常缓冲（全部会话汇总，最新在末尾；供异常 Tab 与 /api/exceptions）。
  final List<Map<String, Object?>> _exceptions = <Map<String, Object?>>[];
  int _excSeq = 0;

  /// 输出流未捕获异常块的逐行解析器（key: uri|stream → tracker）。
  final Map<String, _UncaughtTracker> _uncaught = <String, _UncaughtTracker>{};

  /// 每台设备一个日志流进程（所有设备并行采集，选择器只做前端过滤）。
  final Map<String, Process> _deviceLogProcesses = <String, Process>{};

  /// 正在启动中的设备 id（Process.start 未返回前占位，防并发重入）。
  final Set<String> _deviceLogStarting = <String>{};
  final Set<String> _deviceLogStartFailed = <String>{};
  List<Map<String, String>> devices = <Map<String, String>>[];
  String? selectedId;

  /// 由本工具箱开启了屏幕常亮的设备 id。
  ///
  /// 只代表「本进程发过开启命令」：hdc 的覆盖值在手机重启 / powmgr 重启后
  /// 失效，GUI 重启后这里也会清空，前端以本集合为准（重启后重新勾一次即可，
  /// 命令幂等）。设备掉线时在 [poll] 里一并移除。
  final Set<String> _keepAwake = <String>{};

  List<String> get keepAwakeIds => _keepAwake.toList(growable: false);

  /// 记录常亮状态并把设备列表重新推给所有前端。
  void setKeepAwakeLocal(String deviceId, bool on) {
    if (on) {
      _keepAwake.add(deviceId);
    } else {
      _keepAwake.remove(deviceId);
    }
    broadcast(<String, Object?>{
      'type': 'devices',
      'devices': devices,
      'keepAwake': keepAwakeIds,
    });
  }

  /// 已连接调试会话反推的项目根（供「AI 调试」页的项目目录候选）。
  List<String> get sessionProjectRoots {
    final out = <String>[];
    for (final s in _vmSessions.values) {
      final root = s.projectRoot;
      if (root != null && root.isNotEmpty && !out.contains(root)) out.add(root);
    }
    return out;
  }

  /// 日志环形缓冲（供 HTTP 导出接口读取）。
  List<Map<String, Object?>> get buffer => _buffer;

  /// 调试中枢（flutter run + VM 断点）：首次访问「调试」Tab 时创建。
  /// 事件与输出经 [broadcast] 推给前端，所以放在 state 里统一收尾。
  DebugHub? _debugHub;
  DebugHub get debugHub => _debugHub ??= DebugHub(push: broadcast);

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

  /// VM 地址 → 项目根（「调试」页接入外部会话时给断点相对路径用）。
  String? projectRootForVmUri(String uri) {
    for (final entry in _vmSessions.entries) {
      if (entry.key.startsWith('$uri|')) {
        final root = entry.value.projectRoot;
        return (root == null || root.isEmpty) ? null : root;
      }
    }
    return null;
  }

  Future<void> dispose() async {
    final hub = _debugHub;
    if (hub != null) unawaited(hub.dispose());
    _pollTimer?.cancel();
    _flushTimer?.cancel();
    _tlTimer?.cancel();
    final tlRpc = _tlRpc;
    _tlRpc = null;
    if (tlRpc != null) unawaited(tlRpc.close());
    _watchTimer?.cancel();
    for (final rpc in _watchRpcs.values) {
      unawaited(rpc.close());
    }
    _watchRpcs.clear();
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
    if (_polling) return;
    _polling = true;
    try {
      try {
        devices = await discoverDevices();
      } catch (e) {
        print('[xbume-gui] 设备发现异常: $e');
      }
      final ids = devices.map((d) => d['id'] ?? '').toSet();
      // 设备拔掉后不再保留常亮标记（重新插上时重新勾一次，命令幂等）。
      _keepAwake.removeWhere((id) => !ids.contains(id));
      broadcast(<String, Object?>{
        'type': 'devices',
        'devices': devices,
        'keepAwake': keepAwakeIds,
      });
      for (final device in devices) {
        await _ensureDeviceLogSource(device);
      }
      for (final id in _deviceLogProcesses.keys.toList()) {
        if (!ids.contains(id)) {
          await _stopDeviceLogSource(id);
        }
      }
      await _syncVmSessions();
    } finally {
      _polling = false;
    }
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
    if (id.isEmpty ||
        _deviceLogProcesses.containsKey(id) ||
        _deviceLogStarting.contains(id)) {
      return;
    }
    final command = _deviceLogCommand(device);
    if (command == null) {
      return;
    }
    final source = _sourceForPlatform(device['platform'] ?? '');
    _deviceLogStarting.add(id);
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
        addDeviceLog(
            id, source, '[GUI] 无法启动 ${command.first}（未安装或不在 PATH）: $e');
      }
    } finally {
      _deviceLogStarting.remove(id);
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
        final existing = _vmSessions[key];
        if (existing != null) {
          if (!existing.needsReconnect) {
            continue;
          }
          // 建连失败/连接已断开：丢弃后重建，下一轮 poll（3s）自然重试。
          // 旧实现把失败会话留在 map 里，该 uri 的这条流会永久失效到 GUI
          // 重启（app 重启/拔线重插后日志与异常通道不再恢复）。
          _vmSessions.remove(key)?.close();
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
    // 记录异常来源会话的 VM service 地址：AI 归因需要回连该会话取路由/
    // 网络上下文（异常可能来自非当前选中的会话）。
    rec['wsUri'] = session.uri;
    rec['time'] = _clock();
    rec['ts'] = now.millisecondsSinceEpoch;
    final os = session.os;
    if (os != null && os.isNotEmpty) rec['os'] = os;
    final app = session.appName;
    if (app != null && app.isNotEmpty) rec['app'] = app;
    if (_exceptions.isNotEmpty) {
      final last = _exceptions.last;
      final lastTs = (last['ts'] as int?) ?? 0;
      if (last['hash'] == hash && now.millisecondsSinceEpoch - lastTs < 10000) {
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
    _dumpRouteTraceForException(rec, channel, label);
    if (_isDescendantAssert(rec)) _dumpDepsForException(session, label);
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
    // flutter run 会把 VM service URL（含 auth token）打到 stdout，入缓冲前打码。
    final msg = entry['msg'];
    if (msg != null) entry['msg'] = maskVmTokens(msg.toString());
    _buffer.add(entry);
    _trimLogBuffer(entry);
    _pending.add(entry);
  }

  /// 每个来源键（source|tag|device）的保留条数上限。
  ///
  /// 单个高频会话能在一两分钟内输出上千条，若全局缓冲只按部就班 FIFO，
  /// 其他会话与设备日志会被整片挤出（实测 f_jlink 会话占满 5000 条，
  /// 切到别的会话后 Flutter 输出为 0 条）。按来源分额后，每个来源都至少
  /// 保留自己最近的一千条。
  final Map<String, int> _srcCounts = <String, int>{};

  void _trimLogBuffer(Map<String, Object?> added) {
    trimLogBuffer(_buffer, _srcCounts, added);
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

  // -- 时间轴模块（路由 / 网络；日志与异常由前端本地合并）--------------------
  //
  // 设计取舍：日志已由 WS 全量推送、异常也在前端内存里，服务端再存一份只会
  // 翻倍流量；这里只轮询 app 端的 routes / network 两个环形缓冲（各 300 条），
  // 做 id 去重与状态更新后增量广播。轮询仅在「时间轴」Tab 激活时运行。

  static const String _timelineExpr = "(() { final r = StringBuffer(); "
      "for (final e in XBUme.controller.routes) { "
      "r..write(e.id)..write('\\u0001')..write(e.time.millisecondsSinceEpoch)..write('\\u0001')"
      "..write(e.action.name)..write('\\u0001')"
      "..write(e.routeName.replaceAll('\\u0001', ' ').replaceAll('\\u0002', ' ').replaceAll('\\u0003', ' '))..write('\\u0001')"
      "..write((e.previousRouteName ?? '').replaceAll('\\u0001', ' ').replaceAll('\\u0002', ' ').replaceAll('\\u0003', ' '))..write('\\u0001')"
      "..write(e.phase)..write('\\u0002'); } "
      "final n = StringBuffer(); "
      "for (final e in XBUme.controller.network) { "
      "n..write(e.id)..write('\\u0001')..write(e.time.millisecondsSinceEpoch)..write('\\u0001')"
      "..write(e.method)..write('\\u0001')"
      "..write(e.url.replaceAll('\\u0001', ' ').replaceAll('\\u0002', ' ').replaceAll('\\u0003', ' '))..write('\\u0001')"
      "..write((e.statusCode ?? '').toString())..write('\\u0001')"
      "..write((e.durationMs ?? '').toString())..write('\\u0001')"
      "..write(e.status.name)..write('\\u0001')"
      "..write((e.error ?? '').replaceAll('\\u0001', ' ').replaceAll('\\u0002', ' ').replaceAll('\\u0003', ' '))..write('\\u0002'); } "
      "return r.toString() + '\\u0003' + n.toString(); })()";

  /// 路由/网络事件累积（单会话）。上限 2000，超出淘汰最旧。
  final List<Map<String, Object?>> _tlItems = <Map<String, Object?>>[];
  final Map<String, int> _tlIndex = <String, int>{};
  String? _tlUri;
  Timer? _tlTimer;
  bool _tlBusy = false;
  int _tlFail = 0;

  /// 清空时刻：早于此时间的历史事件不再回填（app 端环形缓冲仍有旧记录）。
  int _tlFloorMs = 0;
  _SandboxRpc? _tlRpc;

  /// 当前订阅的会话 uri（空表示未订阅）。
  String? get timelineUri => _tlUri;

  /// 时间轴事件只读快照（供 /api/timeline）。
  List<Map<String, Object?>> get timelineItems =>
      List<Map<String, Object?>>.unmodifiable(_tlItems);

  /// 订阅会话的时间轴：立即同步一次，之后 1.5s 增量。
  /// 返回首次同步的错误（null 表示成功），供前端提示未接入 xb_ume 等场景。
  Future<String?> startTimeline(String uri) async {
    if (_tlUri == uri && _tlTimer != null) return null;
    // 同一会话（切走再切回）保留已累积的历史与清空下限，只重启轮询；
    // 切换到其它会话才清空，避免两个会话的事件混在一起。
    final sameUri = _tlUri == uri;
    stopTimeline();
    _tlUri = uri;
    if (!sameUri) {
      _tlItems.clear();
      _tlIndex.clear();
      _tlFloorMs = 0;
    }
    _tlFail = 0;
    final error = await _timelinePoll();
    if (_tlUri != uri) return error;
    _tlTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => unawaited(_timelinePoll()),
    );
    broadcast(<String, Object?>{'type': 'tl', 'items': _tlItems});
    return error;
  }

  void stopTimeline() {
    _tlTimer?.cancel();
    _tlTimer = null;
    _tlUri = null;
    final rpc = _tlRpc;
    _tlRpc = null;
    if (rpc != null) unawaited(rpc.close());
  }

  /// 清空当前会话的累积事件，并设置回填下限（避免下一轮又把旧记录拉回来）。
  void clearTimeline() {
    _tlItems.clear();
    _tlIndex.clear();
    _tlFloorMs = DateTime.now().millisecondsSinceEpoch;
    broadcast(<String, Object?>{'type': 'tlCleared'});
  }

  Future<String?> _timelinePoll() async {
    final uri = _tlUri;
    if (uri == null || _tlBusy) return null;
    _tlBusy = true;
    final rpc = _tlRpc ??= _SandboxRpc(uri);
    try {
      final raw = await rpc.evalStringOn(
        'package:xb_ume/src/core/xb_ume.dart',
        _timelineExpr,
      );
      _tlFail = 0;
      // 会话已切换：丢弃本轮结果，避免旧会话事件写进新会话的累积。
      if (_tlUri != uri) return null;
      final changed = _tlUpsert(_parseTimeline(raw));
      if (_tlUri == uri && changed.isNotEmpty) {
        broadcast(<String, Object?>{'type': 'tl', 'items': changed});
      }
      return null;
    } catch (e) {
      _tlFail++;
      // 连接可能已失效（app 重启/断线）：丢弃复用连接，下一轮重建。
      // 只有当前连接仍是本轮所用时才清空（避免误清新一轮已建立的连接）。
      if (identical(_tlRpc, rpc)) {
        _tlRpc = null;
        unawaited(rpc.close());
      }
      if (_tlFail == 1 || _tlFail % 10 == 0) {
        print('[xbume-gui] 时间轴同步失败($uri): $e');
      }
      return '$e';
    } finally {
      _tlBusy = false;
    }
  }

  List<Map<String, Object?>> _parseTimeline(String raw) {
    final events = <Map<String, Object?>>[];
    final halves = raw.split('\u0003');
    // 路由：id / ms / action / name / prev / phase
    for (final line in (halves.isNotEmpty ? halves[0] : '').split('\u0002')) {
      if (line.isEmpty) continue;
      final p = line.split('\u0001');
      if (p.length < 6) continue;
      final ms = int.tryParse(p[1]) ?? 0;
      if (ms <= _tlFloorMs) continue;
      events.add(<String, Object?>{
        't': 'route',
        'id': p[0],
        'ms': ms,
        'action': p[2],
        'name': p[3],
        'prev': p[4],
        'phase': p[5],
      });
    }
    // 网络：id / ms / method / url / code / dur / status / err
    for (final line in (halves.length > 1 ? halves[1] : '').split('\u0002')) {
      if (line.isEmpty) continue;
      final p = line.split('\u0001');
      if (p.length < 8) continue;
      final ms = int.tryParse(p[1]) ?? 0;
      if (ms <= _tlFloorMs) continue;
      events.add(<String, Object?>{
        't': 'net',
        'id': p[0],
        'ms': ms,
        'method': p[2],
        'url': p[3],
        'code': p[4],
        'dur': p[5],
        'status': p[6],
        'err': p[7],
      });
    }
    return events;
  }

  /// 合并一批事件：同 key 原地更新（网络 pending → 完成），新 key 追加。
  /// 返回实际变化的事件（供 WS 增量推送；无变化返回空列表）。
  List<Map<String, Object?>> _tlUpsert(List<Map<String, Object?>> batch) {
    final changed = <Map<String, Object?>>[];
    for (final e in batch) {
      final key = '${e['t']}:${e['id']}';
      final i = _tlIndex[key];
      if (i == null) {
        _tlIndex[key] = _tlItems.length;
        _tlItems.add(e);
        changed.add(e);
        continue;
      }
      final old = _tlItems[i];
      if (old['status'] != e['status'] ||
          old['code'] != e['code'] ||
          old['dur'] != e['dur'] ||
          old['err'] != e['err']) {
        _tlItems[i] = e;
        changed.add(e);
      }
    }
    if (_tlItems.length > 2000) {
      _tlItems.removeRange(0, _tlItems.length - 2000);
      _tlIndex.clear();
      for (var i = 0; i < _tlItems.length; i++) {
        _tlIndex['${_tlItems[i]['t']}:${_tlItems[i]['id']}'] = i;
      }
    }
    return changed;
  }

  // -- P12 字段/表达式 Watch -------------------------------------------------

  final List<_WatchState> _watches = <_WatchState>[];
  final List<Map<String, Object?>> _watchEvents = <Map<String, Object?>>[];
  final Map<String, _SandboxRpc> _watchRpcs = <String, _SandboxRpc>{};
  Timer? _watchTimer;
  bool _watchBusy = false;
  int _watchSeq = 0;
  int _watchShotSeq = 0;

  /// 监听列表（uri 为空不过滤）。
  List<Map<String, Object?>> watchItems(String uri) => _watches
      .where((w) => uri.isEmpty || w.uri == uri)
      .map((w) => w.toJson())
      .toList();

  /// 时间轴监听事件（uri 为空不过滤，最新在末尾）。
  List<Map<String, Object?>> watchEvents(String uri) => _watchEvents
      .where((e) => uri.isEmpty || (e['uri'] ?? '') == uri)
      .toList();

  /// 新增监听。返回 {ok, item} 或 {ok:false, error}。
  Map<String, Object?> addWatch(Map<String, Object?> body) {
    final uri = (body['uri'] ?? '').toString().trim();
    final kind = (body['kind'] ?? 'expr').toString();
    final expr = (body['expr'] ?? '').toString().trim();
    final targetId = (body['targetId'] ?? '').toString().trim();
    final lib = (body['lib'] ?? '').toString().trim();
    final cond = (body['condition'] ?? '').toString().trim();
    var bad = '';
    if (uri.isEmpty) bad = '缺少 uri';
    if (bad.isEmpty && kind != 'field' && kind != 'expr') {
      bad = '监听类型只支持 field / expr';
    }
    if (bad.isEmpty && kind == 'field') {
      if (targetId.isEmpty) bad = 'field 监听缺少实例 id';
      if (bad.isEmpty && !watchFieldOk(expr)) bad = '字段名不合法：$expr';
    }
    if (bad.isEmpty && expr.isEmpty) bad = '表达式为空';
    if (bad.isEmpty && expr.length > 2000) bad = '表达式过长（最多 2000 字）';
    if (bad.isEmpty && cond.length > 2000) {
      bad = '条件表达式过长（最多 2000 字）';
    }
    if (bad.isNotEmpty) return <String, Object?>{'ok': false, 'error': bad};
    // 同一目标重复添加直接返回已有项（连点/重复点「监听」不产生重复轮询）。
    for (final w in _watches) {
      if (w.uri == uri &&
          w.kind == kind &&
          w.expr == expr &&
          w.targetId == targetId &&
          w.libUri == lib) {
        return <String, Object?>{
          'ok': true,
          'item': w.toJson(),
          'duplicated': true,
        };
      }
    }
    var label = (body['label'] ?? '').toString().trim();
    if (label.isEmpty) label = kind == 'field' ? expr : 'expr: $expr';
    if (label.length > 120) label = '${label.substring(0, 120)}…';
    final w = _WatchState(
      id: 'w${++_watchSeq}',
      uri: uri,
      kind: kind,
      targetId: targetId,
      expr: expr,
      libUri: lib.isEmpty ? 'package:flutter/src/widgets/binding.dart' : lib,
      label: label,
      intervalMs: watchIntervalMs(body['intervalMs']),
      condition: cond,
      autoShot: body['autoShot'] != false,
    );
    _watches.add(w);
    _ensureWatchTimer();
    _broadcastWatches();
    return <String, Object?>{'ok': true, 'item': w.toJson()};
  }

  bool removeWatch(String id) {
    final before = _watches.length;
    _watches.removeWhere((w) => w.id == id);
    final hit = _watches.length != before;
    if (hit) _broadcastWatches();
    return hit;
  }

  bool pauseWatch(String id, bool paused) {
    for (final w in _watches) {
      if (w.id != id) continue;
      w.paused = paused;
      w.fails = 0;
      if (paused) {
        w.condPrev = false;
      } else {
        w.nextAt = DateTime.now();
      }
      _broadcastWatches();
      return true;
    }
    return false;
  }

  void clearWatchEvents() {
    _watchEvents.clear();
    broadcast(<String, Object?>{'type': 'watchCleared'});
  }

  void _broadcastWatches() => broadcast(
      <String, Object?>{'type': 'watchList', 'items': watchItems('')});

  void _ensureWatchTimer() {
    _watchTimer ??= Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => unawaited(_watchTick()),
    );
  }

  /// 逐个轮询已到期的监听（串行执行，避免同一会话上并发 eval 互相拖慢）。
  Future<void> _watchTick() async {
    if (_watchBusy || _watches.isEmpty) return;
    final now = DateTime.now();
    final due =
        _watches.where((w) => !w.paused && !w.nextAt.isAfter(now)).toList();
    if (due.isEmpty) return;
    _watchBusy = true;
    try {
      for (final w in due) {
        w.nextAt = DateTime.now().add(Duration(milliseconds: w.intervalMs));
        await _watchPollOne(w);
      }
    } finally {
      _watchBusy = false;
    }
  }

  Future<void> _watchPollOne(_WatchState w) async {
    final rpc = _watchRpcs[w.uri] ??= _SandboxRpc(w.uri);
    try {
      final res = w.kind == 'field'
          ? await rpc.rawRpc('evaluate', <String, Object?>{
              'isolateId': await rpc.isolateId(),
              'targetId': w.targetId,
              'expression': w.expr,
            })
          : await rpc.evalRefOn(w.libUri, w.expr);
      final type = res['type']?.toString() ?? '';
      if (type == '@Error' || type == 'Error') {
        throw res['message']?.toString() ?? '表达式执行失败';
      }
      w.polls++;
      final value = fmtWatchValue(res);
      final old = w.lastValue;
      final first = !w.hasValue;
      w.hasValue = true;
      w.lastValue = value;
      if (!first && value != old) {
        w.changes++;
        _watchEmit(w, old: old, newValue: value);
      }
      // 条件只在开启「自动截图」时求值；false→true 的边沿触发一次截图。
      if (w.autoShot && w.condition.isNotEmpty) {
        final bool met;
        try {
          met = await _watchCond(rpc, w);
        } catch (e) {
          w.fails++;
          w.lastError = '条件表达式错误：$e';
          if (w.fails == 1 || w.fails % 10 == 0) {
            _watchEmit(w, err: w.lastError);
          }
          w.condPrev = false;
          if (w.fails >= 30) {
            w.paused = true;
            w.lastError = '${w.lastError}（连续失败 30 次，已自动暂停）';
            _broadcastWatches();
          } else {
            broadcast(
                <String, Object?>{'type': 'watchState', 'item': w.toJson()});
          }
          return;
        }
        if (met && !w.condPrev) {
          final shot = await _watchShot(rpc);
          w.shots++;
          _watchEmit(w, old: value, newValue: value, shot: shot, condMet: true);
        }
        w.condPrev = met;
      }
      w.fails = 0;
      w.lastError = '';
      broadcast(<String, Object?>{'type': 'watchState', 'item': w.toJson()});
    } catch (e) {
      w.fails++;
      w.lastError = e.toString();
      if (w.fails == 1 || w.fails % 10 == 0) _watchEmit(w, err: w.lastError);
      if (w.fails >= 30) {
        w.paused = true;
        w.lastError = '${w.lastError}（连续失败 30 次，已自动暂停）';
        _broadcastWatches();
      } else {
        broadcast(<String, Object?>{'type': 'watchState', 'item': w.toJson()});
      }
      // 连接可能已失效：丢弃复用连接，下一轮重建。
      final dead = _watchRpcs.remove(w.uri);
      if (dead != null) unawaited(dead.close());
    }
  }

  /// 条件表达式与监听同上下文求值（field：实例；expr：库）。
  Future<bool> _watchCond(_SandboxRpc rpc, _WatchState w) async {
    final res = w.kind == 'field'
        ? await rpc.rawRpc('evaluate', <String, Object?>{
            'isolateId': await rpc.isolateId(),
            'targetId': w.targetId,
            'expression': w.condition,
          })
        : await rpc.evalRefOn(w.libUri, w.condition);
    final type = res['type']?.toString() ?? '';
    if (type == '@Error' || type == 'Error') {
      throw res['message']?.toString() ?? '条件表达式执行失败';
    }
    final v = res['valueAsString']?.toString();
    if (v == 'true') return true;
    if (v == 'false' || v == 'null') return false;
    throw '条件表达式应返回 bool，实际：${v ?? type}';
  }

  /// 条件命中截图：落盘到场景 artifacts 目录（与失败截图同目录）。
  Future<String?> _watchShot(_SandboxRpc rpc) async {
    try {
      final r = await rpc.rawRpc('_flutter.screenshot');
      final b64 = (r['data'] ?? r['screenshot'])?.toString() ?? '';
      if (b64.isEmpty) return null;
      final dir = Directory(_autoArtifactsDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f =
          'watch-${DateTime.now().millisecondsSinceEpoch}-${++_watchShotSeq}.png';
      File('$_autoArtifactsDir/$f').writeAsBytesSync(base64Decode(b64));
      return f;
    } catch (_) {
      return null;
    }
  }

  /// 记一条监听事件（写时间轴 + WS 推送，服务端保留最近 500 条）。
  void _watchEmit(
    _WatchState w, {
    String? old,
    String? newValue,
    String? shot,
    bool condMet = false,
    String? err,
  }) {
    final item = <String, Object?>{
      'type': 'watch',
      'id': '${w.id}-${++_watchSeq}',
      'ms': DateTime.now().millisecondsSinceEpoch,
      'uri': w.uri,
      'watchId': w.id,
      'kind': w.kind,
      'label': w.label,
      'expr': w.expr,
      if (old != null) 'old': old,
      if (newValue != null) 'new': newValue,
      if (w.condition.isNotEmpty) 'condition': w.condition,
      if (condMet) 'condMet': true,
      if (shot != null) 'shot': shot,
      if (err != null) 'error': err,
      'changes': w.changes,
      'shots': w.shots,
    };
    _watchEvents.add(item);
    if (_watchEvents.length > 500) {
      _watchEvents.removeRange(0, _watchEvents.length - 500);
    }
    broadcast(<String, Object?>{'type': 'watch', 'item': item});
  }

  // -- 客户端与广播 ----------------------------------------------------------

  void addClient(WebSocket ws) {
    _clients.add(ws);
    // 新客户端立即全量同步（设备 + 已缓冲日志 + 异常 + 当前选中）。
    ws.add(jsonEncode(<String, Object?>{
      'type': 'snapshot',
      'devices': devices,
      'selected': selectedId,
      'keepAwake': keepAwakeIds,
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
    }, onDone: () {
      _clients.remove(ws);
      if (_clients.isEmpty) stopTimeline();
    }, onError: (_) {
      _clients.remove(ws);
      if (_clients.isEmpty) stopTimeline();
    });
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

/// Watch 轮询间隔（ms）：200–10000，缺省 500；过密 eval 会拖慢被调 app。
int watchIntervalMs(Object? raw) {
  final v =
      raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 500;
  return v.clamp(200, 10000);
}

/// 字段监听只接受合法 Dart 标识符（含 _/$ 私有字段），避免拼进表达式出错。
bool watchFieldOk(String name) =>
    RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name);

/// evaluate 结果 → 单行展示值：优先 valueAsString；对象给 <类名#id尾>，
/// 便于识别「同一字段换了个对象」这类变化。
String fmtWatchValue(Map<String, Object?> res) {
  final vs = res['valueAsString']?.toString();
  if (vs != null && vs.isNotEmpty) {
    if (vs.length > 200) return '${vs.substring(0, 200)}…';
    return res['valueAsStringIsTruncated'] == true ? '$vs…' : vs;
  }
  final cls = (res['class'] as Map?)?['name']?.toString() ?? '';
  final id = res['id']?.toString() ?? '';
  final tail =
      id.isEmpty ? '' : '#${id.length > 6 ? id.substring(id.length - 6) : id}';
  if (cls.isNotEmpty) return '<$cls$tail>';
  return res['type']?.toString() ?? '?';
}

/// 单条 Watch 监听：字段（实例上下文）或表达式（库上下文）。
class _WatchState {
  _WatchState({
    required this.id,
    required this.uri,
    required this.kind,
    required this.targetId,
    required this.expr,
    required this.libUri,
    required this.label,
    required this.intervalMs,
    required this.condition,
    required this.autoShot,
  });

  final String id;
  final String uri;

  /// field：targetId + expr（字段名）；expr：libUri + expr。
  final String kind;
  final String targetId;
  final String expr;
  final String libUri;
  final String label;

  int intervalMs;
  String condition;
  bool autoShot;

  bool paused = false;
  bool hasValue = false;
  String lastValue = '';
  bool condPrev = false;
  int changes = 0;
  int shots = 0;
  int polls = 0;
  int fails = 0;
  String lastError = '';
  DateTime nextAt = DateTime.now();

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'uri': uri,
        'kind': kind,
        'targetId': targetId,
        'expr': expr,
        'lib': libUri,
        'label': label,
        'intervalMs': intervalMs,
        'condition': condition,
        'autoShot': autoShot,
        'paused': paused,
        'hasValue': hasValue,
        'lastValue': lastValue,
        'changes': changes,
        'shots': shots,
        'polls': polls,
        'fails': fails,
        'lastError': lastError,
      };
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

  /// 建连进行中（防止重复 connect）。
  bool _connecting = false;

  /// 需要重建：既包括建连失败（_socket 始终为空），也包括连上后断开。
  bool get needsReconnect => !_connecting && _socket == null;
  String _remainder = '';

  /// VM 所属平台（getVM 的 operatingSystem：android/ohos/ios/macos...），
  /// 供「选中设备 → 包含该设备上的 VM」匹配。
  String? os;

  /// 应用包名（getIsolate 的 libraries 中 package:<pkg>/main.dart 的 <pkg>），
  /// 供会话选择器与日志行展示「这是哪个应用」。
  String? appName;

  /// 该会话所属 Flutter 项目根（getIsolate 的 file:// 库反推），
  /// 供「AI 调试」页把项目目录作为候选带出。
  String? projectRoot;

  Future<void> connect() async {
    if (_connecting) return;
    _connecting = true;
    try {
      // 死会话（app 已断但端口仍在）会让握手挂起，必须限时。
      final socket = await WebSocket.connect(uri).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw '连接 VM service 超时',
      );
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
      try {
        await _socket?.close();
      } catch (_) {
        // ignored
      }
      _socket = null;
    } finally {
      _connecting = false;
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
        stderr.writeln(
            '[xbume-gui] streamListen($streamId) 被拒: $uri ${jsonEncode(parsed['error'])}');
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
        final root = projectRootForLibraries(fileUris);
        if (root != null) {
          projectRoot = root;
          _pkgRootsFor(root);
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
  static final RegExp _headRe = RegExp(
      r'^(?:flutter: )?(?:Unhandled Exception: |XBErrorHandler catch error: )(.*)$');
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
    final m = RegExp(r'(file:///.+):(\d+):(\d+)\s*$').firstMatch(widget);
    final path = m == null ? null : fileUriToLocalPath(m.group(1)!);
    if (path != null) {
      final f = File(path);
      if (f.existsSync()) {
        rec['widgetFile'] = path;
        rec['widgetLine'] = int.parse(m!.group(2)!);
      }
    }
  }
  return rec;
}

/// 路径嵌入 evaluate 表达式的转义（app 端普通字符串）。
/// 与文本转义共用实现：漏掉 $ 会被 Dart 当成字符串插值执行。
String _escPath(String p) => escapeEvalPath(p);

/// 把 Storage 页改动的一行转成 app 内 SharedPreferences 的写入表达式。
/// 返回 null 表示该行不适合经 API 写回（key 无 flutter. 前缀、类型/值非法），
/// 调用方会把它算进 skipped（文件已写，重启后生效）。
/// 抽成纯函数便于单测：类型映射错了会静默写丢值。
String? sharedPrefsSetExpr(Map row) {
  final name = (row['name'] ?? '').toString();
  if (!name.startsWith('flutter.')) return null;
  final key = name.substring('flutter.'.length);
  if (key.isEmpty) return null;
  if (row['del'] == true) return "remove('${_escEvalString(key)}')";
  final v = (row['value'] ?? '').toString();
  final t = (row['type'] ?? 'string').toString();
  final String fn;
  final String lit;
  switch (t) {
    case 'boolean':
    case 'bool':
      if (v != 'true' && v != 'false') return null;
      fn = 'setBool';
      lit = v;
    case 'int':
    case 'long':
      if (int.tryParse(v) == null) return null;
      fn = 'setInt';
      lit = v;
    case 'float':
    case 'double':
    case 'real':
      if (double.tryParse(v) == null) return null;
      fn = 'setDouble';
      lit = v;
    case 'set':
    case 'array':
      final ms = v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
      fn = 'setStringList';
      lit = "<String>[${ms.map((m) => "'${_escEvalString(m)}'").join(',')}]";
    default:
      fn = 'setString';
      lit = "'${_escEvalString(v)}'";
  }
  return "$fn('${_escEvalString(key)}', $lit)";
}

/// 经 VM service 把字节写到 app 内文件：64KB 分块 writeAsBytesSync 到
/// `<file>.xbume.tmp`，逐块校验长度，完成后同目录 rename 原子替换。
/// 不把内容拼进单个 eval 字符串——XML 超长（实测 4.8MB）或含特殊字符时
/// VM 会报「Expected one expression, but found additional input」。
/// 先写临时文件再替换：中途失败不会把原文件写成半截。
Future<void> _writeAppFileBytes(
    _SandboxRpc rpc, String path, List<int> bytes) async {
  const chunk = 64 * 1024;
  final tmp = '$path.xbume.tmp';
  for (var off = 0; off < bytes.length || off == 0; off += chunk) {
    final end = off + chunk < bytes.length ? off + chunk : bytes.length;
    final csv = bytes.sublist(off, end).join(',');
    final mode = off == 0 ? 'FileMode.write' : 'FileMode.append';
    final got = (await rpc.evalString(
      "(() { final f = File('${_escPath(tmp)}'); "
      'f.writeAsBytesSync(<int>[$csv], mode: $mode); '
      'return f.lengthSync().toString(); })()',
    ))
        .trim();
    if (got != '$end') throw '写入不完整（第 $off 字节起：期望累计 $end，实际 $got）';
  }
  final r = (await rpc.evalString(
    "(() { final t = File('${_escPath(tmp)}'); "
    "try { t.renameSync('${_escPath(path)}'); return 'renamed'; } "
    "catch (_) { File('${_escPath(path)}').writeAsBytesSync(t.readAsBytesSync()); "
    "try { t.deleteSync(); } catch (_) {} return 'copied'; } })()",
  ))
      .trim();
  if (r != 'renamed' && r != 'copied') throw '写回失败：$r';
}

/// 在 app 内定位 shared_preferences 的 Dart 实例（legacy SharedPreferences /
/// SharedPreferencesWithCache / SharedPreferencesAsync 任一），返回实例 id。
/// app 从未读写过 preferences（无实例）时返回 null。
Future<String?> _findSharedPrefsInstance(_SandboxRpc rpc) async {
  const names = <String>{
    'SharedPreferences',
    'SharedPreferencesWithCache',
    'SharedPreferencesAsync',
  };
  final iso = await rpc.isolateId();
  final cls = await rpc.rawRpc('getClassList', {'isolateId': iso});
  for (final c in (cls['classes'] as List? ?? const <Object?>[])) {
    if (c is! Map) continue;
    final name = c['name']?.toString() ?? '';
    if (!names.contains(name)) continue;
    // 同名类可能来自别的库（如 app 自定义封装），只认 shared_preferences 包。
    final lib = c['library'];
    final uri = lib is Map ? (lib['uri']?.toString() ?? '') : '';
    if (!uri.contains('shared_preferences')) continue;
    final id = c['id']?.toString() ?? '';
    if (id.isEmpty) continue;
    try {
      final set = await rpc.rawRpc('getInstances', {
        'isolateId': iso,
        'objectId': id,
        'limit': 5,
      });
      for (final it in (set['instances'] as List? ?? const <Object?>[])) {
        final iid = it is Map ? it['id']?.toString() : null;
        if (iid != null && iid.isNotEmpty) return iid;
      }
    } catch (_) {
      // 类已被回收/不可扫：继续看下一个候选。
    }
  }
  return null;
}

/// 让 app 内 SharedPreferences 重新读一次存储（刷新 Dart 端缓存）。
/// legacy 用 reload()，SharedPreferencesWithCache 用 reloadCache()；
/// SharedPreferencesAsync 本身无缓存，两者都会失败。
Future<bool> _reloadSharedPrefs(_SandboxRpc rpc, String instId) async {
  final iso = await rpc.isolateId();
  for (final expr in const <String>['reload()', 'reloadCache()']) {
    try {
      final r = await rpc.rawRpc('evaluate', {
        'isolateId': iso,
        'targetId': instId,
        'expression': expr,
      });
      final t = r['type']?.toString() ?? '';
      if (t != 'Error' && t != '@Error') return true;
    } catch (_) {
      // 方法不存在：试下一个。
    }
  }
  return false;
}

/// 把用户改动的行经 app 内 SharedPreferences API 写回：同时更新 Dart 缓存与
/// 原生存储（原生层还会 flush 落盘），保存后立即生效、无需重启 app。
/// rows 项：{name, type, value} 或 {name, del: true}。
/// 返回 null 表示 app 内没有可用实例（调用方提示重启生效）。
Future<Map<String, Object?>?> _sharedPrefsLiveSync(
  _SandboxRpc rpc,
  List<Map> rows,
) async {
  final inst = await _findSharedPrefsInstance(rpc);
  if (inst == null) return null;
  final iso = await rpc.isolateId();
  Future<Map<String, Object?>> ev(String expr) => rpc.rawRpc('evaluate', {
        'isolateId': iso,
        'targetId': inst,
        'expression': expr,
      });
  // 先 reload：外部改过文件时把磁盘内容读进 Dart 缓存，避免随后 set 用旧缓存
  // 覆盖。旧版插件无 reload 时跳过，set 仍然有效。
  var reloaded = false;
  try {
    reloaded = await _reloadSharedPrefs(rpc, inst);
  } catch (_) {
    // ignored
  }
  if (reloaded) await Future<void>.delayed(const Duration(milliseconds: 250));
  final failed = <String>[];
  final skipped = <String>[];
  var applied = 0;
  String? verifyExpr;
  String? verifyWant;
  for (final row in rows) {
    final expr = sharedPrefsSetExpr(row);
    if (expr == null) {
      skipped.add((row['name'] ?? '').toString());
      continue;
    }
    try {
      final r = await ev(expr);
      final t = r['type']?.toString() ?? '';
      if (t == 'Error' || t == '@Error') {
        final msg = (r['message']?.toString() ?? '').split('\n').first;
        failed.add('${row['name']}：$msg');
        continue;
      }
      applied++;
      if (verifyExpr == null && row['del'] != true) {
        final name = (row['name'] ?? '').toString();
        final key = name.substring('flutter.'.length);
        final t2 = (row['type'] ?? 'string').toString();
        if (t2 == 'string') {
          verifyExpr = "getString('${_escEvalString(key)}')";
          verifyWant = (row['value'] ?? '').toString();
        } else if (t2 == 'int' || t2 == 'long') {
          verifyExpr = "getInt('${_escEvalString(key)}')";
          verifyWant = '${int.tryParse((row['value'] ?? '').toString())}';
        } else if (t2 == 'boolean' || t2 == 'bool') {
          verifyExpr = "getBool('${_escEvalString(key)}')";
          verifyWant = (row['value'] ?? '').toString();
        }
      }
    } catch (e) {
      failed.add('${row['name']}：$e');
    }
  }
  // 读回一项校验：能读回刚写的值才算「立即生效」。
  bool? verified;
  if (verifyExpr != null) {
    try {
      final r = await ev(verifyExpr);
      verified = r['valueAsString']?.toString() == verifyWant;
    } catch (_) {
      // ignored
    }
  }
  return <String, Object?>{
    'applied': applied,
    'failed': failed,
    'skipped': skipped,
    'reloaded': reloaded,
    'verified': verified,
  };
}

/// 「check that it really is our descendant」断言专用探针（framework.dart
/// 上下文：可访问 Element._parent/_widget、InheritedElement._dependents 等私有
/// 成员）。遍历整棵 Element 树，找出仍登记在某个 InheritedElement 的
/// _dependents 里、但沿 _parent 链已经回不到该 InheritedElement 的元素，
/// 输出继承点/失效依赖/生命周期/祖先链，用于确认依赖是在哪次树变动中失效的。
const String _depsProbeExpr =
    "(() { final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return 'NO_ROOT'; "
    "final out = StringBuffer(); var scanned = 0; var inh = 0; var broken = 0; "
    "void walk(Element e) { scanned++; "
    "if (e is InheritedElement && e.mounted) { inh++; "
    "for (final d in e._dependents.keys.toList()) { "
    "Element? a = d._parent; "
    "while (a != null && !identical(a, e)) { a = a._parent; } "
    "if (a == null) { broken++; "
    "if (broken <= 8) { "
    "final chain = <String>[]; Element? p = d; var n = 0; "
    "while (p != null && n < 6) { final w = p._widget; "
    "chain.add(w == null ? 'defunct' : w.runtimeType.toString()); p = p._parent; n++; } "
    "final ew = e._widget; final dw = d._widget; "
    "out.write('--- inh='); out.write(ew == null ? 'defunct' : ew.runtimeType.toString()); "
    "out.write(' key='); out.write(ew?.key?.toString() ?? '-'); "
    "out.write(' dep='); out.write(dw == null ? 'defunct' : dw.runtimeType.toString()); "
    "out.write(' life='); out.write(d._lifecycleState.toString()); "
    "out.write(' chain='); out.write(chain.join('<')); out.writeln(); "
    "} } } } "
    "e.visitChildren(walk); } "
    "try { root.visitChildren(walk); } catch (err) { "
    "out.write('ERR='); out.write(err.toString()); out.writeln(); } "
    "out.write('scanned='); out.write(scanned.toString()); "
    "out.write(' inherited='); out.write(inh.toString()); "
    "out.write(' broken='); out.write(broken.toString()); "
    "return out.toString(); })()";

/// P9：Element 树全量拉取表达式（binding.dart 上下文可见 WidgetsBinding/Element）。
/// 输出格式：每行 深度\u0001 类型 \u0001 key\u0001 bounds(x,y,w,h 逻辑像素，无则为空)\u0003；
/// 末尾额外跟一个空行 + dpr\u0001物理宽\u0001物理高。不用 Dart 模板字符串（避开多层转义）。
const String _wtreeExpr =
    "(() { final v = WidgetsBinding.instance.platformDispatcher.views.first; "
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
String _escEvalString(String s) => escapeEvalString(s);

// ── P10 自动化路径：场景执行引擎 ──

/// tap：GestureBinding.handlePointerEvent down+up 同点（binding.dart 上下文，
/// 实测可驱动真实 UI 导航/点击）。phys=true 时坐标为截图物理像素（除 dpr）。
/// 每次注入唯一 pointer id：PointerDownEvent 默认 pointer=0，若 down 派发中
/// 业务抛异常导致 up 未发，_hitTests 残留 pointer 0 会让后续所有 tap 撞
/// '!_hitTests.containsKey(event.pointer)' 断言永久卡死（f_jlink 实测）。
int _nextPointer() => DateTime.now().microsecondsSinceEpoch & 0x3fffffff;

/// 截图遥控白名单：只允许直接操作手势/文本，不允许 eval 等通用步骤。
const Set<String> remoteOpTypes = <String>{'tap', 'swipe', 'input'};
bool remoteOpAllowed(String type) => remoteOpTypes.contains(type);

/// 帧内注入守卫（与 MCP 侧 busyGuard 同义）。
/// VM `evaluate` 会在安全点插到应用调用栈中间执行；若此时正处于
/// build/layout/paint，改指针或改滚动位置会在布局内部触发 setState，
/// 撞 `Build scheduled during frame.` / `scroll_position.dart` 断言。
const String _autoBusyGuard =
    "final _phase = SchedulerBinding.instance.schedulerPhase; "
    "if (_phase == SchedulerPhase.persistentCallbacks || "
    "_phase == SchedulerPhase.midFrameMicrotasks) return 'BUSY'; ";

/// 注入求值：遇到 BUSY 等到下一帧重试，避免把异常抛进框架事务。
Future<String> _autoEvalInject(_SandboxRpc rpc, String lib, String expr,
    {int tries = 40}) async {
  var last = 'BUSY';
  for (var i = 0; i < tries; i++) {
    last = await rpc.evalStringOn(lib, expr);
    if (last != 'BUSY') return last;
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
  return last;
}

String _autoTapExpr(String x, String y, {bool phys = false, int pointer = 0}) {
  final pos = phys
      ? "final pos = Offset($x, $y) / WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; "
      : "final pos = Offset($x, $y); ";
  // down 派发中业务异常时仍补发 up（释放指针）并返回错误摘要；不 rethrow——
  // 异常经 FlutterError 上报时 inspector 序列化 eval 栈帧会二次炸
  // stack_frame.dart 断言，污染错误信息。
  return "(() { $_autoBusyGuard$pos"
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

/// 对比运行的一侧（一个会话）：独立步骤结果，互不干扰。
class _CompareSide {
  _CompareSide({
    required this.uri,
    required this.label,
    required this.shotPrefix,
  });

  final String uri;
  String label;
  final String shotPrefix; // 截图文件名前缀：cmp-<ts>-a / cmp-<ts>-b
  final List<_AutoStepResult> results = [];
  bool stopReq = false;
  bool done = false;
  String error = ''; // 侧级错误（如会话不可用）

  Map<String, Object?> toJson() => <String, Object?>{
        'uri': uri,
        'label': label,
        'done': done,
        'error': error,
        'results': results.map((r) => r.toJson()).toList(),
      };
}

/// 多设备并排对比：同一组步骤在两个会话上并行执行，各自独立的步骤结果。
class _CompareRunState {
  bool running = false;
  bool stopReq = false;
  String name = '';
  String runId = '';
  DateTime startedAt = DateTime.now();
  DateTime? finishedAt;
  bool shotEveryStep = true;
  _CompareSide? a;
  _CompareSide? b;

  Map<String, Object?> statusJson() => <String, Object?>{
        'running': running,
        'name': name,
        'runId': runId,
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
        'shotEveryStep': shotEveryStep,
        'a': a?.toJson(),
        'b': b?.toJson(),
      };
}

final _compare = _CompareRunState();

String get _autoScenariosDir => '$_home/.xb_ume_ide/scenarios';
String get _autoArtifactsDir => '$_home/.xb_ume_ide/scenarios/artifacts';

/// 场景名非法时的统一提示（400 响应与前端预校验共用）。
const String _autoNameError = '场景名非法：只允许中文/字母/数字/下划线/横线，长度 1-64（不能含空格、点号等）';

/// 场景名 → json 文件；名字只允许字母数字下划线中横线中文，防穿越。
File? _autoScenarioFile(String name) {
  final n = name.trim();
  if (n.isEmpty || n.length > 64) return null;
  if (!RegExp(r'^[\w\u4e00-\u9fff-]+$').hasMatch(n)) return null;
  return File('$_autoScenariosDir/$n.json');
}

/// 从 inspector 根节点树结果里取根 id（如 inspector-0）。
/// result 是 JSON 或 Dart Map 的 toString（新版/旧版 VM 不一致），两种都兼容。
String inspectorRootId(String raw) {
  try {
    final v = (jsonDecode(raw) as Map)['valueId']?.toString() ?? '';
    if (v.isNotEmpty) return v;
  } catch (_) {}
  final m = RegExp(r'valueId:\s*([A-Za-z0-9_-]+)').firstMatch(raw);
  return m?.group(1) ?? 'root';
}

/// 兜底截图：对 inspector 根节点做 toImage（纯 Dart 渲染路径，跨平台）。
/// iOS 等平台的 _flutter.screenshot 会报 Could not capture image screenshot。
Future<String> _inspectorShot(_SandboxRpc rpc) async {
  final isoId = await rpc.isolateId();
  const group = 'xb_shot';
  try {
    final tree = await rpc.rawRpc(
        'ext.flutter.inspector.getRootWidgetSummaryTree', <String, Object?>{
      'isolateId': isoId,
      'objectGroup': group,
    });
    final shot =
        await rpc.rawRpc('ext.flutter.inspector.screenshot', <String, Object?>{
      'isolateId': isoId,
      // 根渲染对象即 RenderView，尺寸已是物理像素；1.0 即原分辨率。
      'id': inspectorRootId('${tree['result'] ?? ''}'),
      'width': '10000',
      'height': '10000',
      'maxPixelRatio': '1.0',
      'debugPaint': 'false',
    });
    return (shot['result'] ?? '').toString();
  } finally {
    try {
      await rpc.rawRpc('ext.flutter.inspector.disposeGroup', <String, Object?>{
        'isolateId': isoId,
        'objectGroup': group,
      });
    } catch (_) {}
  }
}

Future<String?> _autoShot(String uri, String runId, int index) async {
  final rpc = _SandboxRpc(uri);
  try {
    // 步骤截图（失败/报告用）：_flutter.screenshot 不可用时退回 inspector toImage。
    var b64 = '';
    try {
      final r = await rpc.rawRpc('_flutter.screenshot');
      b64 = (r['data'] ?? r['screenshot'])?.toString() ?? '';
    } catch (_) {}
    if (b64.isEmpty) b64 = await _inspectorShot(rpc);
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
      // tapRef：按元素候选的 ref 反查（重跑收集表达式，索引确定），
      // 拿到逻辑像素中心后走同一套 tap 注入。相比模型看截图估坐标，
      // 不受图幅/缩放/底部导航估计偏差影响；界面已变时用 type 校验拦下。
      case 'tapRef':
        final ref = (st['ref'] as num?)?.toInt();
        if (ref == null || ref < 0) return ('', 'tapRef 需要 ref（元素候选的 #号）');
        String raw;
        try {
          raw = await rpc.evalStringOn(_kAiElemLib, _aiElementsExpr(only: ref));
        } catch (e) {
          return ('', 'tapRef 反查失败: $e');
        }
        if (raw == 'NO_ROOT') return ('', 'app 无渲染树');
        if (raw == 'NOREF') {
          return ('', '元素候选 #$ref 已不存在（界面可能已变化），请重新查看候选');
        }
        final cands = aiParseElements(raw);
        if (cands.isEmpty) return ('', '元素候选 #$ref 反查失败（响应格式异常）');
        final c = cands.first;
        final want = (st['expectType'] ?? '').toString().trim();
        if (want.isNotEmpty && want != c.type) {
          return ('', '元素 #$ref 现在是 ${c.type}（候选时是 $want），界面已变化，请改用坐标或重新决策');
        }
        final s = await _autoEvalInject(
            rpc,
            'package:flutter/src/widgets/binding.dart',
            _autoTapExpr(c.cx.toString(), c.cy.toString(),
                pointer: _nextPointer()));
        final label = c.describe();
        return (
          s == 'OK' ? '点击 $label' : '点击 $label（未生效）',
          s == 'OK'
              ? ''
              : s == 'BUSY'
                  ? '应用正在绘制帧，注入被推迟后仍未成功，请重试'
                  : (s.startsWith('ERR:')
                      ? 'tapRef 派发异常: ${s.substring(4)}'
                      : 'tapRef 注入异常: $s'),
        );
      case 'tap':
        final x = (st['x'] as num?)?.toDouble();
        final y = (st['y'] as num?)?.toDouble();
        if (x == null || y == null) return ('', 'tap 需要 x/y 数值坐标');
        final s = await _autoEvalInject(
            rpc,
            'package:flutter/src/widgets/binding.dart',
            _autoTapExpr(x.toString(), y.toString(),
                phys: (st['phys'] ?? false) == true, pointer: _nextPointer()));
        return (
          s,
          s == 'OK'
              ? ''
              : s == 'BUSY'
                  ? '应用正在绘制帧，注入被推迟后仍未成功，请重试'
                  : (s.startsWith('ERR:')
                      ? 'tap 派发异常: ${s.substring(4)}'
                      : 'tap 注入异常: $s')
        );
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
          downReply = await _autoEvalInject(
              rpc,
              ctx,
              "(() { $_autoBusyGuard"
              "final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; "
              "try { GestureBinding.instance.handlePointerEvent("
              "PointerDownEvent(pointer: $pid, position: Offset(${px(x1)}, ${px(y1)}), timeStamp: Duration(microseconds: $downUs))); } catch (e) { "
              "GestureBinding.instance.handlePointerEvent("
              "PointerUpEvent(pointer: $pid, position: Offset(${px(x1)}, ${px(y1)}))); "
              "return 'ERR:' + e.toString(); } return 'OK'; })()");
        } catch (e) {
          return ('', 'swipe down 注入失败: $e');
        }
        if (downReply != 'OK') {
          return (
            '',
            downReply == 'BUSY'
                ? '应用正在绘制帧，注入被推迟后仍未成功，请重试'
                : 'swipe down 异常: ${downReply.startsWith('ERR:') ? downReply.substring(4) : downReply}'
          );
        }
        var pmx = x1;
        var pmy = y1;
        for (var i = 1; i <= seg; i++) {
          final t = i / seg;
          final mx = x1 + (x2 - x1) * t;
          final my = y1 + (y2 - y1) * t;
          final tsUs = tsBase + (ms * 1000 * t).round();
          final moveReply = await _autoEvalInject(
              rpc,
              ctx,
              "(() { $_autoBusyGuard"
              "final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; "
              "GestureBinding.instance.handlePointerEvent("
              "PointerMoveEvent(pointer: $pid, position: Offset(${px(mx)}, ${px(my)}), "
              "delta: Offset(${px(mx)} - ${px(pmx)}, ${px(my)} - ${px(pmy)}), "
              "timeStamp: Duration(microseconds: $tsUs))); return 'OK'; })()");
          if (moveReply != 'OK') {
            await _autoEvalInject(
                rpc,
                ctx,
                "(() { $_autoBusyGuard"
                "final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; "
                "GestureBinding.instance.handlePointerEvent("
                "PointerUpEvent(pointer: $pid, position: Offset(${px(x2)}, ${px(y2)}), "
                "timeStamp: Duration(microseconds: ${tsBase + ms * 1000}))); return 'OK'; })()");
            return (
              '',
              moveReply == 'BUSY'
                  ? '应用正在绘制帧，注入被推迟后仍未成功，请重试'
                  : 'swipe move 异常: $moveReply'
            );
          }
          pmx = mx;
          pmy = my;
          await Future.delayed(Duration(milliseconds: moveMs));
        }
        await _autoEvalInject(
            rpc,
            ctx,
            "(() { $_autoBusyGuard"
            "final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; "
            "GestureBinding.instance.handlePointerEvent("
            "PointerUpEvent(pointer: $pid, position: Offset(${px(x2)}, ${px(y2)}), timeStamp: Duration(microseconds: ${tsBase + ms * 1000}))); return 'OK'; })()");
        return (
          'swipe (${x1.round()},${y1.round()})->(${x2.round()},${y2.round()})',
          ''
        );
      case 'input':
        final text = (st['text'] ?? '').toString();
        // _instance/_currentConnection 是 text_input.dart 库内私有，
        // 必须在该库上下文 eval（binding.dart 上下文会 Member not found）。
        final s = await rpc.evalStringOn(
            'package:flutter/src/services/text_input.dart',
            _autoInputExpr(text));
        return (
          s,
          s == 'OK'
              ? ''
              : s == 'NO_CONN'
                  ? '无焦点输入框（先 tap 输入框）'
                  : '注入异常: $s'
        );
      case 'wait':
        final ms = (st['ms'] as num?)?.toInt() ?? 500;
        await Future.delayed(Duration(milliseconds: ms.clamp(0, 60000)));
        return ('waited $ms ms', '');
      case 'back':
        final s = await rpc.evalStringOn(
            'package:flutter/src/widgets/navigator.dart', _autoRoutesExpr);
        if (s == 'NO_ROOT' || s == 'NO_NAV') return (s, '无路由栈');
        final names = s.split(',').where((e) => e.isNotEmpty).toList();
        if (names.length <= 1) {
          return ('${names.length} route', '已是最后一个路由，无法返回');
        }
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
            'package:flutter/src/widgets/binding.dart',
            _autoAssertVisibleExpr(t));
        return (
          s,
          s == 'FOUND'
              ? ''
              : s == 'NOT_FOUND'
                  ? '树中不存在可见的 $t'
                  : '查找异常: $s'
        );
      case 'assertRoute':
        final name = (st['name'] ?? '').toString();
        final s = await rpc.evalStringOn(
            'package:flutter/src/widgets/navigator.dart', _autoRoutesExpr);
        if (s == 'NO_ROOT' || s == 'NO_NAV') return (s, '无路由栈');
        final names = s.split(',').where((e) => e.isNotEmpty).toList();
        final top = names.isEmpty ? '' : names.last;
        return (
          top,
          name.isEmpty || top.contains(name) ? '' : '栈顶路由 $top 不匹配 $name'
        );
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
        return (
          s,
          expect.isEmpty || s.contains(expect) ? '' : '期望包含「$expect」实际「$s」'
        );
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
          return (
            hit.isEmpty ? '未命中' : '命中: ${hit.take(3).join(' / ')}',
            hit.isEmpty ? '页面文本中未找到「$contains」' : ''
          );
        }
        final bad = texts.where((e) => e.contains(notContains)).toList();
        return (
          bad.isEmpty ? '未出现「$notContains」' : '仍存在: ${bad.take(3).join(' / ')}',
          bad.isEmpty ? '' : '页面文本中不应出现「$notContains」'
        );
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
        final matched = recs
            .where((e) =>
                e['url'].toString().contains(url) &&
                (method.isEmpty ||
                    e['method'].toString().toUpperCase() == method))
            .toList();
        final desc = matched
            .map((e) => '${e['method']} ${e['url']} ${e['statusCode']}')
            .join(' · ');
        if (neg) {
          return (
            matched.isEmpty ? '无匹配（符合预期）' : desc,
            matched.isEmpty ? '' : '不应出现的请求出现了：$desc'
          );
        }
        return (
          matched.isEmpty ? '窗口内 ${recs.length} 条请求，无匹配' : desc,
          matched.isEmpty
              ? '窗口内无匹配请求（urlContains=$url${method.isEmpty ? '' : ' method=$method'}）'
              : ''
        );
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
          final hit =
              hits.firstWhere((e) => e.contains(contains), orElse: () => '');
          return (
            hit.isEmpty ? '窗口内 ${hits.length} 条无匹配' : hit,
            hit.isEmpty ? '日志中未找到「$contains」' : ''
          );
        }
        final bad = hits.where((e) => e.contains(notContains)).take(3).toList();
        return (
          bad.isEmpty ? '未出现「$notContains」' : bad.join(' | '),
          bad.isEmpty ? '' : '日志中不应出现「$notContains」'
        );
      default:
        return (
          '',
          '未知步骤类型 $type（支持 tap/swipe/input/wait/back/navigate/assertVisible/assertRoute/assertInstance/assertText/assertRequest/assertLog/eval）'
        );
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
    return await rpc.evalStringOn(
        'package:flutter/src/widgets/navigator.dart', expr);
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

/// 对比模式一侧的执行：与 _autoRunSteps 同语义，但结果写入本侧、
/// 每一步都可截图（默认开，用于两测截图并排），失败必截图。
Future<void> _compareRunSide(
  _CompareSide side,
  List steps, {
  required bool continueOnFail,
  required bool shotEveryStep,
}) async {
  for (final raw in steps) {
    final st = raw is Map<String, dynamic> ? raw : <String, dynamic>{};
    final type = (st['type'] ?? '?').toString();
    final r = _AutoStepResult(
        side.results.length,
        type,
        (st['expect'] ??
                (st['type'] == 'assertVisible'
                    ? '可见 ${st['widget'] ?? ''}'
                    : ''))
            .toString());
    side.results.add(r);
    if (side.stopReq || _compare.stopReq) {
      r
        ..status = 'skip'
        ..error = '用户停止';
      continue;
    }
    final sw = Stopwatch()..start();
    try {
      final (actual, err) = await _autoExecStep(side.uri, st);
      r.ms = sw.elapsedMilliseconds;
      r.actual = actual;
      if (err.isNotEmpty) {
        r
          ..status = 'fail'
          ..error = err;
        r.shot = await _autoShot(side.uri, side.shotPrefix, r.index);
        if (!continueOnFail) {
          side.stopReq = true;
          continue;
        }
      } else {
        r.status = 'pass';
        if (shotEveryStep) {
          r.shot = await _autoShot(side.uri, side.shotPrefix, r.index);
        }
      }
    } catch (e) {
      r.ms = sw.elapsedMilliseconds;
      r
        ..status = 'fail'
        ..error = '$e';
    }
    final waitAfter = (st['waitAfter'] as num?)?.toInt() ?? 700;
    if (waitAfter > 0) await Future.delayed(Duration(milliseconds: waitAfter));
  }
  side.done = true;
}

/// 并行跑两侧：任一侧异常不影响另一侧（各自内部已兜底）。
Future<void> _compareRunSteps({
  required String uriA,
  required String uriB,
  required String labelA,
  required String labelB,
  required String name,
  required List steps,
  bool continueOnFail = true,
  bool shotEveryStep = true,
}) async {
  final runId = 'cmp-${DateTime.now().millisecondsSinceEpoch}';
  _compare
    ..running = true
    ..stopReq = false
    ..name = name
    ..runId = runId
    ..startedAt = DateTime.now()
    ..finishedAt = null
    ..shotEveryStep = shotEveryStep
    ..a = _CompareSide(uri: uriA, label: labelA, shotPrefix: '$runId-a')
    ..b = _CompareSide(uri: uriB, label: labelB, shotPrefix: '$runId-b');
  try {
    await Future.wait(<Future<void>>[
      _compareRunSide(_compare.a!, steps,
          continueOnFail: continueOnFail, shotEveryStep: shotEveryStep),
      _compareRunSide(_compare.b!, steps,
          continueOnFail: continueOnFail, shotEveryStep: shotEveryStep),
    ]);
  } finally {
    _compare
      ..running = false
      ..finishedAt = DateTime.now();
  }
}

// ── P11 AI 驱动：自然语言目标 → 截图→AI→步骤→执行 循环 ─────────────────

String get _aiConfigPath => '$_home/.xb_ume_ide/ai_config.json';

/// AI 目标历史（下拉选择复用）：去重、最新在前、上限 20 条。
List<String> _aiGoalsLoad() {
  try {
    final j =
        jsonDecode(File('$_home/.xb_ume_ide/ai_goals.json').readAsStringSync());
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
        'elements': b(c['elements']),
      };
    }
  } catch (_) {}
  return <String, bool>{
    'routes': true,
    'text': true,
    'net': true,
    'log': true,
    'elements': true,
  };
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
  String ctxBrief = ''; // 本轮上下文摘要（路由/页面文本/网络/日志），供结束后 AI 总结取证
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
  DateTime? endedAt; // 运行结束时间（报告总耗时用）
  int logCursorMs = 0; // 增量日志游标（上一轮收集到的最后一条 rcvMs）
  Map<String, Object?>? summary; // 结束后 AI 生成的总结（结构化 JSON）
  bool summarizing = false; // 总结生成中（前端继续轮询，不提前收尾）
  String summaryError = ''; // 总结未生成的原因（未配置/调用失败/解析失败）
  int summaryMs = 0; // 总结耗时
  String summaryModel = ''; // 生成总结的模型名
  Map<String, Object?> statusJson() => <String, Object?>{
        'running': running,
        'done': done,
        'goal': goal,
        'cur': cur,
        'rounds': rounds.map((r) => r.toJson()).toList(),
        'startedAt': startedAt.toIso8601String(),
        'summarizing': summarizing,
        'summary': summary,
        'summaryError': summaryError,
        'summaryMs': summaryMs,
        'summaryModel': summaryModel,
      };
}

final _ai = _AiRunState();

const int _aiMaxStepsPerRound = 5;
const int _aiMaxRetries = 3; // AI 调用/回复解析失败的单轮重试上限（退避 2s/4s/6s）
const Set<String> _aiAllowedStepTypes = {
  'tap',
  'tapRef',
  'swipe',
  'input',
  'wait',
  'back',
  'assertVisible',
  'assertInstance',
  'eval',
  'assertText',
  'assertRequest',
  'assertLog',
};

const String _aiSystemPrompt = '''你是 Flutter app 的 UI 自动化操作员。你会看到 app 当前截图和操作目标，
需要返回 JSON 指令驱动 UI 完成目标。
可用步骤类型（坐标均为截图的物理像素，与截图分辨率一致）：
- {"type":"tap","x":整数,"y":整数} 点击
- {"type":"tapRef","ref":整数,"expectType":"候选里的类型"} 按元素候选的 ref 点击（推荐：比坐标准，expectType 选填用于校验界面是否已变化；不可再写 type，否则与步骤类型撞键）
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
3. 优先用「元素候选」里的 ref 点击（比截图估坐标稳）；候选中找不到目标时才用截图估坐标，坐标基于给定的截图分辨率，(0,0) 在左上角、右下角约 (宽,高)；底部导航栏贴在截图底边（y 接近图像高度），不在屏幕中部。
4. 连续两轮界面无变化时必须换策略（换坐标/滑动/返回）。
5. 目标已达成时返回 {"done":true,"think":"...","steps":[]}。
6. 步骤失败时分析原因（元素不在/坐标偏/需先滚动），下一轮修正。
7. 消息里会附「结构化上下文」（路由栈/页面文本/网络请求/增量日志/元素候选）：判断状态是否变化、请求是否发出、列表是否刷新、有无报错等数据层问题时，优先用这些证据与 assertText/assertRequest/assertLog 断言；点哪个元素优先看元素候选的 ref 与 bounds，截图只用于确认视觉效果。
8. 如果目标包含重复次数、成功率或统计类要求（如「连续测 20 次」），每轮 think 必须写明当前进度与本次结果，例如「第 5/20 次：播放成功」，便于结束后按记录统计。''';

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

/// 元素候选收集表达式所在库：与点截图反查（_wpickExpr）同源，
/// 该库可见 inspector 的 InspectorSerializationDelegate / WidgetInspectorService，
/// 才能拿到控件 creationLocation（业务源码位置）。
const String _kAiElemLib =
    'package:xb_ume/src/core/xb_ume_widget_spacing_calculator.dart';

/// 元素候选收集表达式（calculator 库上下文）。
///
/// 输出（行分隔 \u0003、字段分隔 \u0001）：
///   首行 META\u0001dpr\u0001物理宽\u0001物理高
///   之后每行 ref\u0001类型\u0001文本\u0001l,t,w,h（逻辑像素）\u0001源码文件名:行
/// [only] >= 0 时只输出该 ref（tapRef 反查用，其余元素不序列化源码）。
///
/// 只收「能点的 / 有文字的」元素，面积超过屏幕 70% 的容器（整页 InkWell 之类）
/// 会挤掉真正的小控件，直接排除；同一文本（无文本时按类型）同一 bounds 去重。
String _aiElementsExpr({int limit = 50, int srcLimit = 20, int only = -1}) =>
    "(() { final v = WidgetsBinding.instance.platformDispatcher.views.first; "
    "final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return 'NO_ROOT'; "
    "final sep = String.fromCharCode(1); final row = String.fromCharCode(3); "
    "final sw = v.physicalSize.width / v.devicePixelRatio; "
    "final sh = v.physicalSize.height / v.devicePixelRatio; "
    "final maxArea = sw * sh * 0.7; "
    // 图标字形是私有区字符（BMP U+E000..U+F8FF、增补平面 U+F0000+），
    // 不是用户可读文本：不剔除会让一排图标排在候选表最前，模型误当成可点目标。
    "String clean(String s) { final sb = StringBuffer(); "
    "for (final r in s.runes) { if (r < 32 || (r >= 0xE000 && r <= 0xF8FF) "
    "|| r >= 0xF0000 || r == 0x200B || r == 0x200C || r == 0x200D "
    "|| r == 0xFEFF) continue; "
    "sb.writeCharCode(r); } return sb.toString().trim(); } "
    "bool act(String t) { return t.contains('Button') || t.contains('InkWell') "
    "|| t.contains('GestureDetector') || t.contains('TextField') "
    "|| t.contains('EditableText') || t.contains('ListTile') "
    "|| t.contains('Switch') || t.contains('Checkbox') || t.contains('Radio') "
    "|| t.contains('Slider') || t.contains('Chip') || t.contains('Tab') "
    "|| t.contains('Dismissible') || t.contains('Dropdown') "
    "|| t == 'Text' || t == 'RichText' || t == 'Icon'; } "
    "String txt(Element e) { final t = e.widget.runtimeType.toString(); "
    "try { if (t == 'Text') { final d = (e.widget as dynamic).data; "
    "if (d is String) return d; "
    "final tp = (e.widget as dynamic).textSpan; "
    "if (tp is TextSpan) return tp.toPlainText(); } "
    "else if (t == 'RichText') { final tp = (e.widget as dynamic).text; "
    "if (tp is TextSpan) return tp.toPlainText(); } "
    "else if (t == 'EditableText') { "
    "final c = (e.widget as dynamic).controller; "
    "final s = c == null ? null : c.text; if (s is String) return s; } "
    "} catch (_) {} return ''; } "
    // 交互容器自身没有文字：在子树浅层（<=3）里找第一个非空文本当标签
    "String inner(Element e) { final q = <Element>[]; final dq = <int>[]; "
    "e.visitChildren((Element c) { q.add(c); dq.add(0); }); var n = 0; "
    "while (q.isNotEmpty && n < 40) { n++; final c = q.removeAt(0); "
    "final d = dq.removeAt(0); final tx = clean(txt(c)); "
    "if (tx.isNotEmpty) return tx; "
    "if (d < 3) { final ks = <Element>[]; c.visitChildren(ks.add); "
    "for (final k in ks) { q.add(k); dq.add(d + 1); } } } return ''; } "
    "String loc(Element e) { try { final jm = e.toDiagnosticsNode().toJsonMap("
    "InspectorSerializationDelegate(service: WidgetInspectorService.instance, "
    "includeProperties: false, subtreeDepth: 1)); "
    "final lo = jm['creationLocation']; "
    "if (lo is Map) { final f = (lo['file'] ?? '').toString(); "
    "if (f.isNotEmpty) { var s = f; final i = s.lastIndexOf('/'); "
    "if (i >= 0) s = s.substring(i + 1); "
    "final ln = (lo['line'] as num?)?.toInt() ?? 0; "
    "return s + ':' + ln.toString(); } } } catch (_) {} return ''; } "
    "final rows = <List<Object>>[]; final seen = <String>{}; "
    "void visit(Element e) { "
    "final t = e.widget.runtimeType.toString(); final r = e.renderObject; "
    "if (act(t) && r is RenderBox && r.attached && r.hasSize) { "
    "final tl = r.localToGlobal(Offset.zero); "
    "final w = r.size.width; final h = r.size.height; "
    "if (w >= 4 && h >= 4 && w * h <= maxArea "
    "&& tl.dx >= -2 && tl.dy >= -2 && tl.dx <= sw && tl.dy <= sh) { "
    "final l = tl.dx.round(); final tp0 = tl.dy.round(); "
    "final wr = w.round(); final hr = h.round(); "
    "var tx = clean(txt(e)); "
    "if (tx.isEmpty) { tx = inner(e); } "
    "if (tx.length > 60) { tx = tx.substring(0, 60); } "
    // 同一文本同一位置只留 DFS 先到的那个：Text 是 RichText 的父节点，
    // 先到 → 保留语义更清楚的 Text，子 RichText 被去重掉。
    "final key = (tx.isEmpty ? t : tx) + '|' + l.toString() + ',' "
    "+ tp0.toString() + ',' + wr.toString() + ',' + hr.toString(); "
    "if (seen.add(key)) { rows.add(<Object>[t, tx, l, tp0, wr, hr, e, '']); } } } "
    "final kids = <Element>[]; e.visitChildren(kids.add); "
    "for (var i = kids.length - 1; i >= 0; i--) { visit(kids[i]); } } "
    "visit(root); "
    "rows.sort((a, b) { final ta = (a[1] as String).isEmpty ? 1 : 0; "
    "final tb = (b[1] as String).isEmpty ? 1 : 0; "
    "if (ta != tb) return ta.compareTo(tb); "
    "final c = (a[0] as String).compareTo(b[0] as String); "
    "if (c != 0) return c; "
    "final ca = a[3] as int; final cb = b[3] as int; "
    "if (ca != cb) return ca.compareTo(cb); "
    "return (a[2] as int).compareTo(b[2] as int); }); "
    "final n = rows.length < $limit ? rows.length : $limit; "
    "if ($only >= 0 && $only >= n) return 'NOREF'; "
    "final out = StringBuffer(); out.write('META'); out.write(sep); "
    "out.write(v.devicePixelRatio.toString()); out.write(sep); "
    "out.write(v.physicalSize.width.round().toString()); out.write(sep); "
    "out.write(v.physicalSize.height.round().toString()); out.write(row); "
    "var srcs = 0; "
    "for (var i = 0; i < n; i++) { if ($only >= 0 && i != $only) continue; "
    "final r0 = rows[i]; var src = ''; "
    "final wantSrc = $only >= 0 || (srcs < $srcLimit && (r0[1] as String).isNotEmpty); "
    "if (wantSrc) { src = loc(r0[6] as Element); srcs++; } "
    "out.write(i.toString()); out.write(sep); out.write(r0[0] as String); "
    "out.write(sep); out.write(r0[1] as String); out.write(sep); "
    "out.write((r0[2] as int).toString()); out.write(','); "
    "out.write((r0[3] as int).toString()); out.write(','); "
    "out.write((r0[4] as int).toString()); out.write(','); "
    "out.write((r0[5] as int).toString()); out.write(sep); "
    "out.write(src); out.write(row); } "
    "return out.toString(); })()";

/// AI 元素候选（bounds 为逻辑像素，[cx]/[cy] 为中心点）。
class AiElementCandidate {
  AiElementCandidate({
    required this.ref,
    required this.type,
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.src,
  });

  final int ref;
  final String type;
  final String text;
  final int left;
  final int top;
  final int width;
  final int height;
  final String src;

  double get cx => left + width / 2;
  double get cy => top + height / 2;

  /// 给模型看的一行：ref/类型/"文本"/bounds/源码。
  String describe() => '#$ref ${text.isEmpty ? type : '$type "$text"'} '
      '($left,$top $width×$height)${src.isEmpty ? '' : ' ← $src'}';
}

/// 解析 [_aiElementsExpr] 输出；无法解析的行跳过（不因一个坏行丢掉整批）。
List<AiElementCandidate> aiParseElements(String raw) {
  final out = <AiElementCandidate>[];
  for (final line in raw.split('\u0003')) {
    if (line.isEmpty || line.startsWith('META')) continue;
    final p = line.split('\u0001');
    if (p.length < 4) continue;
    final ref = int.tryParse(p[0]);
    final box = p[3].split(',');
    if (ref == null || box.length < 4) continue;
    final l = int.tryParse(box[0]);
    final t = int.tryParse(box[1]);
    final w = int.tryParse(box[2]);
    final h = int.tryParse(box[3]);
    if (l == null || t == null || w == null || h == null) continue;
    out.add(AiElementCandidate(
      ref: ref,
      type: p[1],
      text: p[2],
      left: l,
      top: t,
      width: w,
      height: h,
      src: p.length > 4 ? p[4] : '',
    ));
  }
  return out;
}

/// 拉取 app 端 network 记录（xb_ume core 库 eval，与 /api/network 同源），
/// 可按时间窗过滤；app 未接入 network 模块时在此抛异常由调用方标 N/A。
Future<List<Map<String, Object?>>> _aiNetRecords(String uri,
    {DateTime? since, int limit = 8}) async {
  final rpc = _SandboxRpc(uri);
  try {
    await rpc.libraryId('package:xb_ume/src/core/xb_ume.dart');
    final cutoffExpr = since == null
        ? ''
        : "final c = DateTime.parse('${since.toIso8601String()}'); ";
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
  if (ctx['routes'] == true || ctx['text'] == true || ctx['elements'] == true) {
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
      if (ctx['elements'] == true) {
        try {
          final raw = await rpc.evalStringOn(_kAiElemLib, _aiElementsExpr());
          final cands = aiParseElements(raw);
          if (cands.isEmpty) {
            out.write('元素候选：无（树里没有可识别控件，请按截图定位）\n');
          } else {
            out.write('元素候选（ref 可直接用于 tapRef；bounds 为逻辑像素）：\n');
            for (final c in cands) {
              out.write('- ${c.describe()}\n');
            }
          }
        } catch (_) {
          out.write('元素候选：N/A\n');
        }
      }
    } finally {
      await rpc.close();
    }
  }
  if (ctx['net'] == true) {
    try {
      final recs = await _aiNetRecords(uri, since: _ai.startedAt);
      out.write(recs.isEmpty ? '最近网络请求（本次运行以来）：无\n' : '最近网络请求（本次运行以来）：\n');
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
/// [source] 非空时只保留该会话来源（Flutter 日志的 tag 即会话标签），
/// 供异常 AI 归因过滤掉其他 app/设备的无关日志。
(String, int) _aiLogDelta(int cursorMs, {String? source}) {
  final kw = RegExp('error|exception|fail|crash', caseSensitive: false);
  final all = _guiLogBuffer.where((e) {
    final ms = (e['rcvMs'] as num?)?.toInt() ?? 0;
    if (ms < cursorMs) return false;
    if (source != null &&
        source.isNotEmpty &&
        (e['tag'] ?? '').toString() != source) {
      return false;
    }
    return true;
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

// ---------------------------------------------------------------------------
// 异常 AI 归因
// ---------------------------------------------------------------------------

/// 系统提示：约束输出结构与引用来源，避免模型编造文件/行号。
const String _excAiSystemPrompt = '你是资深 Flutter 调试专家。请根据给定的异常、'
    '调用栈、用户代码源码片段与运行上下文做根因分析。用中文纯文本回答'
    '（不要输出 **、#、``` 等 Markdown 标记），结构固定：\n'
    '1. 结论：一句话说明最可能的根因；\n'
    '2. 定位：引用给出的文件:行与相关代码，说明异常如何发生；\n'
    '3. 修复建议：给出具体改法，必要时附最小代码片段；\n'
    '4. 需要补充：信息不足时列出还需查看的日志或代码。\n'
    '只能引用材料中出现的文件与行号，不要编造；若无法确定，明确说明假设。';

/// 读取源码片段：目标行前后各若干行，目标行以 `>` 标记，带行号。
/// 文件不存在/读取失败/过大时返回空串（AI 分析降级，不影响异常展示）。
String excSourceSnippet(String path, int line,
    {int before = 12, int after = 18}) {
  try {
    final f = File(path);
    if (!f.existsSync() || f.lengthSync() > 2 * 1024 * 1024) return '';
    final lines = f.readAsLinesSync();
    if (lines.isEmpty) return '';
    final center = line.clamp(1, lines.length);
    final start = (center - before).clamp(1, lines.length);
    final end = (center + after).clamp(1, lines.length);
    final sb = StringBuffer();
    for (var i = start; i <= end; i++) {
      sb.write(i == center ? '>' : ' ');
      sb.write(i.toString().padLeft(5));
      sb.write('  ');
      sb.write(lines[i - 1]);
      sb.write('\n');
    }
    return sb.toString();
  } catch (_) {
    return '';
  }
}

/// 栈帧对应的本机文件：优先已解析的 file，其次按 package: 补解析。
String _excFrameFile(Map f) {
  final file = f['file']?.toString() ?? '';
  if (file.isNotEmpty) return file;
  final uri = f['uri']?.toString() ?? '';
  if (uri.isEmpty) return '';
  return _resolveLibraryFile(uri) ?? '';
}

/// 从栈帧中挑最多 5 个用户代码文件，截取目标行附近源码。
/// Flutter SDK / pub-cache / 构建产物默认跳过，只有全是框架帧时才回退取用。
String _excBuildSnippets(List<Map<String, Object?>> frames) {
  final sb = StringBuffer();
  final seen = <String>{};
  var count = 0;
  // Flutter SDK 路径随安装目录而异（flutter/packages、flutter_flutter/packages…），
  // 用正则匹配 SDK 包目录，避免把框架源码当用户代码。
  final sdkPackage = RegExp(
      r'/flutter[^/]*/packages/(flutter|flutter_test|flutter_web_plugins)/');
  bool framework(String file) =>
      file.contains('/flutter/bin/cache/') ||
      file.contains('/.pub-cache/') ||
      file.contains('/.dart_tool/flutter_build/') ||
      sdkPackage.hasMatch(file);
  void take(Map f) {
    if (count >= 5) return;
    final file = _excFrameFile(f);
    final line = (f['line'] as num?)?.toInt() ?? 0;
    if (file.isEmpty || line <= 0 || !seen.add(file)) return;
    final snippet = excSourceSnippet(file, line);
    if (snippet.isEmpty) return;
    sb.writeln('--- ${f['raw'] ?? '$file:$line'} ---');
    sb.write(snippet);
    sb.writeln();
    count++;
  }

  for (final f in frames) {
    if (_excFrameFile(f).isNotEmpty && !framework(_excFrameFile(f))) take(f);
  }
  if (count == 0) {
    for (final f in frames) {
      if (_excFrameFile(f).isNotEmpty) take(f);
    }
  }
  return sb.toString();
}

/// 组装异常分析的 user 消息（纯文本，无截图）。
String excBuildAnalysisUserPrompt({
  required Map<String, Object?> rec,
  required String snippets,
  required String context,
  required String logs,
  int maxFrames = 12,
}) {
  final summary = rec['summary']?.toString() ?? '';
  final desc = rec['desc']?.toString() ?? '';
  final widget = rec['widget']?.toString() ?? '';
  final widgetFile = rec['widgetFile']?.toString() ?? '';
  final widgetLine = (rec['widgetLine'] as num?)?.toInt() ?? 0;
  final channel =
      rec['channel'] == 'framework' ? '框架异常（FlutterError）' : '未捕获异常';
  final frames = <Map<String, Object?>>[];
  for (final f in (rec['stack'] as List? ?? const <Object?>[])) {
    if (f is Map) frames.add(Map<String, Object?>.from(f));
  }
  final b = StringBuffer()
    ..writeln('请分析以下 Flutter 异常，给出根因和修复建议。')
    ..writeln()
    ..writeln('【异常信息】')
    ..writeln('通道：$channel')
    ..writeln('摘要：${summary.isEmpty ? '（无）' : summary}');
  if (desc.isNotEmpty) b.writeln('描述：$desc');
  if (widget.isNotEmpty) {
    b.write('相关 Widget：$widget');
    if (widgetFile.isNotEmpty) {
      b.write('（$widgetFile${widgetLine > 0 ? ':$widgetLine' : ''}）');
    }
    b.writeln();
  }
  final app = rec['app']?.toString() ?? '';
  final os = rec['os']?.toString() ?? '';
  final count = rec['count'] ?? 1;
  b.writeln('应用：${app.isEmpty ? '未知' : app}'
      '；平台：${os.isEmpty ? '未知' : os}；出现次数：$count');
  b.writeln();
  b.writeln('【调用栈】');
  if (frames.isEmpty) {
    b.writeln('（无调用栈）');
  } else {
    for (var i = 0; i < frames.length && i < maxFrames; i++) {
      final raw = frames[i]['raw']?.toString();
      b.writeln(raw != null && raw.isNotEmpty
          ? raw
          : '#$i ${frames[i]['method'] ?? ''} (${frames[i]['uri'] ?? ''}:${frames[i]['line'] ?? 0})');
    }
    if (frames.length > maxFrames) {
      b.writeln('...（另有 ${frames.length - maxFrames} 帧省略）');
    }
  }
  b.writeln();
  b.writeln('【相关源码片段】');
  b.write(snippets.isEmpty ? '（未能解析到本机源码，请仅依据栈帧与上下文推断）\n' : snippets);
  b.writeln();
  b.writeln('【异常发生时运行上下文】');
  b.write(context.isEmpty ? '（无）\n' : context);
  b.writeln();
  b.writeln('【异常前后日志】');
  b.write(logs.isEmpty ? '无\n' : logs);
  return b.toString();
}

/// 回连异常来源会话取路由/页面/网络上下文；失败只降级不中断分析。
Future<Map<String, Object?>> _excCollectContext(String uri, int excTs) async {
  final out = StringBuffer();
  var hasRoutes = false;
  var netCount = 0;
  if (uri.isEmpty) {
    out.writeln('VM 会话不可用（异常来源会话已断开），缺少路由/页面/网络上下文。');
    return <String, Object?>{
      'text': out.toString(),
      'routes': false,
      'network': 0,
    };
  }
  final rpc = _SandboxRpc(uri);
  try {
    try {
      final s = await rpc.evalStringOn(
          'package:flutter/src/widgets/navigator.dart', _autoRoutesExpr);
      final names = (s == 'NO_ROOT' || s == 'NO_NAV')
          ? <String>[]
          : s.split(',').where((e) => e.isNotEmpty).toList();
      hasRoutes = names.isNotEmpty;
      out.writeln('异常发生时的路由栈：${names.isEmpty ? 'N/A' : names.join(' > ')}');
    } catch (_) {
      out.writeln('路由栈：N/A');
    }
    try {
      final s = await rpc.evalStringOn(
          'package:flutter/src/widgets/binding.dart', _aiPageTextExpr());
      final items = s.split('\u0002').where((e) => e.isNotEmpty).toList();
      var joined = items.join(' / ');
      if (joined.length > 300) joined = joined.substring(0, 300);
      out.writeln('页面文本：${items.isEmpty ? 'N/A' : joined}');
    } catch (_) {
      out.writeln('页面文本：N/A');
    }
  } finally {
    await rpc.close();
  }
  try {
    final recs = await _aiNetRecords(uri,
        since: DateTime.fromMillisecondsSinceEpoch(excTs - 30000), limit: 10);
    netCount = recs.length;
    out.writeln(recs.isEmpty ? '异常前 30s 网络请求：无' : '异常前 30s 网络请求：');
    for (final e in recs) {
      out.writeln(
          '- ${e['method']} ${e['url']} ${e['statusCode']} ${e['status']}');
    }
  } catch (_) {
    out.writeln('网络请求：N/A（app 未接入 network 模块）');
  }
  return <String, Object?>{
    'text': out.toString(),
    'routes': hasRoutes,
    'network': netCount,
  };
}

/// 异常 AI 归因主流程：挑源码片段 + 收集上下文 + 调模型。
Future<Map<String, Object?>> _excAnalyze(
    Map<String, Object?> rec, String uri) async {
  final frames = <Map<String, Object?>>[];
  for (final f in (rec['stack'] as List? ?? const <Object?>[])) {
    if (f is Map) frames.add(Map<String, Object?>.from(f));
  }
  final snippets = _excBuildSnippets(frames);
  final excTs =
      (rec['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
  final ctx = await _excCollectContext(uri, excTs);
  final (logs, _) =
      _aiLogDelta(excTs - 15000, source: rec['source']?.toString() ?? '');
  final user = excBuildAnalysisUserPrompt(
    rec: rec,
    snippets: snippets,
    context: (ctx['text'] ?? '').toString(),
    logs: logs,
  );
  final reply = await _aiCall(<Map<String, Object?>>[
    <String, Object?>{'role': 'system', 'content': _excAiSystemPrompt},
    <String, Object?>{'role': 'user', 'content': user},
  ]);
  final logCount = logs == '无'
      ? 0
      : logs.split('\n').where((l) => l.startsWith('- ')).length;
  return <String, Object?>{
    'ok': true,
    'analysis': reply,
    'meta': <String, Object?>{
      'sources': snippets.isEmpty ? 0 : snippets.split('--- ').length - 1,
      'frames': frames.length,
      'routes': ctx['routes'] == true,
      'network': ctx['network'] ?? 0,
      'logs': logCount,
    },
  };
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
    ..summary = null
    ..summarizing = false
    ..summaryError = ''
    ..summaryMs = 0
    ..summaryModel = ''
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
        iw = (pngBytes[16] << 24) |
            (pngBytes[17] << 16) |
            (pngBytes[18] << 8) |
            pngBytes[19];
        ih = (pngBytes[20] << 24) |
            (pngBytes[21] << 16) |
            (pngBytes[22] << 8) |
            pngBytes[23];
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
      // 留存本轮上下文（路由/文本/网络/日志）作事后总结的证据；只存摘要，
      // 避免报告运行时内存无限增长。
      r.ctxBrief = '$ctxStr'
          '${ctx['log'] == true && logStr != '无' ? '增量日志：$logStr' : ''}';
      if (r.ctxBrief.length > 1600) {
        r.ctxBrief = '${r.ctxBrief.substring(0, 1600)}…';
      }
      // 3) 组消息：system + 目标 + 历史摘要 + 截图
      final hist = StringBuffer();
      for (final p in _ai.rounds) {
        if (p.round == r.round) continue;
        hist.write(
            '轮${p.round}: ${p.error.isNotEmpty ? '异常=${p.error}' : 'think=${p.think}'}; ');
        for (final sr in p.results) {
          hist.write(
              '${sr.type}=${sr.status == 'pass' ? 'OK' : '失败:${sr.error.isEmpty ? sr.actual : sr.error}'}; ');
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
          'image_url': <String, Object?>{
            'url': 'data:image/png;base64,$failB64'
          },
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
        final rawSteps =
            obj['steps'] is List ? obj['steps'] as List : <Object?>[];
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
        final res = _AutoStepResult(r.results.length,
            (st['type'] ?? '?').toString(), (st['expect'] ?? '').toString());
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
            failB64 = base64Encode(
                File('$_autoArtifactsDir/${res.shot}').readAsBytesSync());
          }
          break;
        }
        res.status = 'pass';
        final waitAfter = (st['waitAfter'] as num?)?.toInt() ?? 700;
        if (waitAfter > 0) {
          await Future.delayed(Duration(milliseconds: waitAfter));
        }
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
  } finally {
    _ai.running = false;
    _ai.endedAt = DateTime.now();
    // 结束即落盘测试报告（自包含 HTML，截图 base64 内嵌），GUI 重启后
    // 仍可通过 /api/ai/report 下载当前运行Id对应的报告。
    if (_ai.rounds.isNotEmpty) {
      // 先落盘基础报告（不含总结），保证总结调用失败/超时也能下载；
      // 生成总结后重写为最终版（证明执行结果是否满足指令要求）。
      _saveAiReport();
      await _aiSummarize();
      _saveAiReport();
    }
  }
}

/// 将当前运行报告落盘（失败不抛异常，不影响主流程）。
void _saveAiReport() {
  try {
    final dir = Directory('$_autoScenariosDir/reports');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('${dir.path}/${_ai.runId}.html').writeAsStringSync(_aiReportHtml());
  } catch (_) {
    // 报告落盘失败不影响主流程（前端仍可现场生成）
  }
}

/// 总结分析员的 system 提示词：逐条拆解指令、只依据记录、统计必须给依据。
const String _aiSummarySystemPrompt =
    '''你是 Flutter UI 自动化测试的分析员。你会收到一条测试指令和一次自动化执行的完整记录，
需要核对执行结果是否满足指令要求，并输出结构化总结。
要求：
1. 先从指令中拆出可核对的要求（操作步骤、次数、判定标准、要计算的指标等），requirements 逐条覆盖，不得遗漏。
2. 只依据记录中的证据回答（每轮 think、步骤结果、路由/页面文本/网络/日志证据），禁止推测未发生的事。
3. 统计类结论必须给出计数依据：先说明哪些轮/步骤/日志对应一次成功或失败，再算总数与比率（如成功率=成功次数/总次数）。
4. 指令要求 N 次而记录不足 N 次时，必须明确指出「实际 N 次、未达标」，不得把未执行的次数算作成功或失败。
5. 证据不足或无法从记录判断时，status 用 unknown 并在 evidence 说明缺什么；不要编造。
6. 只输出一个 JSON 对象（不要代码围栏和多余文字），字段：
{
  "verdict": "一句话结论（含完成度/次数/成功率等关键数字）",
  "requirements": [{"requirement": "指令要求原文或改写", "status": "met|partial|unmet|unknown", "evidence": "依据（轮次/步骤/日志/断言）"}],
  "metrics": [{"name": "指标名", "value": "值", "basis": "计数依据（哪些轮/步骤）"}],
  "summary": "多段文字：需求理解、实际执行结果、失败原因归类、改进建议",
  "issues": ["问题或建议"],
  "confidence": "high|medium|low"
}''';

/// 结束后的 AI 总结：把指令 + 逐轮记录交给模型，要求逐条覆盖指令。
/// 最多 3 次调用（正常 1 次 + 失败重试 / 覆盖补全），失败不影响已落盘报告。
Future<void> _aiSummarize() async {
  final cfg = _aiConfig();
  if (cfg['baseUrl']!.trim().isEmpty ||
      cfg['apiKey']!.trim().isEmpty ||
      cfg['model']!.trim().isEmpty) {
    _ai.summaryError = 'AI 未配置（接口地址/密钥/模型），请在 AI 设置中填写';
    return;
  }
  _ai
    ..summarizing = true
    ..summary = null
    ..summaryError = ''
    ..summaryModel = cfg['model']!;
  final sw = Stopwatch()..start();
  try {
    final user = _aiRunBrief();
    var extra = '';
    for (var attempt = 0; attempt < 3; attempt++) {
      // 总结最多等约 2 分钟（单次 45s + 总时长 100s 双上限）；超时后
      // 保留已落盘的基础报告并展示原因，不让收尾无限期挂住页面。
      if (sw.elapsed > const Duration(seconds: 100)) {
        if (_ai.summaryError.isEmpty) {
          _ai.summaryError = '总结生成超时（约 2 分钟），报告不含 AI 总结';
        }
        break;
      }
      if (attempt > 0) await Future.delayed(Duration(seconds: 2 * attempt));
      try {
        final reply = await _aiCall(<Map<String, Object?>>[
          <String, Object?>{
            'role': 'system',
            'content': _aiSummarySystemPrompt
          },
          <String, Object?>{'role': 'user', 'content': '$user$extra'},
        ]).timeout(const Duration(seconds: 45));
        final obj = _aiParseReply(reply);
        if (obj == null) {
          _ai.summaryError = '总结回复不是合法 JSON';
          continue;
        }
        final missing = aiSummaryMissingRequirements(obj, _ai.goal);
        if (missing.isNotEmpty && attempt < 2) {
          // 覆盖自检未过：把缺失要求告知模型重生成，避免总结漏掉指令中的数量/统计要求。
          extra = '\n\n注意：上一次总结遗漏了指令中的这些要求：${missing.join('、')}。'
              '请重新输出完整 JSON，requirements 必须逐条覆盖指令，不得遗漏。';
          _ai.summaryError = '总结未覆盖指令要求：${missing.join('、')}';
          continue;
        }
        final normalized = Map<String, Object?>.from(obj);
        if (missing.isNotEmpty) {
          normalized['coverageWarning'] =
              '覆盖可能不全：指令要求 ${missing.join('、')} 未在总结中出现';
        }
        _ai
          ..summary = normalized
          ..summaryError = '';
        return;
      } catch (e) {
        _ai.summaryError = '总结调用失败：${_oneLine(e)}';
      }
    }
  } finally {
    _ai.summaryMs = sw.elapsedMilliseconds;
    _ai.summarizing = false;
  }
}

/// 把当前运行压缩成总结输入（指令 + 概况 + 逐轮 think/步骤/证据），长度封顶。
String _aiRunBrief() {
  var steps = 0, pass = 0, fail = 0;
  for (final r in _ai.rounds) {
    for (final s in r.results) {
      steps++;
      if (s.status == 'pass') pass++;
      if (s.status == 'fail') fail++;
    }
  }
  final endedAt = _ai.endedAt ?? DateTime.now();
  final dur = endedAt.difference(_ai.startedAt);
  final lastErr = _ai.rounds.isEmpty ? '' : _ai.rounds.last.error;
  final endReason = _ai.done
      ? 'AI 判定 done（目标完成）'
      : (_ai.stopReq
          ? '手动停止'
          : (lastErr.isNotEmpty
              ? '异常终止：${_aiBriefLine(lastErr, 120)}'
              : '未完成（原因未知）'));
  final b = StringBuffer()
    ..writeln('【测试指令】')
    ..writeln(_ai.goal)
    ..writeln()
    ..writeln('【运行概况】')
    ..writeln('结束方式：$endReason')
    ..writeln('轮数：${_ai.rounds.length}，步骤：$steps（pass $pass / fail $fail），'
        '总耗时：${dur.inSeconds}s')
    ..writeln()
    ..writeln('【逐轮记录】');
  for (final r in _ai.rounds) {
    b.writeln('轮 ${r.round + 1}：think=${_aiBriefLine(r.think, 200)}');
    if (r.retries > 0) b.writeln('  AI 调用重试：${r.retries} 次');
    if (r.error.isNotEmpty) b.writeln('  轮级错误：${_aiBriefLine(r.error, 150)}');
    for (final s in r.results) {
      final parts = <String>['  - ${s.type} ${s.status}'];
      if (s.expect.isNotEmpty) parts.add('期望=${_aiBriefLine(s.expect, 80)}');
      if (s.actual.isNotEmpty) parts.add('实际=${_aiBriefLine(s.actual, 120)}');
      if (s.error.isNotEmpty) parts.add('错误=${_aiBriefLine(s.error, 120)}');
      b.writeln(parts.join('；'));
    }
    if (r.ctxBrief.isNotEmpty) {
      b.writeln('  证据：${_aiBriefLine(r.ctxBrief, 500)}');
    }
  }
  var text = b.toString();
  const maxBrief = 24000;
  if (text.length > maxBrief) {
    text = '${text.substring(0, maxBrief)}\n…（记录过长已截断，以上为前 $maxBrief 字）';
  }
  return text;
}

/// 单行化并限长（总结输入/报告问题清单用）。
String _aiBriefLine(String s, int max) {
  final t = _oneLine(s).trim();
  return t.length <= max ? t : '${t.substring(0, max)}…';
}

/// 覆盖自检：指令中的数字要求（如「20 次」）必须出现在总结的要求/指标里。
List<String> aiSummaryMissingRequirements(
    Map<String, dynamic> summary, String goal) {
  final nums = RegExp(r'\d+').allMatches(goal).map((m) => m.group(0)!).toSet();
  if (nums.isEmpty) return <String>[];
  final reqs = summary['requirements'] is List
      ? summary['requirements'] as List
      : const <Object?>[];
  final mets = summary['metrics'] is List
      ? summary['metrics'] as List
      : const <Object?>[];
  final text = '${jsonEncode(reqs)} ${jsonEncode(mets)}';
  return nums.where((n) => !text.contains(n)).toList();
}

String _aiSummaryStatusLabel(String s) =>
    const <String, String>{
      'met': '✅ 满足',
      'partial': '⚠️ 部分满足',
      'unmet': '❌ 未满足',
      'unknown': '❔ 无法判断',
    }[s] ??
    (s.isEmpty ? '—' : s);

String _aiSummaryStatusColor(String s) =>
    const <String, String>{
      'met': '#2e7d32',
      'partial': '#b26a00',
      'unmet': '#c62828',
      'unknown': '#666',
    }[s] ??
    '#666';

/// 渲染「AI 总结」区块（报告用纯函数，便于单测）。
/// 基础报告（未开始生成、无错误、无总结）返回空串，避免出现无意义的空区块。
String buildAiSummaryHtml(
  Map<String, Object?>? summary, {
  bool summarizing = false,
  String error = '',
  int ms = 0,
  String model = '',
}) {
  if (summary == null && error.isEmpty && !summarizing) return '';
  const bd =
      'padding:4px 8px;border-bottom:1px solid #ddd;text-align:left;vertical-align:top';
  final b = StringBuffer('<h3>AI 总结</h3>');
  if (summarizing) {
    b.write('<div style="font-size:13px;color:#666">正在生成 AI 总结…</div>');
    return b.toString();
  }
  if (summary == null) {
    b.write('<div style="font-size:13px;color:#b26a00">未生成 AI 总结：'
        '${_htmlEsc(error)}</div>');
    return b.toString();
  }
  final verdict = (summary['verdict'] ?? '').toString();
  if (verdict.isNotEmpty) {
    b.write('<div style="font-size:14px;font-weight:600;margin:4px 0 8px">'
        '${_htmlEsc(verdict)}</div>');
  }
  final metrics = summary['metrics'];
  if (metrics is List && metrics.isNotEmpty) {
    b.write(
        '<table style="border-collapse:collapse;font-size:13px;margin:8px 0">'
        '<tr><th style="$bd">指标</th><th style="$bd">值</th>'
        '<th style="$bd">计数依据</th></tr>');
    for (final m in metrics) {
      if (m is! Map) continue;
      b.write(
          '<tr><td style="$bd">${_htmlEsc((m['name'] ?? '').toString())}</td>'
          '<td style="$bd"><b>${_htmlEsc((m['value'] ?? '').toString())}</b></td>'
          '<td style="$bd">${_htmlEsc((m['basis'] ?? '').toString())}</td></tr>');
    }
    b.write('</table>');
  }
  final reqs = summary['requirements'];
  if (reqs is List && reqs.isNotEmpty) {
    b.write('<div style="font-size:13px;margin-top:8px"><b>需求覆盖</b></div>'
        '<table style="border-collapse:collapse;font-size:13px;margin:4px 0">'
        '<tr><th style="$bd">你的要求</th><th style="$bd">判定</th>'
        '<th style="$bd">依据</th></tr>');
    for (final q in reqs) {
      if (q is! Map) continue;
      final st = (q['status'] ?? '').toString();
      b.write('<tr><td style="$bd">'
          '${_htmlEsc((q['requirement'] ?? '').toString())}</td>'
          '<td style="$bd;color:${_aiSummaryStatusColor(st)}">'
          '${_htmlEsc(_aiSummaryStatusLabel(st))}</td>'
          '<td style="$bd">${_htmlEsc((q['evidence'] ?? '').toString())}</td></tr>');
    }
    b.write('</table>');
  }
  final text = (summary['summary'] ?? '').toString();
  if (text.isNotEmpty) {
    b.write('<div style="white-space:pre-wrap;font-size:13px;margin:8px 0">'
        '${_htmlEsc(text)}</div>');
  }
  final issues = summary['issues'];
  if (issues is List && issues.isNotEmpty) {
    b.write('<div style="font-size:13px;margin-top:8px"><b>问题与建议</b></div>'
        '<ul style="margin:4px 0;padding-left:20px;font-size:13px">');
    for (final s in issues) {
      b.write('<li>${_htmlEsc(s.toString())}</li>');
    }
    b.write('</ul>');
  }
  final warn = (summary['coverageWarning'] ?? '').toString();
  if (warn.isNotEmpty) {
    b.write(
        '<div style="font-size:12px;color:#b26a00">${_htmlEsc(warn)}</div>');
  }
  final conf = (summary['confidence'] ?? '').toString();
  final confLabel = const <String, String>{
        'high': '高',
        'medium': '中',
        'low': '低'
      }[conf] ??
      conf;
  final info = <String>[
    if (model.isNotEmpty) '模型 $model',
    if (ms > 0) '耗时 ${(ms / 1000).toStringAsFixed(1)}s',
    if (confLabel.isNotEmpty) '把握度 $confLabel',
  ].join(' · ');
  if (info.isNotEmpty) {
    b.write('<div style="font-size:12px;color:#666;margin-top:6px">'
        '生成信息：${_htmlEsc(info)}</div>');
  }
  return b.toString();
}

/// HTML 文本转义（AI 报告生成用）。
String _htmlEsc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// 截图文件 → data URI（报告内嵌用，读取失败返回 null）。
String? _autoShotDataUri(String? name) {
  if (name == null || name.isEmpty) return null;
  final f = File('$_autoArtifactsDir/$name');
  if (!f.existsSync()) return null;
  return 'data:image/png;base64,${base64Encode(f.readAsBytesSync())}';
}

/// AI 驱动运行测试报告（自包含 HTML）：结论/遇到的问题/逐轮明细（截图内嵌）。
String _aiReportHtml() {
  const bd = 'padding:4px 8px;border-bottom:1px solid #ddd;text-align:left';
  final endedAt = _ai.endedAt ?? DateTime.now();
  final dur = endedAt.difference(_ai.startedAt);
  var steps = 0, pass = 0, fail = 0;
  for (final r in _ai.rounds) {
    for (final s in r.results) {
      steps++;
      if (s.status == 'pass') pass++;
      if (s.status == 'fail') fail++;
    }
  }
  final lastErr = _ai.rounds.isEmpty ? '' : _ai.rounds.last.error;
  String verdict;
  var verdictColor = '#c62828';
  if (_ai.done) {
    verdict = '✅ 目标完成（AI 判定 done）';
    verdictColor = '#2e7d32';
  } else if (lastErr.isNotEmpty) {
    verdict = '❌ 异常终止：${_htmlEsc(lastErr)}';
  } else if (_ai.stopReq) {
    verdict = '⚠️ 手动停止（目标未确认完成）';
    verdictColor = '#b26a00';
  } else {
    verdict = '❓ 未完成';
  }
  // 问题清单：轮级错误 / AI 重试 / 步骤级 fail，聚合为平铺列表
  final summaryHtml = buildAiSummaryHtml(
    _ai.summary,
    summarizing: _ai.summarizing,
    error: _ai.summaryError,
    ms: _ai.summaryMs,
    model: _ai.summaryModel,
  );
  final problems = <String>[];
  for (final r in _ai.rounds) {
    if (r.error.isNotEmpty) problems.add('轮 ${r.round + 1}：${r.error}');
    if (r.retries > 0) problems.add('轮 ${r.round + 1}：AI 调用重试 ${r.retries} 次');
    for (final s in r.results) {
      if (s.status == 'fail') {
        problems.add('轮 ${r.round + 1} 步 ${s.index + 1}（${s.type}）：'
            '${s.error.isNotEmpty ? s.error : '期望 ${s.expect}，实际 ${s.actual}'}');
      }
    }
  }
  if (problems.isEmpty) {
    problems.add(_ai.done ? '无' : '执行提前结束且无失败步骤，但 AI 未判定目标完成');
  }
  // 逐轮明细（同前端轮卡片形态，截图内嵌）
  final roundsHtml = StringBuffer();
  for (final r in _ai.rounds) {
    roundsHtml
        .write('<div style="border:1px solid #ccc;margin:8px 0;padding:8px">');
    final shotUri = _autoShotDataUri(r.shot);
    roundsHtml.write('<div style="display:flex;gap:8px;align-items:flex-start">'
        '<b style="font-size:13px">轮 ${r.round + 1}</b>');
    if (shotUri != null) {
      roundsHtml.write(
          '<img src="$shotUri" style="height:96px;border:1px solid #999">');
    }
    roundsHtml.write('<div style="flex:1;font-size:13px">');
    if (r.retries > 0) {
      roundsHtml
          .write('<div style="color:#b26a00">AI 调用重试 ${r.retries} 次</div>');
    }
    if (r.error.isNotEmpty) {
      roundsHtml.write('<div style="color:#c62828">${_htmlEsc(r.error)}</div>');
    }
    if (r.think.isNotEmpty) {
      roundsHtml.write('<div>AI 思考：${_htmlEsc(r.think)}</div>');
    }
    roundsHtml.write('</div></div>');
    if (r.results.isNotEmpty) {
      roundsHtml.write(
          '<table style="border-collapse:collapse;width:100%;font-size:12px;margin-top:6px">'
          '<tr><th style="$bd">#</th><th style="$bd">类型</th><th style="$bd">期望</th>'
          '<th style="$bd">状态</th><th style="$bd">耗时</th><th style="$bd">实际 / 错误</th></tr>');
      for (final s in r.results) {
        final c = s.status == 'pass'
            ? '#2e7d32'
            : (s.status == 'fail' ? '#c62828' : '#666');
        roundsHtml.write('<tr><td style="$bd">${s.index + 1}</td>'
            '<td style="$bd">${_htmlEsc(s.type)}</td>'
            '<td style="$bd">${_htmlEsc(s.expect)}</td>'
            '<td style="$bd;color:$c">${_htmlEsc(s.status)}</td>'
            '<td style="$bd">${s.ms}ms</td>'
            '<td style="$bd">${_htmlEsc(s.actual)}'
            '${s.error.isEmpty ? '' : ' | ${_htmlEsc(s.error)}'}</td></tr>');
        final sUri = _autoShotDataUri(s.shot);
        if (sUri != null) {
          roundsHtml.write('<tr><td colspan="6" style="$bd">'
              '<img src="$sUri" style="max-height:160px;border:1px solid #999"></td></tr>');
        }
      }
      roundsHtml.write('</table>');
    }
    roundsHtml.write('</div>');
  }
  final buf = StringBuffer();
  buf.write('<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">'
      '<title>xb_ume AI 自动化测试报告 ${_htmlEsc(_ai.runId)}</title></head>'
      '<body style="font-family:-apple-system,\'PingFang SC\',sans-serif;'
      'max-width:900px;margin:24px auto;color:#222">'
      '<h2 style="margin:0 0 4px">xb_ume AI 自动化测试报告</h2>'
      '<table style="border-collapse:collapse;font-size:13px;margin:8px 0">'
      '<tr><td style="$bd">目标</td><td style="$bd">${_htmlEsc(_ai.goal)}</td></tr>'
      '<tr><td style="$bd">结论</td><td style="$bd;color:$verdictColor"><b>$verdict</b></td></tr>'
      '<tr><td style="$bd">开始时间</td><td style="$bd">${_ai.startedAt.toIso8601String()}</td></tr>'
      '<tr><td style="$bd">总耗时</td><td style="$bd">${dur.inSeconds}s</td></tr>'
      '<tr><td style="$bd">规模</td><td style="$bd">${_ai.rounds.length} 轮 · $steps 步'
      '（pass $pass / fail $fail）</td></tr>'
      '</table>'
      '$summaryHtml'
      '<h3>遇到的问题</h3>'
      '<ul style="margin:4px 0;padding-left:20px;font-size:13px">\n'
      '${problems.map((p) => '<li>${_htmlEsc(p)}</li>').join('\n')}\n'
      '</ul>'
      '<h3>执行明细</h3>'
      '$roundsHtml'
      '</body></html>');
  return buf.toString();
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
      children
          .add(await expandRef('value', v is Map ? v : <String, Object?>{}));
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
  final libUri =
      owner is Map ? ((owner['library'] as Map?)?['uri'] ?? '').toString() : '';
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

/// VM service JSON-RPC 的 error → 可读文案。
/// 部分引擎（如鸿蒙 Flutter）没有 expression compilation service，evaluate 只返回
/// 笼统的 Expression compilation error，真实原因在 data.details 里，不能丢弃。
String vmServiceErrorText(Object? error) {
  if (error is! Map) return error?.toString() ?? 'VM service 错误';
  final message = error['message']?.toString() ?? 'VM service 错误';
  final data = error['data'];
  var details = '';
  if (data is Map) {
    details = data['details']?.toString() ?? '';
  } else if (data != null) {
    details = data.toString();
  }
  if (details.contains('No compilation service available')) {
    return '该调试会话不支持表达式求值（VM 未提供编译服务，常见于鸿蒙 Flutter 引擎），'
        '路由栈/实例字段/Watch/沙盒等依赖 eval 的功能不可用';
  }
  if (details.isEmpty || message.contains(details)) return message;
  if (details.length > 300) details = '${details.substring(0, 300)}…';
  return '$message（$details）';
}

/// 分段读取 app 沙盒文件：每次 evaluate 读 1MB 并 gzip 压缩传输，
/// app 端与 GUI 端内存峰值均为常数级，文件大小无上限。返回文件字节数。
Future<int> _readSandboxFileChunks(
  _SandboxRpc rpc,
  String path,
  void Function(List<int> chunk) onChunk,
) async {
  final size = int.parse(
    (await rpc.evalString("File('${_escPath(path)}').lengthSync()")).trim(),
  );
  const chunkSize = 1024 * 1024;
  for (var offset = 0; offset < size; offset += chunkSize) {
    final n = size - offset < chunkSize ? size - offset : chunkSize;
    final data = await rpc.evalString(
      "(() { final fh = File('${_escPath(path)}').openSync(); "
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
  return size;
}

/// SQLite 数据库文件的本地缓存目录（GUI 本机，源文件在 app 沙盒里）。
String dbCacheDir() {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  return '$home/.xb_ume_ide/db';
}

/// 会话 + 路径 + 大小 + mtime → 8 位缓存 id（FNV-1a 32）。
/// 同一文件内容变化（mtime/size 变）会得到新 id，天然避免读到旧缓存。
String dbCacheId(String uri, String path, int size, int mtime) {
  var h = 0x811c9dc5;
  for (final c in '$uri|$path|$size|$mtime'.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// 校验 dbId：只接受 8 位小写十六进制，防路径穿越。
bool dbIdOk(String id) => RegExp(r'^[0-9a-f]{8}$').hasMatch(id);

/// 校验待执行 SQL：单条、非空、限长（只读由 sqlite3 -readonly 保证）。
String? dbSqlError(String sql) {
  final s = sql.trim();
  if (s.isEmpty) return 'SQL 为空';
  if (s.length > 20000) return 'SQL 过长（上限 20000 字符）';
  final body = s.replaceFirst(RegExp(r';\s*$'), '');
  if (body.contains(';')) return '一次只能执行一条 SQL';
  return null;
}

/// CSV 单元格转义（RFC 4180）。
String dbCsvCell(Object? v) {
  if (v == null) return '';
  final s = v.toString();
  if (s.contains(RegExp(r'[",\n\r]'))) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

/// 解析 `sqlite3 -json` 输出 → {columns, rows}；rows 为按 columns 顺序的值数组。
/// 空结果（stdout 为空）返回空列表，由前端提示 0 行。
Map<String, Object?> dbParseJsonRows(String stdout) {
  final text = stdout.trim();
  if (text.isEmpty) {
    return <String, Object?>{'columns': <String>[], 'rows': <Object?>[]};
  }
  final decoded = jsonDecode(text);
  if (decoded is! List) throw 'sqlite3 输出不是 JSON 数组';
  final columns = <String>[];
  if (decoded.isNotEmpty && decoded.first is Map) {
    columns.addAll((decoded.first as Map).keys.map((e) => e.toString()));
  }
  final rows = <List<Object?>>[];
  for (final r in decoded) {
    if (r is! Map) continue;
    rows.add(<Object?>[for (final c in columns) r[c]]);
  }
  return <String, Object?>{'columns': columns, 'rows': rows};
}

/// sqlite3 命令行执行结果。
class DbRunResult {
  DbRunResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.truncated,
    required this.ms,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
  final bool truncated;
  final int ms;
}

/// 以只读模式执行一条 SQL：`sqlite3 -readonly`，默认输出 JSON，
/// csv=true 时输出带表头的 CSV（导出用）。20s 超时、16MB 输出上限。
Future<DbRunResult> dbRunSqlite(
  String dbPath,
  String sql, {
  bool csv = false,
  int maxBytes = 16 * 1024 * 1024,
}) async {
  final sw = Stopwatch()..start();
  final args = <String>['-readonly'];
  if (csv) {
    args.addAll(<String>['-csv', '-header']);
  } else {
    args.add('-json');
  }
  args.addAll(<String>[dbPath, sql]);
  Process proc;
  try {
    proc = await Process.start('sqlite3', args);
  } on ProcessException catch (e) {
    throw '无法启动 sqlite3 命令行（${e.message}）：请安装 sqlite3 并加入 PATH'
        '（macOS 自带；Windows 可 winget install SQLite.SQLite）';
  }
  final out = BytesBuilder(copy: false);
  var truncated = false;
  final outDone = Completer<void>();
  final sub = proc.stdout.listen((chunk) {
    if (out.length + chunk.length > maxBytes) {
      truncated = true;
      proc.kill();
      return;
    }
    out.add(chunk);
  }, onDone: () {
    if (!outDone.isCompleted) outDone.complete();
  });
  final errSb = StringBuffer();
  final errSub = proc.stderr.transform(utf8.decoder).listen(errSb.write);
  int code;
  try {
    code = await proc.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        proc.kill();
        return -1;
      },
    );
    await outDone.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  } finally {
    await sub.cancel();
    await errSub.cancel();
  }
  return DbRunResult(
    stdout: utf8.decode(out.takeBytes(), allowMalformed: true),
    stderr: errSb.toString(),
    exitCode: code,
    truncated: truncated,
    ms: sw.elapsedMilliseconds,
  );
}

/// sqlite3 失败时的可读原因。
String dbSqliteErrorText(DbRunResult r) {
  final err = r.stderr.trim();
  if (err.contains('readonly database')) {
    return '只读模式：DELETE / UPDATE / INSERT / DDL 写操作均被拒绝';
  }
  if (err.isNotEmpty) return err;
  if (r.truncated) return '结果超过 16MB 上限，请加 LIMIT 缩小范围';
  return 'sqlite3 退出码 ${r.exitCode}';
}

/// CSV 下载用的文件名：优先用打开时的原库名（demo.db → demo.csv），
/// 缺失元数据时退回 dbId。
String dbCsvFileName(String dbId) {
  var name = dbId;
  try {
    final meta = File('${dbCacheDir()}/$dbId.name');
    if (meta.existsSync()) {
      final raw = meta.readAsStringSync().trim();
      if (raw.isNotEmpty) {
        name = raw.replaceAll(
            RegExp(r'\.(db|sqlite3?|db3)$', caseSensitive: false), '');
      }
    }
  } catch (_) {}
  name = name.replaceAll(RegExp(r'["\r\n\\/]'), '_');
  if (name.isEmpty) name = dbId;
  return '$name.csv';
}

/// 列出库内表与视图（忽略 sqlite_ 内部表），附带建表 SQL。
Future<List<Map<String, Object?>>> dbListTables(String dbPath) async {
  const sql = "SELECT name, type, sql FROM sqlite_master "
      "WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' "
      "ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END, name";
  final r = await dbRunSqlite(dbPath, sql);
  if (r.exitCode != 0) throw dbSqliteErrorText(r);
  final parsed = dbParseJsonRows(r.stdout);
  final cols = (parsed['columns'] as List).cast<String>();
  final rows = (parsed['rows'] as List).cast<List<Object?>>();
  return <Map<String, Object?>>[
    for (final row in rows)
      <String, Object?>{
        for (var i = 0; i < cols.length; i++) cols[i]: row[i],
      },
  ];
}

/// 表结构：列（PRAGMA table_info）、索引（PRAGMA index_list）与建表 SQL。
Future<Map<String, Object?>> dbTableInfo(String dbPath, String table) async {
  final quoted = '"${table.replaceAll('"', '""')}"';
  final cols = await dbRunSqlite(dbPath, 'PRAGMA table_info($quoted)');
  if (cols.exitCode != 0) throw dbSqliteErrorText(cols);
  final idx = await dbRunSqlite(dbPath, 'PRAGMA index_list($quoted)');
  final create = await dbRunSqlite(
    dbPath,
    "SELECT sql FROM sqlite_master WHERE name = "
    "'${table.replaceAll("'", "''")}'",
  );
  Map<String, Object?> toMaps(DbRunResult r) {
    final parsed = dbParseJsonRows(r.stdout);
    final names = (parsed['columns'] as List).cast<String>();
    final rows = (parsed['rows'] as List).cast<List<Object?>>();
    return <String, Object?>{
      'columns': names,
      'rows': <Map<String, Object?>>[
        for (final row in rows)
          <String, Object?>{
            for (var i = 0; i < names.length; i++) names[i]: row[i],
          },
      ],
    };
  }

  final tableSql = <String>[];
  if (create.exitCode == 0) {
    final parsed = dbParseJsonRows(create.stdout);
    final rows = (parsed['rows'] as List).cast<List<Object?>>();
    for (final row in rows) {
      final v = row.isEmpty ? null : row.first;
      if (v != null && v.toString().isNotEmpty) tableSql.add(v.toString());
    }
  }
  return <String, Object?>{
    'columns': toMaps(cols)['rows'],
    'indexes': idx.exitCode == 0 ? toMaps(idx)['rows'] : <Object?>[],
    'sql': tableSql.isEmpty ? '' : tableSql.first,
  };
}

/// 应用沙盒浏览器：通过 VM service evaluate 在 app 进程内执行 dart:io 代码，
/// 零 app 端改动（debug 模式即可，release 无 VM service）。
/// 每次请求新建临时连接，用完即断。
class _SandboxRpc {
  // uri 在入口就归一：/api/routestack、/api/routelocate 等由前端直接透传的
  // 地址可能是 http://（flutter run 输出、dbgSt.wsUri 都是这个形态），
  // 而 WebSocket.connect 只认 ws(s)://，不归一就会报 Unsupported URL scheme。
  _SandboxRpc(String uri) : uri = normalizeVmUri(uri);

  final String uri;
  int _seq = 0;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  final Map<String, Completer<Object?>> _pending = {};
  String? _isolateId;

  /// 最近一次 getVM 的结果（`_resolveTarget` 时缓存，供性能面板读 VM 信息）。
  Map<String, Object?>? _vm;

  Map<String, Object?>? get vm => _vm;

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
        if (parsed['error'] != null) {
          completer.completeError(vmServiceErrorText(parsed['error']));
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
    _vm = vm;
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
    throw uri == 'dart:io'
        ? 'app 未加载 dart:io 库'
        : 'app 未加载 $uri 库（非 Flutter 调试会话？）';
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
  Future<Map<String, Object?>> evalRefOn(
      String libraryUri, String expression) async {
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
  /// close 握手可能因对端无响应而挂住，加超时兑底（超时后 socket 由
  /// 底层销毁，不再阻塞 HTTP 响应）。
  Future<void> close() async {
    // 任何一步失败/挂住都不能让调用方的 finally 卡死（否则 HTTP 响应
    // 永远不 close，前端轮询直接挂起）。
    try {
      await _sub?.cancel().timeout(const Duration(seconds: 1));
    } catch (_) {
      // ignored
    }
    try {
      await _socket?.close().timeout(const Duration(seconds: 2));
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

// ---------------------------------------------------------------------------
// 会话选择排障日志（掉选复盘用）
// ---------------------------------------------------------------------------

/// 会话选择链路日志：~/.xb_ume_ide/logs/vm_sel.log（超 2MB 轮转为 .1）。
/// 记录 daemon 会话增减与前端上报的选择事件（用户选择/指纹找回/回退/前后台切换）。
String get _vmSelLogFile => '$_home/.xb_ume_ide/logs/vm_sel.log';

void _vmSelLog(String tag, String msg) {
  try {
    final dir = Directory('$_home/.xb_ume_ide/logs');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File(_vmSelLogFile);
    if (f.existsSync() && f.lengthSync() > 2 * 1024 * 1024) {
      f.renameSync('${f.path}.1');
    }
    final t = DateTime.now().toIso8601String();
    f.writeAsStringSync('$t [$tag] $msg\n', mode: FileMode.append, flush: true);
  } catch (_) {
    // 日志写入失败不影响主流程
  }
}

/// 上一轮 /api/daemon 返回的会话集合签名（source|fp 排序拼接），用于只记变化。
var _lastDaemonSessionsSig = '';

// ---------------------------------------------------------------------------
// 路由调试日志（路由栈 Tab 异常复现用）
// ---------------------------------------------------------------------------

/// 路由调试日志：~/.xb_ume_ide/logs/route_debug.log（超 2MB 轮转为 .1）。
/// 记录路由栈读取/路由定位/路由操作的耗时与结果；框架异常到达时追加最近
/// 操作快照，用于复现「切到路由栈 Tab 后操作手机出现 framework 断言」时
/// 对齐电脑端操作与手机端异常的时间线。
String get _routeDebugLogFile => '$_home/.xb_ume_ide/logs/route_debug.log';

/// 最近路由操作（异常快照用，最多 80 条）。
final List<String> _routeTrace = <String>[];

/// uri 只取端口，避免把 VM service token 写进日志。
String _vmPortTag(String uri) {
  final port = Uri.tryParse(uri)?.port;
  return port == null || port == 0 ? '?' : '$port';
}

String _oneLine(Object e) =>
    e.toString().replaceAll('\n', ' ').replaceAll('\r', ' ');

void _routeDebugLog(String tag, String msg, {bool trace = true}) {
  final line = '${DateTime.now().toIso8601String()} [$tag] $msg';
  if (trace) {
    _routeTrace.add(line);
    if (_routeTrace.length > 80) _routeTrace.removeAt(0);
  }
  try {
    final dir = Directory('$_home/.xb_ume_ide/logs');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File(_routeDebugLogFile);
    if (f.existsSync() && f.lengthSync() > 2 * 1024 * 1024) {
      f.renameSync('${f.path}.1');
    }
    f.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {
    // 日志写入失败不影响主流程
  }
}

/// 框架异常到达时把最近路由操作追加到日志，便于直接对齐时间线
///（assertion 本身仍走 /api/exceptions 与设备日志）。
void _dumpRouteTraceForException(
    Map<String, Object?> rec, String channel, String label) {
  final summary =
      (rec['summary'] ?? '').toString().replaceAll('\n', ' ').trim();
  final frames = (rec['stack'] as List? ?? const <Object?>[])
      .take(3)
      .map((f) => f is Map ? (f['raw'] ?? '').toString() : '$f')
      .join(' | ')
      .replaceAll('\n', ' ');
  final sum = summary.length > 200 ? '${summary.substring(0, 200)}…' : summary;
  final head = frames.length > 300 ? '${frames.substring(0, 300)}…' : frames;
  _routeDebugLog(
      'exception/$channel',
      'source=$label summary=$sum'
          '${head.isEmpty ? '' : ' firstFrames=$head'}');
  final recent = _routeTrace.length > 25
      ? _routeTrace.sublist(_routeTrace.length - 25)
      : List<String>.of(_routeTrace);
  for (final line in recent) {
    _routeDebugLog('exception/ctx', line, trace: false);
  }
}

/// 该异常是否为「依赖元素已不在继承点子树内」的断言：典型是
/// InheritedElement.notifyClients 里的
/// 「check that it really is our descendant」。
bool _isDescendantAssert(Map<String, Object?> rec) {
  final summary = (rec['summary'] ?? '').toString();
  final desc = (rec['desc'] ?? '').toString();
  if (summary.contains('really is our descendant') ||
      summary.contains('UnmanagedRestorationScope') ||
      summary.contains('notifyClients') ||
      desc.contains('UnmanagedRestorationScope')) {
    return true;
  }
  for (final f in (rec['stack'] as List? ?? const <Object?>[])) {
    if (f is Map &&
        (f['raw'] ?? '')
            .toString()
            .contains('InheritedElement.notifyClients')) {
      return true;
    }
  }
  return false;
}

DateTime _lastDepsDump = DateTime.fromMillisecondsSinceEpoch(0);

/// 断言到达后 600ms 在 app 内跑一次依赖一致性探针，把失效依赖写进
/// route_debug.log（[deps] 标签）。只读遍历，不注册依赖；限频 8s。
void _dumpDepsForException(_VmSession session, String label) {
  final now = DateTime.now();
  if (now.difference(_lastDepsDump).inSeconds < 8) return;
  _lastDepsDump = now;
  Future<void>.delayed(const Duration(milliseconds: 600), () async {
    final rpc = _SandboxRpc(session.uri);
    try {
      final out = await rpc.evalStringOn(
          'package:flutter/src/widgets/framework.dart', _depsProbeExpr);
      var lines = 0;
      for (final line in out.split('\n')) {
        if (line.isEmpty) continue;
        _routeDebugLog(
            'deps', 'port=${_vmPortTag(session.uri)} source=$label $line',
            trace: false);
        if (++lines >= 40) break;
      }
    } catch (e) {
      _routeDebugLog('deps',
          'port=${_vmPortTag(session.uri)} source=$label error=${_oneLine(e)}',
          trace: false);
    } finally {
      await rpc.close();
    }
  });
}

// ── MCP 服务探测（「守护进程」页展示） ──
//
// MCP 有两种存在形式，页面要同时认：
//   - HTTP 模式：本机监听端口（默认 46140，可用 --http 改），可握手拿工具数；
//   - stdio 模式：由 IDE/客户端以子进程拉起，没有端口，只能看进程命令行。
// 只做只读探测、不拉起进程：连不上就是「未运行」，由页面给出启动命令。

/// MCP HTTP 默认端口与探测范围（与 README / MCP_GUIDE 一致）。
const int kMcpDefaultPort = 46140;

/// 读 mcp.token（HTTP 模式首次运行由服务端生成）。
String readMcpToken() {
  try {
    final f = File('$_home/.xb_ume_ide/mcp.token');
    return f.existsSync() ? f.readAsStringSync().trim() : '';
  } catch (_) {
    return '';
  }
}

/// 探测本机 MCP 服务状态（供 /api/mcp）。
Future<Map<String, Object?>> probeMcpStatus() async {
  final token = readMcpToken();
  // 端口被改到相邻值时也能发现；本机未监听端口会立刻 RST，扫 10 个不慢。
  for (var port = kMcpDefaultPort; port < kMcpDefaultPort + 10; port++) {
    final hit = await _probeMcpHttp(port, token);
    if (hit != null) return hit;
  }
  final pids = await _mcpStdioPids();
  if (pids.isNotEmpty) {
    return <String, Object?>{
      'running': true,
      'mode': 'stdio',
      'pids': pids,
      'toolCount': null,
    };
  }
  return <String, Object?>{
    'running': false,
    'defaultPort': kMcpDefaultPort,
    'hint': 'dart run xb_ume:mcp（stdio）或 dart run xb_ume:mcp --http $kMcpDefaultPort',
    'hasToken': token.isNotEmpty,
  };
}

// ── MCP 服务启停（守护进程页的「启动/停止」）───────────────────────────

/// GUI 拉起的 MCP 服务记录（pid + port），停服务时按它定位。
File get _mcpPidFile => File('$_home/.xb_ume_ide/mcp.pid');

Map<String, Object?> readMcpPidRecord() {
  try {
    final f = _mcpPidFile;
    if (!f.existsSync()) return const <String, Object?>{};
    final j = jsonDecode(f.readAsStringSync());
    if (j is Map) return j.map((k, v) => MapEntry(k.toString(), v));
  } catch (_) {
    // 记录损坏就当成没有。
  }
  return const <String, Object?>{};
}

/// 写回 config.json（读-改-写，保留其他配置键）。
void _guiWriteConfigRaw(Map<String, Object?> cfg) {
  final file = File('$_home/.xb_ume_ide/config.json');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(cfg));
}

/// 「随工具箱启动」开关（config.json 的 mcpAutoStart，默认关）。
bool readMcpAutoStart() => _guiReadConfigRaw()['mcpAutoStart'] == true;

Future<void> writeMcpAutoStart(bool on) async {
  final cfg = _guiReadConfigRaw();
  cfg['mcpAutoStart'] = on;
  _guiWriteConfigRaw(cfg);
}

/// 「允许 eval」开关（config.json 的 mcpAllowEval，默认关）。
/// 开启后工具箱拉起的 MCP 会多带 --allow-eval，多出 xbume_eval：
/// 能在 app 进程里求值任意表达式（可读可改运行时状态），默认不给。
bool readMcpAllowEval() => _guiReadConfigRaw()['mcpAllowEval'] == true;

Future<void> writeMcpAllowEval(bool on) async {
  final cfg = _guiReadConfigRaw();
  cfg['mcpAllowEval'] = on;
  _guiWriteConfigRaw(cfg);
}

/// 读 token；不存在就先生成（规则与 mcp.dart 的 ensureToken 一致）。
/// 不先建好就去拉起服务，第一次握手会因两边的 token 不一致拿 401。
String ensureMcpToken() {
  final cur = readMcpToken();
  if (cur.length >= 16) return cur;
  final rnd = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  final token = rnd.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  try {
    final f = File('$_home/.xb_ume_ide/mcp.token');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(token);
    // token 是本地共享密钥，收紧到仅当前用户可读（Windows 无 POSIX 权限，跳过）。
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', <String>['600', f.path]);
      } catch (_) {}
    }
  } catch (_) {
    // 写不了就交给服务端自己生成。
  }
  return token;
}

/// 端口是否还能监听（MCP 自己会 bind，这里只在启动前挑一个空位）。
Future<bool> _mcpPortFree(int port) async {
  try {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await s.close();
    return true;
  } catch (_) {
    return false;
  }
}

/// 启动 MCP HTTP 服务（后台子进程，部署副本 ~/.xb_ume_ide/mcp.dart）。
/// 启动时开放全部工具组（core + diagnose + run-safe + act + device-write）；
/// 装包/卸包/停进程这些高危工具自身仍强制 confirm: true。
///
/// [forceEval] 为 true 时无论配置如何都带 --allow-eval（「AI 调试」一键开启用）。
Future<Map<String, Object?>> startMcp({bool forceEval = false}) async {
  final current = await probeMcpStatus();
  if (current['running'] == true) {
    return <String, Object?>{
      ...current,
      'ok': true,
      'message': current['mode'] == 'http'
          ? 'MCP 服务已在运行（端口 ${current['port']}）'
          : '已有 stdio 模式的 MCP 进程在跑（无监听端口）',
    };
  }
  final script = File('$_home/.xb_ume_ide/mcp.dart');
  if (!script.existsSync()) {
    return <String, Object?>{
      'ok': false,
      'message': '未找到 ~/.xb_ume_ide/mcp.dart，请先执行 dart run xb_ume:ide --install',
    };
  }
  int? port;
  for (var p = kMcpDefaultPort; p < kMcpDefaultPort + 10; p++) {
    if (await _mcpPortFree(p)) {
      port = p;
      break;
    }
  }
  if (port == null) {
    return <String, Object?>{
      'ok': false,
      'message': '端口 $kMcpDefaultPort-${kMcpDefaultPort + 9} 都被占用',
    };
  }
  final log = File('$_home/.xb_ume_ide/logs/mcp.log');
  log.parent.createSync(recursive: true);
  final Process proc;
  try {
    proc = await Process.start(
      Platform.resolvedExecutable,
      <String>[
        script.path,
        '--http',
        '$port',
        '--tool-groups',
        'all',
        // 桥接类工具（data / env）要回过头调本进程的 /api/*，直接告诉它端口，
        // 省掉 46129..46138 探测（也避开用户手动指定过端口的情况）。
        '--gui-port',
        '$_guiPort',
        '--log-file',
        log.path,
        // 默认不给 eval：它能读写 app 运行时状态，要用户在卡片上显式勾选。
        // forceEval 只用于「AI 调试」一键开启（用户点按钮即视为授权）。
        if (forceEval || readMcpAllowEval()) '--allow-eval',
      ],
      workingDirectory: '$_home/.xb_ume_ide',
      mode: ProcessStartMode.detached,
    );
  } catch (e) {
    return <String, Object?>{'ok': false, 'message': '拉起进程失败：$e'};
  }
  try {
    _mcpPidFile.writeAsStringSync(jsonEncode(<String, Object?>{
      'pid': proc.pid,
      'port': port,
      'at': DateTime.now().toIso8601String(),
    }));
  } catch (_) {}
  // 等握手成功：dart 冷启动要 JIT 编译，最多等 10 秒。
  final token = ensureMcpToken();
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final hit = await _probeMcpHttp(port, token);
    if (hit != null) {
      return <String, Object?>{
        ...hit,
        'ok': true,
        'message': 'MCP 服务已启动（端口 $port）',
      };
    }
  }
  return <String, Object?>{
    'ok': false,
    'pid': proc.pid,
    'port': port,
    'message': '已拉起进程 ${proc.pid}，但 10 秒内没握手成功，详见 ${log.path}',
  };
}

/// 停止 GUI 拉起的 MCP 服务（按 PID 记录）。
Future<Map<String, Object?>> stopMcp() async {
  final rec = readMcpPidRecord();
  final pid = int.tryParse('${rec['pid'] ?? ''}');
  if (pid == null) {
    final st = await probeMcpStatus();
    if (st['running'] == true) {
      return <String, Object?>{
        'ok': false,
        'message': '这个 MCP 服务不是工具箱启动的（没有 PID 记录），请手动停止',
      };
    }
    return <String, Object?>{'ok': true, 'message': 'MCP 服务未运行'};
  }
  var killed = false;
  try {
    killed = Process.killPid(pid, ProcessSignal.sigterm);
  } catch (_) {}
  final port = int.tryParse('${rec['port'] ?? ''}') ?? kMcpDefaultPort;
  // MCP 收到 SIGTERM 会优雅关闭，这里等端口释放后再返回。
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (await _mcpPortFree(port)) break;
  }
  try {
    _mcpPidFile.deleteSync();
  } catch (_) {}
  return <String, Object?>{
    'ok': true,
    'message': killed ? 'MCP 服务已停止（pid $pid）' : '进程 $pid 已不存在，已清理记录',
  };
}

/// 「AI 调试」一键开启：把项目目录/设备变成一条可粘给 AI 的指令，
/// 并保证 MCP 服务处于「带 eval」状态（不一致就只重启自己记录的进程）。
///
/// 不在这里拉 app：拉起由 AI 调 xbume_app_launch 完成，
/// 这样 flutter run 的 stdin 才在 MCP 进程手里，热重载才能用。
Future<Map<String, Object?>> _aiSetup(String body) async {
  Map<String, Object?> j = const <String, Object?>{};
  try {
    final d = body.isEmpty ? null : jsonDecode(body);
    if (d is Map) j = d.map((k, v) => MapEntry(k.toString(), v));
  } catch (_) {
    return <String, Object?>{'ok': false, 'message': '请求体不是合法 JSON'};
  }

  final rawDir = '${j['dir'] ?? ''}'.trim();
  if (rawDir.isEmpty) {
    return <String, Object?>{
      'ok': false,
      'message': '请先填写项目目录（Flutter 项目根，含 pubspec.yaml）',
    };
  }
  final String projectDir;
  try {
    projectDir = resolveProjectDir(rawDir);
  } on FormatException catch (e) {
    return <String, Object?>{'ok': false, 'message': e.message};
  }

  var device = '${j['device'] ?? ''}'.trim();
  if (device.isEmpty) device = await guessDevice() ?? '';
  if (device.isEmpty) {
    return <String, Object?>{
      'ok': false,
      'message': '无法自动选择设备（有多台或没有可用设备），请填写设备 id',
      'devices': await listDeviceChoices(),
    };
  }

  final st = await probeMcpStatus();
  if (st['running'] == true && st['mode'] == 'stdio') {
    return <String, Object?>{
      'ok': false,
      'message': '检测到 stdio 模式的 MCP 进程（由 AI 客户端拉起），参数不归工具箱管；'
          '请在客户端配置里加 --allow-eval，或先退出客户端的这个 MCP 再点一键开启',
    };
  }
  Map<String, Object?> mcp;
  if (st['running'] == true && st['hasEval'] == true) {
    mcp = st;
  } else if (st['running'] == true) {
    // 在跑但没开 eval：只重启有 pid 记录的进程。
    if (readMcpPidRecord()['pid'] == null) {
      return <String, Object?>{
        'ok': false,
        'message': '端口 ${st['port']} 上的 MCP 不是工具箱启动的、且没开 eval；'
            '请手动停止它后重试',
      };
    }
    await stopMcp();
    mcp = await startMcp(forceEval: true);
  } else {
    mcp = await startMcp(forceEval: true);
  }
  if (mcp['ok'] == false) return mcp;

  final prompt = buildAiPrompt(
    projectDir: projectDir,
    deviceId: device,
    hasEval: mcp['hasEval'] == true,
  );
  final config = aiClientConfig(
    url: '${mcp['url'] ?? ''}',
    token: readMcpToken(),
  );
  final cfg = _guiReadConfigRaw();
  cfg['aiProjectDir'] = projectDir;
  cfg['aiDevice'] = device;
  // 最近用过的项目目录（最多 8 条，去重后置顶）。
  final recentDirs = <String>[
    projectDir,
    for (final e in (cfg['aiRecentDirs'] as List? ?? const <Object?>[]))
      if ('$e'.trim().isNotEmpty && '$e'.trim() != projectDir) '$e'.trim(),
  ].take(8).toList();
  cfg['aiRecentDirs'] = recentDirs;
  _guiWriteConfigRaw(cfg);

  return <String, Object?>{
    'ok': true,
    'projectDir': projectDir,
    'deviceId': device,
    'recentDirs': recentDirs,
    'mcp': mcp,
    'prompt': prompt,
    'config': config,
  };
}

/// 对 http://127.0.0.1:<port>/mcp 发一条 JSON-RPC，返回响应 JSON；失败返回 null。
Future<Map<String, Object?>?> _mcpPost(
  HttpClient hc,
  int port,
  String token,
  Map<String, Object?> body,
) async {
  try {
    final req = await hc.postUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(HttpHeaders.acceptHeader,
        'application/json, text/event-stream');
    if (token.isNotEmpty) req.headers.set('X-XBUME-Token', token);
    req.write(jsonEncode(body));
    final res = await req.close().timeout(const Duration(seconds: 2));
    final text = await res.transform(utf8.decoder).join();
    if (text.trim().isEmpty) return null;
    final j = jsonDecode(text);
    return j is Map ? Map<String, Object?>.from(j) : null;
  } catch (_) {
    return null;
  }
}

/// 握手一个端口：initialize 成功才认作 MCP，再 tools/list 取工具数。
Future<Map<String, Object?>?> _probeMcpHttp(int port, String token) async {
  final hc = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 400);
  try {
    final init = await _mcpPost(hc, port, token, <String, Object?>{
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': <String, Object?>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{
          'tools': <String, Object?>{},
        },
        'clientInfo': <String, Object?>{'name': 'xbume-gui', 'version': '1'},
      },
    });
    final result = init?['result'];
    if (result is! Map) return null;
    var count = 0;
    final list = await _mcpPost(hc, port, token, <String, Object?>{
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
      'params': <String, Object?>{},
    });
    final tools = (list?['result'] as Map?)?['tools'];
    var hasEval = false;
    if (tools is List) {
      count = tools.length;
      hasEval = tools.any((t) => t is Map && t['name'] == 'xbume_eval');
    }
    final info = result['serverInfo'];
    return <String, Object?>{
      'running': true,
      'mode': 'http',
      'port': port,
      'url': 'http://127.0.0.1:$port/mcp',
      'protocolVersion': '${result['protocolVersion'] ?? ''}',
      'serverName': info is Map ? '${info['name'] ?? ''}' : '',
      'serverVersion': info is Map ? '${info['version'] ?? ''}' : '',
      'toolCount': count,
      'hasEval': hasEval,
    };
  } finally {
    hc.close(force: true);
  }
}

/// stdio 模式的 MCP 服务 pid（无端口，靠进程命令行识别）。
Future<List<int>> _mcpStdioPids() async {
  try {
    if (Platform.isWindows) {
      const ps = "Get-CimInstance Win32_Process | Where-Object { "
          "\$_.CommandLine -match 'xb_ume:mcp' -and "
          "\$_.CommandLine -notmatch '--http' } | "
          "ForEach-Object { \$_.ProcessId }";
      final r =
          await Process.run('powershell', <String>['-NoProfile', '-Command', ps]);
      return r.stdout
          .toString()
          .split('\n')
          .map((e) => int.tryParse(e.trim()))
          .whereType<int>()
          .toList(growable: false);
    }
    final r = await Process.run('pgrep', <String>['-f', 'xb_ume:mcp']);
    final out = <int>[];
    for (final line in r.stdout.toString().split('\n')) {
      final p = int.tryParse(line.trim());
      if (p == null || p == pid) continue;
      // pgrep -f 是子串匹配，会命中 --http 实例；用 ps 复核命令行再判定。
      final ps = await Process.run('ps', <String>['-p', '$p', '-o', 'command=']);
      final cmd = ps.stdout.toString();
      if (!cmd.contains('xb_ume:mcp') || cmd.contains('--http')) continue;
      out.add(p);
    }
    return out;
  } catch (_) {
    return const <int>[];
  }
}

/// 与 daemon（bin/ide.dart）约定的安装目录与配置文件名。
const String kInstallDirName = '.xb_ume_ide';
const String kConfigName = 'config.json';

/// 重启 / 停止 / 启动守护进程、GUI 接班人、重新部署均在
/// src/control/svc_control.dart 里实现（GUI 与 bin/ide.dart 共用）。

/// 优雅退出：先关掉全部 VM 会话再 exit。
///
/// 实测：持有流订阅（Stdout/Extension）的 VM service 连接被硬切断后，
/// DDS 会永久死锁（该会话此后对所有客户端无响应）；重启 / 停止 GUI 都
/// 必须走这里，不能直接 kill -9。
Future<void> gracefulShutdown(GuiState state) async {
  try {
    await state.dispose().timeout(const Duration(seconds: 2));
  } catch (_) {}
  exit(0);
}

/// 服务状态快照（/api/svc/status）。
Future<Map<String, Object?>> svcStatusSnapshot() async {
  final daemon = await queryDaemonStatus();
  return <String, Object?>{
    'ok': true,
    'gui': <String, Object?>{
      'pid': pid,
      'port': _guiPort,
      'uptimeSec': DateTime.now().difference(_guiStartedAt).inSeconds,
      'script': Platform.script.toFilePath(),
    },
    'daemon': daemon,
    'sourceRoot': readSourceRoot(),
    'busy': _svcBusy ? _svcBusyAction : null,
    'platform': Platform.operatingSystem,
  };
}

/// 部署日志增量（/api/svc/log?offset=N）：offset 为已读字节数。
Map<String, Object?> readInstallLog(String? offsetRaw) {
  final f = File(installLogPath());
  if (!f.existsSync()) {
    return <String, Object?>{
      'ok': true,
      'offset': 0,
      'text': '',
      'running': false,
    };
  }
  try {
    final bytes = f.readAsBytesSync();
    final size = bytes.length;
    final since = int.tryParse(offsetRaw ?? '') ?? -1;
    // offset 非法（页面重开 / 日志被截断）时退回最后 4KB，别把整段历史发过去。
    final from = since >= 0 && since <= size
        ? since
        : (size > 4096 ? size - 4096 : 0);
    return <String, Object?>{
      'ok': true,
      'offset': size,
      'text': utf8.decode(bytes.sublist(from), allowMalformed: true),
      'running': _svcBusy && _svcBusyAction == 'redeploy',
    };
  } catch (e) {
    return <String, Object?>{'ok': false, 'message': '读取日志失败: $e'};
  }
}

String _svcTargetLabel(String t) =>
    t == 'gui' ? 'GUI' : (t == 'daemon' ? '守护进程' : t);

String _svcSummary(String verb, Map<String, Object?> out) {
  final parts = <String>[];
  out.forEach((k, v) {
    final ok = v is Map && v['ok'] == true;
    parts.add('${_svcTargetLabel(k)}${ok ? '✓' : '✗'}');
  });
  return '$verb结果：${parts.join('，')}';
}

Future<void> _writeJson(HttpRequest req, Map<String, Object?> body) async {
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  await req.response.close();
}

/// /api/svc/<action>：start / stop / restart / redeploy。
///
/// GUI 自身的重启 / 停止不能在此直接 exit：先把响应写完，再交给
/// gracefulShutdown（关 VM 会话），否则前端拿到的是连接被重置。
Future<void> handleSvcAction(
  GuiState state,
  HttpRequest req,
  String action,
) async {
  if (_svcBusy) {
    await _writeJson(req, <String, Object?>{
      'ok': false,
      'message': '正在执行 $_svcBusyAction，请稍候',
    });
    return;
  }
  final target = normalizeSvcTarget(req.uri.queryParameters['target']) ??
      (action == 'start' ? 'daemon' : 'all');
  _svcBusy = true;
  _svcBusyAction = action;
  var exitAfter = false;
  Map<String, Object?> result;
  try {
    if (action == 'start') {
      result = target == 'gui'
          ? <String, Object?>{
              'ok': true,
              'message': 'GUI 已在运行（pid=$pid）；启动 GUI 请双击工具箱或运行 --svc start gui',
            }
          : await startDaemon();
    } else if (action == 'stop' || action == 'restart') {
      final out = <String, Object?>{};
      for (final t in svcActionOrder(target)) {
        if (t == 'daemon') {
          out['daemon'] =
              action == 'stop' ? await stopDaemon() : await restartDaemon();
        } else if (t == 'gui') {
          if (action == 'stop') {
            out['gui'] = <String, Object?>{
              'ok': true,
              'message': 'GUI 正在停止（页面会失去连接）',
            };
            exitAfter = true;
          } else {
            final r = await spawnGuiSuccessor(ownerPid: pid, port: _guiPort);
            out['gui'] = r;
            exitAfter = r['ok'] == true;
          }
        }
      }
      final ok = out.values.every((v) => v is Map && v['ok'] == true);
      result = <String, Object?>{
        'ok': ok,
        'message': _svcSummary(action == 'stop' ? '停止' : '重启', out),
        'results': out,
      };
    } else if (action == 'redeploy') {
      final r = await redeployAndRestart(waitPid: pid);
      exitAfter = r['ok'] == true;
      result = r;
    } else {
      result = <String, Object?>{'ok': false, 'message': '未知动作: $action'};
    }
  } catch (e) {
    result = <String, Object?>{'ok': false, 'message': '执行失败: $e'};
  } finally {
    _svcBusy = false;
    _svcBusyAction = '';
  }
  await _writeJson(req, result);
  if (exitAfter) {
    // 响应已 flush：留 400ms 让浏览器收到结果，再优雅退出。
    unawaited(Future<void>.delayed(const Duration(milliseconds: 400))
        .then((_) => gracefulShutdown(state)));
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
      ok = await _resolveGuiIdeCli(ide) != null;
    }
    if (ok) installed.add(ide);
  }
  return installed;
}

/// 当前配置的 ideOrder（无配置/损坏时返回默认名单）。
List<String> readGuiIdeOrderList() {
  final order = _guiReadConfigRaw()['ideOrder'];
  if (order is! List) return List<String>.of(_guiDefaultIdeOrder);
  final names =
      order.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
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

/// Windows 上未加入 PATH 时按 app 内置 CLI 兜底（与 daemon 的
/// _vscodeLikeAppClis 同一份路径表；发行渠道多，未逐一实测）。
Map<String, List<String>> get _guiWindowsVscodeAppClis {
  if (!Platform.isWindows) return const <String, List<String>>{};
  final lad = Platform.environment['LOCALAPPDATA'];
  if (lad == null) return const <String, List<String>>{};
  String user(String app) => '$lad\\Programs\\$app\\resources\\app\\bin';
  String system(String app) => 'C:\\Program Files\\$app\\resources\\app\\bin';
  return <String, List<String>>{
    'qoder-cn': <String>[
      '${user('Qoder CN')}\\qoder-cn.cmd',
      '${user('Qoder')}\\qoder-cn.cmd',
      '${system('Qoder CN')}\\qoder-cn.cmd',
    ],
    'qodercn': <String>[
      '${user('Qoder CN')}\\qodercn.cmd',
      '${user('Qoder')}\\qodercn.cmd',
      '${system('Qoder CN')}\\qodercn.cmd',
    ],
    'cursor': <String>[
      '${user('Cursor')}\\cursor.cmd',
      '${system('Cursor')}\\cursor.cmd',
    ],
    'trae': <String>[
      '${user('Trae')}\\trae.cmd',
      '${user('Trae CN')}\\trae.cmd',
      '${system('Trae')}\\trae.cmd',
    ],
    'windsurf': <String>[
      '${user('Windsurf')}\\windsurf.cmd',
      '${system('Windsurf')}\\windsurf.cmd',
    ],
    'code': <String>[
      '$lad\\Programs\\Microsoft VS Code\\bin\\code.cmd',
      'C:\\Program Files\\Microsoft VS Code\\bin\\code.cmd',
    ],
  };
}

/// 解析 IDE 的 CLI 路径：PATH 优先，未加入 PATH 时回退 app 内置 CLI。
Future<String?> _resolveGuiIdeCli(String ide) async {
  if (await _guiHasCommand(ide)) return ide;
  for (final p in <String>[
    ...(_guiMacosVscodeAppClis[ide] ?? const <String>[]),
    ...(_guiWindowsVscodeAppClis[ide] ?? const <String>[]),
  ]) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

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
    final names =
        order.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
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
    // vscode-like：PATH 优先，未加 PATH 时按 app 内置 CLI 兜底。
    final cli = await _resolveGuiIdeCli(ide);
    if (cli == null) continue;
    if (await _guiRunChecked(cli, <String>[
      ...(_guiIdeCliSubcommands[ide] ?? const <String>[]),
      '-g',
      '$path:$line',
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
final Map<String, Map<String, String>> _pkgRootsCache =
    <String, Map<String, String>>{};

/// file: URI → 本机路径；非 file URI 或非法编码返回 null。
/// 百分号编码会解码；Windows 盘符按字符串还原（'/C:/x' → 'C:/x'），
/// 不依赖运行平台，便于在任意系统上单测。
String? fileUriToLocalPath(String uri) {
  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.scheme != 'file') return null;
  final host = parsed.host;
  if (host.isNotEmpty && host != 'localhost') return null;
  final String decoded;
  try {
    decoded = Uri.decodeComponent(parsed.path);
  } catch (_) {
    return null;
  }
  if (decoded.isEmpty) return null;
  final winPath = RegExp(r'^/[A-Za-z]:/').hasMatch(decoded);
  return (winPath ? decoded.substring(1) : decoded).replaceAll('\\', '/');
}

/// 从 isolate 的 file:/// 库 uri 推断 Flutter 项目根目录。
///
/// 不能只取“第一个 file:// 库”：isolate 的库列表里混着 pub-cache 三方包，
/// 按 URI 排序常排在 app 之前（Windows 路径同样如此）。这里收集所有候选根，
/// 优先返回真正带 `.dart_tool/package_config.json` 的那个；都读不到时
/// 退而选非 pub-cache 目录，避免把三方包当成项目根。
String? projectRootForLibraries(List<String> fileUris) {
  final candidates = <String>{};
  for (final uri in fileUris) {
    final path = fileUriToLocalPath(uri);
    if (path == null) continue;
    for (final marker in const <String>['/.dart_tool/', '/lib/']) {
      final idx = path.indexOf(marker);
      if (idx > 0) candidates.add(path.substring(0, idx));
    }
  }
  String? firstNonCache;
  for (final root in candidates) {
    if (File('$root/.dart_tool/package_config.json').existsSync()) return root;
    if (firstNonCache == null && !_looksLikePubCache(root)) {
      firstNonCache = root;
    }
  }
  return firstNonCache ?? (candidates.isEmpty ? null : candidates.first);
}

/// 是否 pub-cache 下的包目录（三方包不是项目根）。
bool _looksLikePubCache(String path) {
  final lower = path.replaceAll('\\', '/').toLowerCase();
  return lower.contains('/.pub-cache/') || lower.contains('/pub/cache/');
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
      final root = packageRootPath(rootUri, projectRoot);
      if (root == null) continue;
      roots[name] = root;
    }
    _pkgRootsCache[projectRoot] = roots;
    return roots;
  } catch (_) {
    return null;
  }
}

/// package_config.json 的单条 rootUri → 本机包根路径（统一正斜杠）。
/// 绝对 file: URI（pub-cache）与相对路径（path 依赖）都支持。
String? packageRootPath(String rootUri, String projectRoot) {
  final root = rootUri.startsWith('file:')
      ? fileUriToLocalPath(rootUri)
      : _normalizeLocalPath('$projectRoot/.dart_tool/$rootUri');
  if (root == null || root.isEmpty) return null;
  var trimmed = root;
  // 去掉结尾斜杠，但保留 Windows 盘符根（C:/）。
  while (trimmed.length > 3 && trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

/// 归一化本机路径（处理 ../ 与 ./，package_config 的相对 rootUri 用）。
String _normalizeLocalPath(String p) {
  final path = p.replaceAll('\\', '/');
  final abs = path.startsWith('/');
  final out = <String>[];
  for (final seg in path.split('/')) {
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
  if (uri.startsWith('file:')) {
    final path = fileUriToLocalPath(uri);
    if (path == null) return null;
    final f = File(path);
    return f.existsSync() ? f.path : null;
  }
  if (uri.startsWith('package:')) {
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
  }
  return null;
}

/// `package:<pkg>/<p>` → 本机源码路径（Flutter SDK / 依赖包），找不到返回 null。
/// 只给源码面板的「单步跟随当前帧」用：IDE 单步进入框架代码时也会打开源码。
String? resolvePackageSourcePath(String uri, String projectRoot) {
  if (!uri.startsWith('package:')) return null;
  final rest = uri.substring('package:'.length);
  final slash = rest.indexOf('/');
  if (slash <= 0 || slash == rest.length - 1) return null;
  final pkg = rest.substring(0, slash);
  final rel = rest.substring(slash + 1);
  final pkgRoot = _pkgRootsFor(projectRoot.trim())?[pkg];
  if (pkgRoot == null) return null;
  final f = File('$pkgRoot/lib/$rel');
  return f.existsSync() ? f.path : null;
}

/// 在源文件中找类/mixin/enum 声明行（1-based）；找不到返回 1。
int _findClassDeclLine(String path, String className) {
  try {
    final lines = File(path).readAsLinesSync();
    final pattern = RegExp(
        '^(?:abstract\\s+)?(?:class|enum|mixin|extension)\\s+$className\\b');
    for (var i = 0; i < lines.length; i++) {
      if (pattern.hasMatch(lines[i])) return i + 1;
    }
  } catch (_) {
    // ignored
  }
  return 1;
}

// -- 路由 State / VM / Notifier 的静态源码解析 --------------------------------
// 前置条件：routelocate 已把路由子树中第一个用户 widget 类定位到本机源
// 文件。State 名与 VM / Notifier 名均从源码推导，不再连 VM：
//   State 名 = widget 类 createState() 的返回类型（纯 XBWidget 页面继承自
//   XBWidget.createState，用户类里没有覆盖，此时为空）；
//   VM 名 = widget 声明处泛型实参（extends XBPage<HomeVM>）、generateVM
//   返回类型或构造调用、State 字段类型、vmOf/vmWatch/Provider.of/Consumer
//   等泛型实参，沿 extends 链验证是否 XBVM / XBPageVM 体系；
//   Notifier = 其余沿 extends 链能到 ChangeNotifier 的字段/泛型实参。

/// 从 widget 类源码静态解析（State 类名, XBVM 类名列表, Notifier 类名列表）。
(String, List<String>, List<String>) _routeStateAndNotifier(
    String widgetFile, String widgetCls) {
  final src = File(widgetFile).readAsStringSync();
  final widgetBody = _classBodyOf(src, widgetCls);
  if (widgetBody == null) return ('', const <String>[], const <String>[]);
  // createState() => _HomePageState(); / createState() { return _HomePageState(); }
  final sm = RegExp(r'createState\s*\(\s*\)\s*=>\s*([A-Za-z_$][\w$]*)')
          .firstMatch(widgetBody) ??
      RegExp(r'createState\s*\(\s*\)\s*\{\s*(?:return\s+)?([A-Za-z_$][\w$]*)')
          .firstMatch(widgetBody);
  final stateName = sm?.group(1) ?? '';
  // State 类多与 widget 同文件（私有类）；不在时按项目类索引找。
  String? stateSrc;
  String? stateBody;
  if (stateName.isNotEmpty) {
    stateBody = _classBodyOf(src, stateName);
    stateSrc = src;
    if (stateBody == null) {
      final root = _pubspecRootFor(widgetFile);
      final f = root == null ? null : _clsFileIndexFor(root)[stateName];
      if (f != null) {
        stateSrc = File(f).readAsStringSync();
        stateBody = _classBodyOf(stateSrc, stateName);
      }
    }
  }
  final (vms, cns) = _notifierNamesOf(
    widgetSrc: src,
    widgetBody: widgetBody,
    widgetCls: widgetCls,
    stateSrc: stateSrc,
    stateName: stateName,
    stateBody: stateBody,
    root: _pubspecRootFor(widgetFile),
  );
  return (stateName, vms, cns);
}

/// 源码中类 <clsName> 的声明子句（class 关键字到类体 `{` 之前）。
String? _classDeclOf(String src, String clsName) {
  final m = RegExp(
          '(?:^|\\s)(?:abstract\\s+|base\\s+|final\\s+|sealed\\s+|mixin\\s+)*class\\s+'
          '${RegExp.escape(clsName)}[\\s<][^{]*\\{')
      .firstMatch(src);
  return m?.group(0);
}

/// 源码中类 <clsName> 的类体（大括号配平截取，不含外层花括号）。
String? _classBodyOf(String src, String clsName) {
  final m = RegExp(
          '(?:^|\\s)(?:abstract\\s+|base\\s+|final\\s+|sealed\\s+|mixin\\s+)*class\\s+'
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
  final decl = _classDeclOf(src, clsName);
  if (decl == null) return null;
  return RegExp(r'\bextends\s+([A-Za-z_$][\w$]*)').firstMatch(decl)?.group(1);
}

/// 源码中类 <clsName> 的声明行号（1 起）；找不到返回 null。
///
/// 匹配规则与 [_classBodyOf] 一致（允许 abstract/base/final/sealed 前缀）。
int? _classLineOf(String src, String clsName) {
  final m = RegExp(
          '(?:^|\\s)(?:abstract\\s+|base\\s+|final\\s+|sealed\\s+|mixin\\s+)*class\\s+'
          '${RegExp.escape(clsName)}[\\s<]')
      .firstMatch(src);
  if (m == null) return null;
  // 匹配可以空白开头，行号按 class 关键字本身算。
  final at = src.indexOf('class', m.start);
  if (at < 0) return null;
  var line = 1;
  for (var i = 0; i < at; i++) {
    if (src.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}

/// 类名 → 本机源码位置（`file` + `line`），供断点卡片的路由栈小节
/// “点名字就在下方源码面板打开”用。
///
/// State 多与 widget 同文件，所以先试 widgetFile；VM / ChangeNotifier 常
/// 在单独文件，统一走 [_clsFileIndexFor] 的项目类索引（按项目根缓存）。
/// 找不到源码的类（在依赖包 / SDK 里）不进结果，前端据此降级为灰字。
Map<String, Map<String, Object?>> _classLocations(
    String widgetFile, String widgetCls, String stateName,
    List<String> vmList, List<String> cnList) {
  final out = <String, Map<String, Object?>>{};
  final root = _pubspecRootFor(widgetFile);
  final idx = root == null ? const <String, String>{} : _clsFileIndexFor(root);

  void put(String cls, List<String?> prefers) {
    if (cls.isEmpty || out.containsKey(cls)) return;
    final seen = <String>{};
    for (final f in <String?>[...prefers, idx[cls]]) {
      if (f == null || !seen.add(f)) continue;
      String src;
      try {
        src = File(f).readAsStringSync();
      } catch (_) {
        continue;
      }
      final line = _classLineOf(src, cls);
      if (line == null) continue;
      out[cls] = <String, Object?>{'file': f, 'line': line};
      return;
    }
  }

  put(widgetCls, <String?>[widgetFile]);
  if (stateName.isNotEmpty) put(stateName, <String?>[widgetFile]);
  for (final v in vmList) {
    put(v, const <String?>[]);
  }
  for (final c in cnList) {
    put(c, const <String?>[]);
  }
  return out;
}

/// 从 widget / State 源码收集 XBVM 与 ChangeNotifier 类名（去重保序）。
///
/// 依次探测：声明处泛型实参、generateVM 返回类型与构造调用、字段类型、
/// vmOf/vmWatch/Provider.of/watch/read/select/Consumer/Selector 泛型实参；
/// 沿 extends 链把 XBVM / XBPageVM 体系归入 VM，其余 CN 归入 Notifier。
(List<String>, List<String>) _notifierNamesOf({
  required String widgetSrc,
  required String widgetBody,
  required String widgetCls,
  required String? stateSrc,
  required String stateName,
  required String? stateBody,
  required String? root,
}) {
  final vms = <String>[];
  final cns = <String>[];
  final seen = <String>{};
  void probe(String raw) {
    final t = RegExp(r'^[A-Za-z_$][\w$]*').firstMatch(raw.trim())?.group(0);
    if (t == null || t.isEmpty || seen.contains(t)) return;
    // XBVM / XBPageVM 是体系基类，既不作为具体实例候选，也不能点击跳转。
    if (t == 'XBVM' || t == 'XBPageVM') return;
    if (_extendsXbVM(t, root, 0)) {
      seen.add(t);
      vms.add(t);
    } else if (t == 'ChangeNotifier' ||
        t == 'ValueNotifier' ||
        (root != null && _extendsChangeNotifier(t, root, 0))) {
      seen.add(t);
      cns.add(t);
    }
  }

  // ① 声明处泛型实参：class X extends XBPage<HomeVM> / State<Widget>。
  for (final decl in <String?>[
    _classDeclOf(widgetSrc, widgetCls),
    if (stateSrc != null && stateName.isNotEmpty)
      _classDeclOf(stateSrc, stateName),
  ]) {
    if (decl == null) continue;
    final m =
        RegExp(r'\bextends\s+[A-Za-z_$][\w$]*\s*<([^>]*)>').firstMatch(decl);
    if (m == null) continue;
    for (final raw in m.group(1)!.split(',')) {
      probe(raw);
    }
  }
  // ② generateVM 的返回类型（显式时）与构造函数（返回类型省略时）。
  final gmType = RegExp(
          r'(?:^|\n)\s*(?:@override\s+)?([A-Za-z_$][\w$]*(?:<[^>]*>)?)\s+generateVM\s*\(')
      .firstMatch(widgetBody);
  if (gmType != null) probe(gmType.group(1)!);
  final gmExpr = RegExp(
              r'generateVM\s*\([^)]*\)\s*(?:async\s*)?=>\s*([A-Za-z_$][\w$]*)')
          .firstMatch(widgetBody) ??
      RegExp(r'generateVM\s*\([^)]*\)\s*(?:async\s*)?\{[\s\S]{0,400}?\breturn\s+([A-Za-z_$][\w$]*)')
          .firstMatch(widgetBody);
  if (gmExpr != null) probe(gmExpr.group(1)!);
  // ③ 字段类型：State 里持有 controller / VM 字段。
  final fieldRe = RegExp(
      r'^\s*(?:final\s+|late\s+|const\s+|static\s+)*'
      r'([A-Za-z_$][\w$]*)(?:<[^;=]*?>)?\??\s+_?[a-z][\w$]*\s*(?:=|;)',
      multiLine: true);
  for (final body in <String?>[widgetBody, stateBody]) {
    if (body == null) continue;
    for (final m in fieldRe.allMatches(body)) {
      probe(m.group(1)!);
    }
  }
  // ④ 泛型调用实参：Provider 注入、Consumer 监听、context.vmOf 等。
  // 只扫本页 widget / State 类体，避免把同文件其它页面的 VM 归到当前行。
  final genericRe = RegExp(
      r'\b(?:Provider\.of|ChangeNotifierProvider|vmOf|vmWatch|vmOfOrNull|vmWatchOrNull|watch|read|select|Consumer[2-9]?|Selector)\s*<([^>]*)>');
  for (final body in <String?>[widgetBody, stateBody]) {
    if (body == null) continue;
    for (final m in genericRe.allMatches(body)) {
      for (final raw in m.group(1)!.split(',')) {
        probe(raw);
      }
    }
  }
  return (vms, cns);
}

/// 项目内类型 <type> 是否沿 extends 链最终继承 XBVM（含 XBPageVM）。
bool _extendsXbVM(String type, String? root, int depth) {
  if (type == 'XBVM' || type == 'XBPageVM') return true;
  if (root == null || depth > 4) return false;
  final f = _clsFileIndexFor(root)[type];
  if (f == null) return false;
  try {
    final sup = _superClassOf(File(f).readAsStringSync(), type);
    if (sup == null) return false;
    return _extendsXbVM(sup, root, depth + 1);
  } catch (_) {
    return false;
  }
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
final Map<String, Map<String, String>> _clsFileCache =
    <String, Map<String, String>>{};

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
        for (final m
            in RegExp(r'\bclass\s+([A-Za-z_$][\w$]*)').allMatches(src)) {
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
  final entry = parsed ??
      <String, String>{
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

/// 每个日志来源键（source|tag|device）的保留条数上限。
///
/// 单个高频会话能在一两分钟内输出上千条，若全局缓冲只按 FIFO 淘汰，其他
/// 会话与设备日志会被整片挤出（实测 f_jlink 会话占满 5000 条，切到别的会话
/// 后 Flutter 输出为 0 条）。按来源分额后，每个来源都保留自己最近的一千条。
const int kMaxLinesPerSource = 1000;

String _logSrcKey(Map<String, Object?> e) =>
    '${e['source'] ?? ''}|${e['tag'] ?? ''}|${e['device'] ?? ''}';

/// 日志缓冲裁剪（顶层函数便于单测）。
///
/// 1) 单来源配额：同一 source|tag|device 超 [kMaxLinesPerSource] 条时，删该
///    来源最旧的一条，避免单个高频会话挤掉其他会话的输出；
/// 2) 总量上限：仍超 [kMaxBufferLines] 时，优先淘汰最旧的非 Flutter 行
///    （设备日志洪流不应挤掉 Flutter 输出）。
void trimLogBuffer(
  List<Map<String, Object?>> buffer,
  Map<String, int> srcCounts,
  Map<String, Object?> added,
) {
  final key = _logSrcKey(added);
  var n = (srcCounts[key] ?? 0) + 1;
  if (n > kMaxLinesPerSource) {
    final src = added['source'];
    final tag = added['tag'];
    final dev = added['device'];
    final idx = buffer.indexWhere(
        (e) => e['source'] == src && e['tag'] == tag && e['device'] == dev);
    if (idx >= 0) {
      buffer.removeAt(idx);
      n--;
    }
  }
  srcCounts[key] = n;

  var over = buffer.length - kMaxBufferLines;
  if (over <= 0) {
    return;
  }
  var i = 0;
  while (over > 0 && i < buffer.length) {
    final src = buffer[i]['source']?.toString() ?? '';
    if (!src.startsWith('flutter')) {
      final k = _logSrcKey(buffer[i]);
      srcCounts[k] = (srcCounts[k] ?? 1) - 1;
      buffer.removeAt(i);
      over--;
    } else {
      i++;
    }
  }
  while (over > 0 && buffer.isNotEmpty) {
    final k = _logSrcKey(buffer.first);
    srcCounts[k] = (srcCounts[k] ?? 1) - 1;
    buffer.removeAt(0);
    over--;
  }
}

// ---------------------------------------------------------------------------
// 系统辅助
// ---------------------------------------------------------------------------

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
<meta name="xbume-token" content="__XBUME_TOKEN__">
<title>xb_ume 工具箱</title>
<style>
  :root { --bg:#0b0f14; --panel:#131a23; --line:#223041; --fg:#dbe6f0; --dim:#8aa0b4; --acc:#00e5ff; }
  * { box-sizing:border-box; margin:0; padding:0; }
  body { background:var(--bg); color:var(--fg); font:14px/1.5 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif; height:100vh; display:flex; flex-direction:column; }
  header { display:flex; align-items:center; gap:12px; padding:10px 16px; border-bottom:1px solid var(--line); }
  header h1 { font-size:15px; font-weight:600; color:var(--acc); margin-right:12px; }
  .tab { padding:6px 14px; border:1px solid var(--line); border-radius:6px; cursor:pointer; color:var(--dim); white-space:nowrap; flex:0 0 auto; }
  /* Tab 多时横向滚动，避免被 flex 压窄后中文竖排换行 */
  .tabs { display:flex; align-items:center; gap:8px; flex:1; min-width:0; overflow-x:auto; scrollbar-width:thin; }
  .tab.active { color:var(--acc); border-color:var(--acc); }
  .ide-list { list-style:none; margin:10px 0 0; padding:0; }
  .ide-list li { display:flex; align-items:center; gap:8px; padding:7px 10px; border:1px solid var(--line); border-radius:6px; margin-bottom:6px; background:var(--bg2,#161b22); }
  .ide-list li .handle { color:var(--dim); cursor:grab; user-select:none; }
  .ide-list li.dragging { opacity:.45; }
  .ide-list li.dragover { border-color:var(--acc); }
  .ide-list li .notinstalled { color:var(--dim); font-size:12px; margin-left:auto; }
  #hdr-right { margin-left:auto; display:flex; align-items:center; gap:10px; position:relative; }
  /* 服务控制（顶栏）：GUI / daemon 状态徽标 + 下拉菜单 */
  .svc-badge { font-size:11px; padding:2px 8px; border-radius:10px; border:1px solid var(--line); color:var(--dim); white-space:nowrap; font-variant-numeric:tabular-nums; }
  .svc-badge.on { color:#7ee787; border-color:#2f6b3c; background:#12251a; }
  .svc-badge.off { color:#ff9b9b; border-color:#5c2e2e; background:#241416; }
  .svc { position:relative; }
  .svc > button { padding:5px 10px; border:1px solid var(--line); border-radius:6px; background:var(--panel); color:var(--dim); cursor:pointer; }
  .svc > button:hover { color:var(--fg); border-color:var(--acc); }
  .svc-menu { position:absolute; right:0; top:calc(100% + 6px); min-width:200px; background:var(--panel); border:1px solid var(--line); border-radius:8px; box-shadow:0 8px 28px rgba(0,0,0,.55); padding:4px; display:none; z-index:80; }
  .svc-menu.open { display:block; }
  .svc-menu > div { padding:7px 10px; border-radius:6px; cursor:pointer; font-size:12.5px; color:var(--fg); white-space:nowrap; }
  .svc-menu > div:hover { background:#1b2634; }
  .svc-menu > div.danger { color:#ff9b9b; }
  .svc-menu > div.disabled { opacity:.45; cursor:default; }
  .svc-menu > div.disabled:hover { background:none; }
  .svc-menu .sep { height:1px; background:var(--line); margin:4px 6px; padding:0; cursor:default; }
  #svc-toast { position:fixed; right:16px; bottom:16px; z-index:98; padding:8px 14px; border-radius:8px; background:#132132; border:1px solid var(--line); color:var(--fg); font-size:12.5px; max-width:420px; display:none; box-shadow:0 4px 18px rgba(0,0,0,.5); white-space:pre-wrap; }
  #svc-toast.err { background:#2a1518; border-color:#5c2e2e; color:#ffb4b4; }
  #svc-overlay { position:fixed; inset:0; z-index:999; display:none; align-items:center; justify-content:center; flex-direction:column; gap:10px; background:rgba(6,10,14,.82); color:var(--fg); }
  #svc-overlay .t { font-size:16px; font-weight:600; }
  #svc-overlay .s { font-size:12.5px; color:var(--dim); max-width:520px; text-align:center; line-height:1.7; }
  #svc-logbox { position:fixed; left:50%; top:50%; transform:translate(-50%,-50%); width:min(760px,86vw); max-height:70vh; z-index:99; background:#0d141c; border:1px solid var(--line); border-radius:10px; padding:12px 14px; display:none; box-shadow:0 12px 40px rgba(0,0,0,.6); }
  #svc-logbox pre { margin:8px 0 0; max-height:52vh; overflow:auto; font-size:12px; line-height:1.5; color:#c6d4e2; white-space:pre-wrap; }
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
  #tl-body { font:12px/1.5 ui-monospace,Menlo,Consolas,monospace; background:#070b10; border:1px solid var(--line); border-radius:8px; height:calc(100vh - 250px); overflow-y:auto; }
  .tl-row { display:flex; align-items:baseline; gap:8px; padding:2px 8px; border-left:3px solid transparent; cursor:pointer; white-space:nowrap; overflow:hidden; }
  .tl-row:hover { background:#161b22; }
  .tl-row.tl-open { background:#161b22; }
  .tl-t { color:#8b949e; flex:0 0 auto; }
  .tl-badge { flex:0 0 auto; font-size:11px; padding:0 5px; border-radius:3px; }
  .tl-sum { flex:1 1 auto; overflow:hidden; text-overflow:ellipsis; }
  .tl-aux { flex:0 0 auto; color:#8b949e; }
  .tl-route { border-left-color:#bc8cff; }
  .tl-route .tl-badge { background:#3a2a5a; color:#d2a8ff; }
  .tl-net { border-left-color:#58a6ff; }
  .tl-net .tl-badge { background:#173a5e; color:#79c0ff; }
  .tl-log { border-left-color:#6e7681; }
  .tl-log .tl-badge { background:#30363d; color:#c9d1d9; }
  .tl-log.tl-w { border-left-color:#d29922; }
  .tl-log.tl-e { border-left-color:#f85149; }
  .tl-exc { border-left-color:#f85149; }
  .tl-exc .tl-badge { background:#5c1a1a; color:#ffb4b4; }
  .tl-watch .tl-badge { background:#33280f; color:#ffd479; }
  .inwatch { border:1px solid var(--line); border-radius:6px; padding:8px; margin-top:8px; background:#0d1117; }
  .inwatch input, .inwatch select { font-size:12px; }
  .inwatch-list { margin-top:6px; }
  .inwatch-list .wrow { display:flex; align-items:center; gap:8px; flex-wrap:wrap; font-size:12px; padding:3px 0; border-top:1px dashed var(--line); }
  /* 实例 Tab：上部操作区贴顶（main 才是滚动容器），字段树滚动时不跟着滚走。
     背景色必须不透明，否则下面内容会透出来；两个列表限高内滚，避免多命中 /
     多条监听时固定区把屏幕占满。
     padding-top 从 .page 挪到 sticky 自己身上：sticky 元素的原始 y 必须是 0，
     否则滚动头 16px 它会先跟着内容往上挪一下再粘住。 */
  #page-instances { padding-top:0; }
  #in-sticky { position:sticky; top:0; z-index:6; background:var(--bg); padding:16px 0 2px; }
  #in-sticky #in-list { max-height:24vh; overflow:auto; }
  #in-sticky .inwatch-list { max-height:18vh; overflow:auto; }
  .tl-detail { padding:6px 12px 10px 22px; background:#161b22; border-left:3px solid var(--line); font-size:12px; white-space:pre-wrap; word-break:break-all; }
  .tl-detail a { color:#58a6ff; text-decoration:none; }
  .tl-detail a:hover { text-decoration:underline; }
  /* 数据库页：表名/链接用亮蓝，默认深蓝在深色背景上对比度不足。 */
  #page-db a { color:#58a6ff; text-decoration:none; }
  #page-db a:hover { text-decoration:underline; }
  /* 跨 Tab 定位：目标行闪烁高亮 + 失败提示条 */
  .locate-flash, .locate-flash td { animation: locateFlash 1.1s ease-in-out 2; }
  @keyframes locateFlash { 0%,100% { background:transparent; } 50% { background:#4a3a00; } }
  #locate-toast { position:fixed; left:50%; bottom:60px; transform:translateX(-50%); z-index:95; padding:6px 14px; border-radius:16px; background:#3d2b00; color:#ffd479; border:1px solid #7a5c00; font-size:12px; display:none; box-shadow:0 2px 10px rgba(0,0,0,.5); }
  .tl-newbar { position:fixed; bottom:18px; left:50%; transform:translateX(-50%); z-index:80; padding:6px 14px; border-radius:16px; background:#1f6feb; color:#fff; cursor:pointer; font-size:12px; box-shadow:0 2px 10px rgba(0,0,0,.5); }
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
  #page-network { padding-top:0; }
  #nw-toolbar { position:sticky; top:0; z-index:6; background:var(--bg); padding:16px 0 6px; border-bottom:1px solid var(--line); }
  .nwhead { position:sticky; z-index:5; background:var(--bg); padding:11px 0 7px; }
  .nwtable { margin-top:0; }
  .nwtable th { position:sticky; z-index:4; background:var(--bg); }
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
  /* 日志工具栏：输入框自适应宽度；按钮组整体不换行，窄窗口时整组移到下一行，
     不会出现「输入框变宽、后面的按钮被挤出去」 */
  #f-kw { flex:1 1 220px; min-width:180px; max-width:380px; }
  .lbtns { display:flex; align-items:center; gap:10px; flex:0 0 auto; }
  /* 来源开关（设备日志 / Flutter 输出）只切显隐：不重建 DOM。
     设备日志高频时一次重建几千行会让整个页面明显卡顿。 */
  #logview.nodev .devline, #logview.noflutter .fline { display:none; }
  #exc-overlay { position:fixed; top:56px; right:16px; z-index:99; max-width:420px; background:#5c1a1a; color:#ffb4b4; border:1px solid #c0392b; border-radius:8px; padding:8px 12px; font-size:13px; cursor:pointer; box-shadow:0 2px 12px rgba(0,0,0,.5); display:none; word-break:break-all; }
  .exccard { border:1px solid #5c2a2a; border-radius:8px; padding:10px 12px; margin-bottom:10px; background:#140e0e; }
  .exccard .exchead { color:#ff9d9d; font-weight:600; word-break:break-all; }
  .excframe { font-family:monospace; font-size:12px; padding:1px 0; word-break:break-all; }
  .excframe .muted { color:#666; }
  .excai { margin-top:8px; border-top:1px dashed #5c2a2a; padding-top:8px; font-size:12px; color:#e8d5d5; }
  .excai .aihead { color:#ffb4b4; font-weight:600; margin-bottom:4px; }
  .excai .aitext { white-space:pre-wrap; line-height:1.55; }
  .shwrap { position:relative; display:inline-block; max-width:100%; line-height:0; }
  .shwrap img { display:block; max-width:100%; border:1px solid #444; user-select:none; -webkit-user-drag:none; touch-action:none; }
  .shring { position:absolute; width:18px; height:18px; margin:-9px 0 0 -9px; border:2px solid #f0b429; border-radius:50%; pointer-events:none; display:none; box-shadow:0 0 0 3px rgba(240,180,41,.18); }
  .shline { position:absolute; height:2px; background:#f0b429; transform-origin:0 50%; pointer-events:none; display:none; opacity:.9; }
  .shrec { border:1px solid var(--line); border-radius:8px; padding:10px; background:#0e141c; }
  .shrec .hd { display:flex; align-items:center; gap:8px; flex-wrap:wrap; }
  .shrec .dot { width:8px; height:8px; border-radius:50%; background:#ef5350; display:none; }
  .shrec .dot.on { display:inline-block; animation:shblink 1.1s infinite; }
  @keyframes shblink { 50% { opacity:.25; } }
  .shsteps { max-height:42vh; overflow:auto; margin-top:8px; border-top:1px solid var(--line); font-size:12px; }
  .shstep { display:flex; align-items:flex-start; gap:6px; padding:3px 0; border-bottom:1px dashed #24303d; }
  .shstep .idx { color:#66788a; min-width:18px; text-align:right; }
  .shstep .ty { color:var(--acc); min-width:38px; }
  .shstep .ds { flex:1; color:#c6d4e2; word-break:break-all; }
  .shstep .del { color:#8aa0b4; cursor:pointer; }
  .shstatus { margin-top:8px; font-size:12px; color:#8aa0b4; white-space:pre-wrap; }
  .shstatus .err { color:#ef5350; }
  .shstatus .ok { color:#4caf50; }
  /* 性能 Tab：指标卡片 + 双曲线 + 进程内存构成 */
  .pf-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); gap:12px; }
  .pf-card { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:10px 14px; }
  .pf-card .k { color:var(--dim); font-size:12px; }
  .pf-card .v { font-size:22px; font-weight:600; margin-top:2px; font-variant-numeric:tabular-nums; }
  .pf-card .s { color:var(--dim); font-size:11px; margin-top:2px; line-height:1.4; }
  .pf-charts { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
  @media (max-width:900px) { .pf-charts { grid-template-columns:1fr; } }
  .pf-chart { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:10px 12px 6px; }
  .pf-chart .hd { display:flex; align-items:center; gap:12px; color:var(--dim); font-size:12px; margin-bottom:4px; flex-wrap:wrap; }
  .pf-chart .hd b { color:var(--fg); font-size:13px; }
  .pf-chart canvas { display:block; width:100%; height:150px; }
  .pf-legend span { margin-left:10px; white-space:nowrap; }
  .pf-legend i { display:inline-block; width:8px; height:8px; border-radius:2px; margin-right:4px; }
  .pf-memtable { font-size:12px; }
  .pf-memtable td { padding:4px 8px; border-bottom:1px solid var(--line); vertical-align:middle; }
  .pf-memtable tr:last-child td { border-bottom:none; }
  .pf-memtable .bar { height:6px; background:#1d2735; border-radius:3px; overflow:hidden; }
  .pf-memtable .bar i { display:block; height:6px; background:var(--acc); }
  /* 调试 Tab：VS Code 式一屏布局——左栏断点 / 路由栈 / 已记住（左侧栏），
     中栏调用栈 + 变量 + 求值（主区），右栏源码（编辑器），底部运行输出（调试控制台）。
     整页不滚，每个面板只在自己框里滚，不再用固定 max-height 一路堆卡片。 */
  #page-debug.active { display:flex; flex-direction:column; gap:10px; height:100%; min-height:0; overflow:hidden; }
  #page-debug .card { margin-bottom:0; padding:8px 12px; }
  #page-debug .row { margin-bottom:6px; gap:8px; }
  #page-debug button { padding:4px 9px; font-size:12px; }
  .dbg-tools { flex:0 0 auto; }
  .dbg-main { flex:1 1 auto; display:flex; gap:10px; min-height:0; }
  /* 三栏共用：内部滚动，绝不把自己撑得比父级高 */
  .dbg-col { display:flex; flex-direction:column; min-width:0; min-height:0; }
  /* 左栏整体可滚：窗口不够高时侧栏自己滚，绝不把断点输入区 / 列表压没 */
  .dbg-side { flex:0 0 300px; gap:10px; overflow:auto; }
  .dbg-side > .card { display:flex; flex-direction:column; min-height:0; }
  .dbg-side > .dbg-bpcard { flex:1 1 auto; min-height:190px; }
  .dbg-side > .dbg-sec { flex:0 0 auto; }
  /* 窄栏里的行一律允许换行，按钮不把状态文字挤成一条缝 */
  .dbg-side .row { flex-wrap:wrap; }
  .dbg-varcol { flex:1 1 420px; }
  #dbg-src-card { flex:1.05 1 460px; min-width:340px; }
  /* 断点输入：窄栏里两列排（路径 + 行号 / 条件 + 日志），否则五个控件各占一行把列表挤没 */
  .dbg-bpadd { display:flex; flex-direction:column; gap:6px; margin-bottom:6px; }
  .dbg-bprow { display:flex; gap:6px; min-width:0; }
  .dbg-bprow #dbg-bp-line { flex:0 0 72px; }
  .dbg-bpadd input, .dbg-bpadd button { width:auto; min-width:0; margin:0; font-size:12px; padding:4px 8px; }
  .dbg-bpadd input { flex:1 1 0; }
  .dbg-bpadd button { flex:1 1 0; }
  /* 源码面板的文件 / 条件 / 日志：右栏窄，同样两列排（文件名整行） */
  .dbg-srcadd { display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr); gap:6px; margin-bottom:6px; }
  .dbg-srcadd #dbg-src-file { grid-column:1 / -1; }
  .dbg-srcadd input { width:auto; min-width:0; margin:0; font-size:12px; padding:4px 8px; }
  /* 工具条：运行配置 / 接入会话并成一行（宽屏） */
  .dbg-tools2 { display:flex; align-items:flex-start; gap:14px; flex-wrap:wrap; }
  #page-debug .dbg-tools2 > .row { flex:1 1 400px; margin-bottom:0; }
  #dbg-bps { flex:1 1 auto; max-height:none; min-height:52px; }
  #dbg-routes { max-height:24vh; min-height:40px; }
  /* 路由栈小节：一条路由一块——首行「序号 + 路由名 / 当前 / 类型 + 跳转」，
     次行文件（整行省略），第三行 Widget/State/VM/Notifier 芯片（可换行、留间距）。
     300px 窄侧栏里也不再全挤在一行、类名换行叠在一起。 */
  .dbg-rtitem { padding:6px 0 7px; border-bottom:1px dashed var(--line); }
  .dbg-rtitem:last-child { border-bottom:none; padding-bottom:1px; }
  .dbg-rtrow { display:flex; align-items:center; gap:6px; min-width:0; }
  .dbg-rtidx { flex:0 0 auto; font:11px/16px ui-monospace,Menlo,Consolas,monospace;
    color:var(--dim); background:#182231; border:1px solid var(--line);
    border-radius:4px; padding:0 5px; }
  .dbg-rtname { flex:1 1 auto; min-width:0; overflow:hidden; text-overflow:ellipsis;
    white-space:nowrap; }
  .dbg-rtcur { color:var(--acc); font-weight:600; }
  .dbg-rttype { color:var(--dim); font-size:11px; }
  .dbg-rtjump { flex:0 0 auto; font-size:11px; line-height:16px; padding:0 7px;
    border:1px solid var(--line); border-radius:9px; color:var(--dim);
    text-decoration:none; white-space:nowrap; }
  .dbg-rtjump:hover { color:var(--acc); border-color:var(--acc); }
  .dbg-rtfile { margin-top:3px; min-width:0; font:11.5px/17px ui-monospace,Menlo,Consolas,monospace;
    white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .dbg-rtfile a { display:inline-block; max-width:100%; overflow:hidden;
    text-overflow:ellipsis; white-space:nowrap; vertical-align:bottom;
    color:#7cc4ff; text-decoration:none; }
  .dbg-rtfile a:hover { color:var(--acc); text-decoration:underline; }
  .dbg-rtfile a.dbg-rtmiss { color:var(--dim); font-style:italic; }
  /* 类名芯片：一个类一个块，不再用「/」连成一条挤在一起的长行 */
  .dbg-rtcls { display:flex; flex-wrap:wrap; gap:4px; margin-top:5px; }
  .dbg-rtchip { display:inline-flex; align-items:center; gap:2px; max-width:100%;
    padding:0 5px; border:1px solid var(--line); border-radius:9px;
    background:#141c26; font:11px/17px ui-monospace,Menlo,Consolas,monospace; }
  .dbg-rtchip > a { min-width:0; overflow:hidden; text-overflow:ellipsis;
    white-space:nowrap; color:#9ecbff; text-decoration:none; }
  .dbg-rtchip > a:hover { color:var(--acc); }
  .dbg-rtchip > span.muted { min-width:0; overflow:hidden; text-overflow:ellipsis;
    white-space:nowrap; }
  .dbg-rtchip-i { flex:0 0 auto; color:var(--dim); text-decoration:none; }
  .dbg-rtchip-i:hover { color:var(--acc); }
  #dbg-saved { max-height:13vh; min-height:34px; }
  #dbg-stack { flex:0 0 auto; max-height:min(24vh,200px); min-height:56px; }
  #dbg-vars { flex:1 1 auto; max-height:none; min-height:60px; margin-top:6px; padding-top:4px; border-top:1px solid var(--line); }
  #dbg-eval-out { flex:0 0 auto; max-height:76px; }
  #dbg-src-code { flex:1 1 auto; max-height:none; min-height:0; }
  /* 底部运行输出：高度可拖（拖卡片上沿，同 VS Code 终端；双击手柄复位）。
     高度存在 #page-debug 的 --dbg-out-h 上，没有就用默认 clamp，刷新后还记得。 */
  .dbg-outcard { flex:0 0 auto; position:relative; height:var(--dbg-out-h, clamp(170px,26vh,300px)); display:flex; flex-direction:column; }
  .dbg-outcard > #dbg-out { flex:1 1 auto; height:auto; min-height:0; }
  .dbg-outgrip { position:absolute; left:0; right:0; top:-5px; height:13px; cursor:row-resize; touch-action:none; z-index:2; }
  .dbg-outgrip::after { content:''; position:absolute; left:14px; right:14px; top:5px; height:3px; border-radius:2px; background:var(--line); }
  .dbg-outgrip:hover::after, .dbg-outgrip.on::after { background:var(--acc); }
  /* 运行输出查找 / 筛选：查找只高亮（黄）、筛选只留匹配行（绿）、同时命中橙，
     配色与交互对齐「文件查看」页；两个输入框宽度可收缩，窄窗口下不会把标题挤掉。 */
  .dbg-outq { flex:0 1 190px; min-width:104px; font-size:12px; padding:3px 8px; }
  #dbg-out mark { background:#e3b341; color:#0b0f14; border-radius:2px; }
  #dbg-out mark.mf { background:#46d68c; color:#07110b; }
  #dbg-out mark.mb { background:#f0883e; color:#241a0b; }
  .dbg-list { max-height:260px; overflow:auto; font-size:12px; }
  /* 小屏 / 窄窗口：退回上下堆叠，整页开始滚（保证不会把面板压成一条缝） */
  @media (max-width:1180px) {
    #page-debug.active { height:auto; overflow:visible; }
    .dbg-main { flex-wrap:wrap; }
    .dbg-side { flex:1 1 100%; flex-direction:row; }
    .dbg-side > .card { flex:1 1 260px; }
    .dbg-varcol { flex:1 1 100%; }
    #dbg-src-card { flex:1 1 100%; }
    #dbg-stack { max-height:34vh; }
    #dbg-vars { max-height:40vh; }
    #dbg-bps { max-height:40vh; }
    #dbg-src-code { max-height:60vh; }
    .dbg-outcard { height:var(--dbg-out-h, auto); }
    .dbg-outcard > #dbg-out { height:30vh; }
  }
  /* 窗口矮（笔记本电脑分屏）：一屏装不下就退回整页滚，保证断点区不被压成一条 */
  @media (max-height:840px) and (min-width:1181px) {
    #page-debug.active { height:auto; overflow:visible; }
    .dbg-main { min-height:520px; }
    #dbg-vars { max-height:40vh; }
    #dbg-src-code { max-height:60vh; }
    .dbg-outcard { height:var(--dbg-out-h, auto); }
    .dbg-outcard > #dbg-out { height:22vh; }
  }
  .dbg-bp, .dbg-fr, .dbg-var { display:flex; align-items:center; gap:8px; padding:4px 6px; border-bottom:1px dashed var(--line); }
  .dbg-bp .dot { width:7px; height:7px; border-radius:50%; background:#46d68c; flex:0 0 auto; }
  .dbg-bp.unres .dot { background:#e5484d; }
  .dbg-bp.off .p { text-decoration:line-through; color:var(--dim); }
  .dbg-bp .p, .dbg-fr .p, .dbg-var .p { flex:1 1 auto; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-family:ui-monospace,Menlo,Consolas,monospace; }
  .dbg-bp .cond { color:#ffd479; flex:0 0 auto; max-width:150px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .dbg-bp .x { color:#8aa0b4; cursor:pointer; padding:0 3px; flex:0 0 auto; }
  .dbg-bp .x:hover { color:var(--acc); }
  #dbg-src-code { font:12px/1.5 ui-monospace,Menlo,Consolas,monospace; background:#070b10; border:1px solid var(--line); border-radius:8px; padding:4px 0; margin-top:6px; overflow:auto; }
  .dbg-cl { display:flex; white-space:pre; }
  .dbg-cl .no { flex:0 0 auto; width:52px; text-align:right; padding-right:10px; color:#5b6b7c; cursor:pointer; user-select:none; }
  .dbg-cl .no:hover { color:var(--acc); background:#161b22; }
  .dbg-cl .tx { flex:1; min-width:0; padding-right:10px; overflow:hidden; }
  .dbg-cl .mk { flex:0 0 auto; width:30px; color:#ff7b72; }
  .dbg-cl.bp { background:rgba(220,60,60,.13); }
  .dbg-cl.bp .no { color:#ff7b72; font-weight:600; }
  .dbg-cl.saved { background:rgba(220,60,60,.06); }
  .dbg-cl.saved .no { color:#a06060; }
  .dbg-cl.cur { background:rgba(240,180,41,.13); box-shadow:inset 3px 0 0 #f0b429; }
  .dbg-cl.cur .no { color:#f0b429; font-weight:600; }
  .dbg-fr { cursor:pointer; }
  .dbg-fr:hover { background:#161b22; }
  .dbg-fr.cur { background:#1b2532; box-shadow:inset 2px 0 0 #f0b429; }
  .dbg-fr .fn { color:var(--acc); flex:0 0 auto; max-width:55%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .dbg-var .fn { color:#ffd479; flex:0 0 auto; max-width:38%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  /* 变量筛选：命中的那段名字高亮（深色底 + 亮字，跟 .fn 的黄字拉开层次） */
  #dbg-vars mark { background:#4a3a00; color:#ffe9a8; padding:0 1px; border-radius:2px; font-weight:600; }
  /* 可展开的变量（对象 / List / Map）：箭头占位固定宽度，整行可点。 */
  .dbg-var.kid { cursor:pointer; }
  .dbg-var.kid:hover { background:#161b22; }
  .dbg-var .arw { flex:0 0 auto; width:11px; text-align:center; color:var(--dim); font-size:9px; }
  #dbg-out { font:12px/1.45 ui-monospace,Menlo,Consolas,monospace; background:#070b10; border:1px solid var(--line); border-radius:8px; padding:8px; overflow:auto; white-space:pre-wrap; word-break:break-all; }
  #dbg-bar { position:fixed; left:50%; bottom:18px; transform:translateX(-50%); z-index:96; display:none; align-items:center; flex-wrap:nowrap; gap:6px; padding:6px 8px 6px 12px; background:#0e1620; border:1px solid var(--line); border-radius:10px; box-shadow:0 6px 24px rgba(0,0,0,.55); }
  #dbg-bar.on { display:flex; }
  #dbg-bar.paused { border-color:#f0b429; }
  #dbg-bar .why { flex:0 1 auto; color:var(--dim); font-size:12px; max-width:220px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  #dbg-bar.paused .why { color:#f0b429; }
  #dbg-bar button { flex:0 0 auto; padding:4px 10px; font-size:12px; white-space:nowrap; }
  #dbg-bar button:disabled { opacity:.4; cursor:not-allowed; }
  #dbg-bar .sep { flex:0 0 auto; width:1px; height:18px; background:var(--line); }
  #dbg-toast { position:fixed; left:50%; bottom:72px; transform:translateX(-50%); z-index:97; padding:6px 14px; border-radius:14px; background:#5c1a1a; color:#ffb4b4; border:1px solid #c0392b; font-size:12px; display:none; box-shadow:0 2px 10px rgba(0,0,0,.5); max-width:70vw; }
</style>
</head>
<body>
<header>
  <h1>xb_ume 工具箱</h1>
  <div class="tabs">
    <div class="tab active" data-tab="daemon">守护进程</div>
    <div class="tab" data-tab="ai">AI 调试</div>
    <div class="tab" data-tab="debug">调试</div>
    <div class="tab" data-tab="logs">日志</div>
    <div class="tab" data-tab="timeline">时间轴</div>
    <div class="tab" data-tab="exc">异常<span id="exc-badge" style="display:none;background:#c0392b;color:#fff;border-radius:9px;font-size:11px;padding:0 6px;margin-left:4px"></span></div>
    <div class="tab" data-tab="sandbox">应用沙盒</div>
    <div class="tab" data-tab="db">数据库</div>
    <div class="tab" data-tab="routes">路由栈</div>
    <div class="tab" data-tab="network">Network</div>
    <div class="tab" data-tab="storage">Storage</div>
    <!-- 状态面板暂时隐藏，代码保留，恢复时去掉 display:none -->
    <div class="tab" data-tab="status" style="display:none">状态</div>
    <div class="tab" data-tab="instances">实例</div>
    <div class="tab" data-tab="shot">截图</div>
    <div class="tab" data-tab="perf">性能</div>
    <!-- Widget 树功能暂时隐藏（parent 参照标注定位待优化），代码保留，恢复时去掉 display:none -->
    <div class="tab" data-tab="wtree" style="display:none">Widget树</div>
    <div class="tab" data-tab="auto">自动化</div>
    <div class="tab" data-tab="compare">对比</div>
  </div>
  <div id="hdr-right">
    <span id="svc-badge-gui" class="svc-badge" title="GUI 进程">GUI ○</span>
    <span id="svc-badge-daemon" class="svc-badge" title="守护进程">daemon ○</span>
    <div class="svc">
      <button id="svc-btn" onclick="svcToggle(event)" title="服务控制：重启 / 停止 GUI 与守护进程、重新部署">服务 ▾</button>
      <div class="svc-menu" id="svc-menu">
        <div onclick="svcAct('restart','gui')">重启 GUI</div>
        <div onclick="svcAct('restart','daemon')">重启守护进程</div>
        <div onclick="svcAct('restart','all')">重启全部</div>
        <div class="sep"></div>
        <div class="danger" onclick="svcAct('stop','gui')">停止 GUI</div>
        <div class="danger" onclick="svcAct('stop','daemon')">停止守护进程</div>
        <div class="sep"></div>
        <div id="svc-redeploy">重新部署并重启</div>
        <div id="svc-redeploy-hint" class="disabled" style="display:none">（需先用 --install 记录源码目录）</div>
        <div onclick="svcShowLog()">查看部署日志</div>
      </div>
    </div>
    <span id="vmstat" class="bad" style="display:none"></span>
    <select id="vmsel" style="display:none" onchange="setVmFilter(this.value)" title="选择要查看哪个调试会话（Flutter 输出来源），IDE 跳转不受影响"></select>
    <select id="hdrdev" onchange="selectDevice(this.value)"></select>
    <label class="chk" id="hdr-awake-wrap" style="display:none" title="调试期间保持屏幕常亮（防长场景 / AI 循环中途熄屏）：鸿蒙覆盖熄屏时间（≈24.8 天，手机重启后失效）；Android 仅充电时生效。只改运行时状态，不写系统设置"><input type="checkbox" id="hdr-awake" onchange="setKeepAwake(this.checked)">常亮</label>
    <button onclick="refreshAll()" title="立即扫描设备并刷新调试会话状态">刷新</button>
    <div id="wsdot" title="页面连接状态"></div>
  </div>
</header>
<div id="svc-overlay"><div class="t"></div><div class="s"></div></div>
<div id="svc-toast"></div>
<div id="svc-logbox"><b style="font-size:13px">部署日志</b><span class="muted" style="font-size:11px;margin-left:8px">~/.xb_ume_ide/install.log</span><div style="float:right"><button onclick="document.getElementById('svc-logbox').style.display='none'">关闭</button></div><pre id="svc-log-pre"></pre></div>
<div id="exc-overlay" onclick="excGoTab()"></div>
<main>
  <section class="page active" id="page-daemon">
    <div class="card">
      <div class="row"><b>守护进程状态</b><button onclick="refreshDaemon()">刷新</button><button class="primary" onclick="restartDaemon()">重启守护进程</button><button onclick="rtOp('reassemble')" title="ext.flutter.reassemble：重建全部 Widget（实例 Tab 字段写回后立即生效）；完整热重载需 IDE 编译 kernel，此处不做">UI 重建</button><button onclick="rtOp('gc')" title="_collectAllGarbage：触发全量 GC（泄漏检测前用）">触发 GC</button><span id="rt-op-stat" class="muted"></span></div>
      <div id="daemon-status" class="muted">查询中…</div>
    </div>
    <div class="card">
      <div class="row"><b>MCP 服务</b><span id="mcp-status" class="muted">查询中…</span><button id="mcp-toggle" onclick="toggleMcp(this)">启动</button><button onclick="copyMcpConfig(this)">复制 MCP 配置</button><button onclick="refreshMcp(true)">刷新</button><label class="chk" style="margin-left:6px" title="勾选后再打开工具箱会自动拉起 MCP HTTP 服务（默认 46140）；取消勾选不会停掉正在运行的服务"><input type="checkbox" id="mcp-auto" onchange="setMcpAuto(this)">随工具箱启动</label><label class="chk" style="margin-left:6px" title="勾选后启动的 MCP 多开放 xbume_eval：可在 app 进程内求值任意表达式（能读写运行时状态），改了需重启服务才生效"><input type="checkbox" id="mcp-eval" onchange="setMcpEval(this)">允许 eval</label></div>
      <div id="mcp-detail" class="muted" style="margin-top:4px">让 Qoder / Cursor / Claude Code 直接驱动本机调试会话（会话发现、找组件、点击、场景、设备）；工具清单与配置示例见 MCP_GUIDE.md</div>
    </div>
    <div class="card">
      <div class="row"><b>IDE 优先级</b><button onclick="resetIdeOrder()">恢复默认</button><button onclick="openConfig()">打开配置文件</button></div>
      <ul id="ide-order-list" class="ide-list"></ul>
      <div id="ide-order-tip" class="muted" style="margin-top:4px">拖动 ☰ 调整优先级，松手即保存；进入本页会自动扫描已安装的 IDE，新装的追加到列表末尾；未安装的自动跳过</div>
    </div>
  </section>
  <section class="page" id="page-ai">
    <div class="card">
      <div class="row">
        <b>AI 自动调试</b>
        <span id="ai-status" class="muted">未就绪</span>
        <button class="primary" onclick="aiSetup(this)">一键开启</button>
        <button onclick="aiCopyPrompt(this)">复制 AI 指令</button>
        <button onclick="aiCopyConfig(this)">复制 MCP 配置</button>
      </div>
      <div class="row" style="margin-top:8px;gap:10px;flex-wrap:nowrap">
        <label class="chk" style="display:flex;align-items:center;flex:1;min-width:0" title="Flutter 项目根目录（含 pubspec.yaml）。候选项来自当前调试会话反推的项目根与最近用过的目录，也可直接粘路径">项目目录
          <input id="ai-dir" list="ai-dir-list" placeholder="/path/to/your/flutter/app" style="flex:1;min-width:0;width:0;margin-left:6px">
          <datalist id="ai-dir-list"></datalist>
        </label>
        <button onclick="aiPickDir()" style="flex:0 0 auto;margin-left:6px;padding:6px 10px" title="浏览本机目录挑项目根（浏览器给不了绝对路径，这里由后台列目录）">选择…</button>
        <label class="chk" style="display:flex;align-items:center;flex:0 0 auto;margin-right:0" title="app 要跑在哪台设备（AI 自己 flutter run -d 它）；留空自动：唯一手机 > 桌面">设备
          <select id="ai-device" style="width:210px;margin-left:6px"></select>
        </label>
      </div>
      <div class="muted" style="margin-top:8px;line-height:1.6">
        点「一键开启」会：启动带 <code>xbume_eval</code> 的 MCP（已在跑就复用，参数不一致只重启自己记录的那个）
        → 生成一段指令并自动复制。把指令粘给 AI，它会先看有没有可复用的会话（没有就自己
        <code>flutter run</code> 拉起 app）、复现现场、定位到源码行、改代码、热重载、复跑验证。
      </div>
      <div class="muted" style="margin-top:6px;line-height:1.6;font-size:12px">
        「项目目录」候选项来自：当前已连接的调试会话（按 app 库路径反推项目根）+ 最近用过的目录，也可直接粘路径；
        「设备」默认跟随右上角设备选择器。右上角的 <b>VM 会话</b>是已经在跑的调试会话（日志 / 时间轴用）；
        由本工具拉起的（调试 Tab「启动 / 复用」或 AI 自己）AI 调试会直接<b>复用</b>、也能热重载；
        IDE 拉起的只能只读接入（能看能下断点，热重载回 IDE 按 <code>r</code>）。
      </div>
      <pre id="ai-prompt" style="white-space:pre-wrap;max-height:calc(100vh - 400px);min-height:180px;overflow:auto;font-size:12px;line-height:1.55;margin:10px 0 0">点「一键开启」后，这里会出现可直接粘给 AI 的指令</pre>
    </div>
    <div id="ai-dir-pick" style="display:none;position:fixed;inset:0;z-index:120;background:rgba(3,7,12,.62)" onclick="if(event.target===this)aiPickClose()">
      <div style="position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:min(780px,92vw);max-height:80vh;display:flex;flex-direction:column;background:#0f1620;border:1px solid #223041;border-radius:10px;box-shadow:0 12px 40px rgba(0,0,0,.6)">
        <div class="row" style="padding:10px 12px;gap:6px;border-bottom:1px solid #223041;flex-wrap:nowrap">
          <b style="white-space:nowrap">选择项目目录</b>
          <button onclick="aiPickUp()" id="ai-pick-up" style="padding:4px 9px" title="上一级">↑ 上级</button>
          <button onclick="aiPickLoad('')" style="padding:4px 9px" title="回到用户主目录">主目录</button>
          <input id="ai-pick-path" placeholder="绝对路径，回车跳转" style="flex:1;min-width:0;width:0;font-size:12px" onkeydown="if(event.key==='Enter')aiPickLoad(this.value)">
          <button onclick="aiPickClose()" style="padding:4px 9px" title="关闭（Esc）">✕</button>
        </div>
        <div id="ai-pick-cand" class="row" style="padding:6px 12px;gap:6px;flex-wrap:wrap;border-bottom:1px solid #223041"></div>
        <div id="ai-pick-list" style="flex:1;overflow:auto;padding:4px 6px"></div>
        <div class="row" style="padding:10px 12px;gap:8px;border-top:1px solid #223041;flex-wrap:nowrap">
          <span id="ai-pick-tip" class="muted" style="flex:1;min-width:0;font-size:12px"></span>
          <button class="primary" onclick="aiPickChoose()">选定此目录</button>
        </div>
      </div>
    </div>
  </section>
  <section class="page" id="page-debug">
    <!-- 顶部工具条：会话 / 目录 / 设备 / 运行配置 / 接入（对应 VS Code 调试视图顶部） -->
    <div class="card dbg-tools">
      <div class="row">
        <b>调试会话</b>
        <span id="dbg-stat" class="muted">未连接</span>
        <span id="dbg-msg" class="muted" style="font-size:12px;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"></span>
        <button onclick="dbgStatus()">刷新</button>
      </div>
      <div class="row" style="margin-top:4px;gap:10px;flex-wrap:wrap">
        <label class="chk" style="display:flex;align-items:center;flex:1 1 260px;min-width:220px" title="Flutter 项目根目录（含 pubspec.yaml），也是断点相对路径的基准">项目目录
          <input id="dbg-dir" list="dbg-dir-list" placeholder="/path/to/your/flutter/app" style="flex:1;min-width:0;width:0;margin-left:6px" onchange="dbgLoadSaved();dbgProfileRefresh()">
          <datalist id="dbg-dir-list"></datalist>
        </label>
        <label class="chk" style="display:flex;align-items:center;flex:0 0 auto" title="flutter run -d 哪台设备。默认 macOS 桌面；手机上的会话请用下方「接入」">设备
          <select id="dbg-device" style="width:190px;margin-left:6px"></select>
        </label>
        <label class="chk" style="display:flex;align-items:center;flex:0 0 auto" title="入口文件，留空用 lib/main.dart（flutter run 默认）">入口
          <input id="dbg-target" placeholder="lib/main.dart" style="width:150px;margin-left:6px;font-size:12px">
        </label>
        <button class="primary" onclick="dbgStart(this)">启动 / 复用</button>
        <button onclick="dbgStop(this)" title="只停本工具（GUI/MCP）拉起的 flutter run，按精确 PID 停">停止</button>
      </div>
      <!-- 运行配置与接入会话：宽屏并排一行，窄屏自动折行 -->
      <div class="dbg-tools2" style="margin-top:4px">
        <div class="row" style="gap:8px;flex-wrap:wrap">
          <b style="font-size:12px" title="项目级运行配置：启动前要跑的准备命令、按平台追加给 flutter run 的参数、停止后的清理（run_profiles.json，按项目根生效）">运行配置</b>
          <span id="dbg-profile" class="muted" style="font-size:12px;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">未配置</span>
          <button onclick="dbgProfileRefresh(this)" style="flex:0 0 auto">刷新</button>
          <button onclick="dbgProfileOpen()" style="flex:0 0 auto" title="打开 run_profiles.json（只读摘要来自它：预启动命令 / 额外参数 / 停止清理）">打开配置</button>
        </div>
        <div class="row" style="gap:10px;flex-wrap:nowrap">
          <label class="chk" style="display:flex;align-items:center;flex:1;min-width:0" title="接入已经在跑的调试会话（含 IDE 拉起的）：断点/单步可用；热重载需要本工具拉起的会话">接入会话
            <select id="dbg-attach" style="flex:1;min-width:0;margin-left:6px"></select>
          </label>
          <button onclick="dbgAttach(this)">接入</button>
          <button onclick="dbgDetach(this)" title="只断开调试连接，app 继续跑">断开</button>
        </div>
      </div>
      <div class="muted" style="margin-top:6px;font-size:12px;line-height:1.6">
        启动走 <code>flutter run</code>（与 AI 的 <code>xbume_app_launch</code> 同一条链路）：已在跑的会话直接<b>复用</b>，不重装包，AI 也能复用这里起的会话。
        接入的外部会话（IDE 拉起的）可打断点/单步，热重载请回 IDE 按 <code>r</code>。断点只调 VM service，不改源码、不需编辑器。
      </div>
    </div>
    <div class="dbg-main">
      <!-- 左栏：断点 / 路由栈 / 已记住（VS Code 左侧栏） -->
      <div class="dbg-side dbg-col">
        <div class="card dbg-bpcard">
          <div class="row">
            <b>断点</b>
            <span id="dbg-bp-n" class="muted" style="font-size:12px"></span>
            <button id="dbg-bp-all" onclick="dbgToggleAllBps(this)" title="当前会话还没有断点">停用全部</button>
            <button onclick="dbgSrcOpen()" style="margin-left:auto" title="打开项目源码，点行号就能下断点 / 再点取消（不用手输文件:行）">源码下断点</button>
            <button onclick="dbgListBp(this)">刷新</button>
          </div>
          <div class="dbg-bpadd">
            <div class="dbg-bprow">
              <input id="dbg-bp-path" placeholder="路径，可相对项目根：lib/main.dart" onkeydown="if(event.key==='Enter')dbgAddBp()">
              <input id="dbg-bp-line" placeholder="行号" onkeydown="if(event.key==='Enter')dbgAddBp()">
            </div>
            <div class="dbg-bprow">
              <input id="dbg-bp-cond" placeholder="条件（可空）" onkeydown="if(event.key==='Enter')dbgAddBp()">
              <input id="dbg-bp-log" placeholder="日志表达式（命中不暂停，如 'i=$i'）" onkeydown="if(event.key==='Enter')dbgAddBp()">
            </div>
            <div class="dbg-bprow">
              <button class="primary" id="dbg-bp-add" onclick="dbgAddBp(this)">加断点</button>
              <button id="dbg-bp-cancel" onclick="dbgCancelBpEdit()" style="display:none" title="放弃修改，回到新加断点">取消</button>
            </div>
          </div>
          <div id="dbg-bps" class="dbg-list"></div>
        </div>
        <div class="card dbg-sec">
          <div class="row" style="gap:6px">
            <b style="font-size:12px">路由栈</b>
            <button onclick="dbgRtLoad(this)" style="margin-left:auto;flex:0 0 auto" title="读取当前调试会话的 Navigator 路由栈，并列出每条路由对应的源码文件">刷新</button>
          </div>
          <div id="dbg-rt-n" class="muted" style="font-size:11px;line-height:1.4;margin-bottom:4px">刷新后列出当前会话的路由与文件：点文件名在下方源码面板打开，点行号即下断点；类名后的 ◎ 去「实例」查对象</div>
          <div id="dbg-routes" class="dbg-list"></div>
        </div>
        <div class="card dbg-sec">
          <div class="row" style="gap:6px">
            <b style="font-size:12px">已记住</b>
            <button onclick="dbgLoadSaved(this)" style="margin-left:auto;flex:0 0 auto">刷新</button>
            <button onclick="dbgShowAllSaved(this)" title="按项目根分组列出所有项目记住的断点（换项目后也能看见/清理）" style="flex:0 0 auto">全部项目</button>
            <button onclick="dbgForgetSaved(this)" title="清空该项目记住的断点，下次连接不再自动恢复（不影响当前会话里的断点）" style="flex:0 0 auto">忘记</button>
          </div>
          <div id="dbg-saved-n" class="muted" style="font-size:11px;line-height:1.4;margin-bottom:4px">重连同一项目自动恢复</div>
          <div id="dbg-saved" class="dbg-list"></div>
        </div>
      </div>
      <!-- 中栏：调用栈 / 变量 / 求值（主区，变量树吃掉剩余高度） -->
      <div class="card dbg-varcol dbg-col">
        <div class="row"><b>调用栈 / 变量</b><span id="dbg-frame" class="muted" style="font-size:12px;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"></span><button onclick="dbgStack()" style="flex:0 0 auto">刷新</button></div>
        <div id="dbg-stack" class="dbg-list"></div>
        <div class="row" style="margin-top:6px;gap:6px;flex-wrap:nowrap">
          <input id="dbg-var-filter" placeholder="筛选变量：名字包含即可（忽略大小写），如 count" style="flex:1;min-width:0;font-size:12px" title="模糊匹配变量名；命中项与通往它的祖先保留，其余隐藏。输入停下后会自动把整棵树拉下来补扫，Esc 清空" oninput="dbgVarFilterOnInput()" onkeydown="if(event.key==='Escape')dbgVarFilterClear()">
          <label class="muted" style="font-size:11px;flex:0 0 auto;display:flex;align-items:center;gap:3px;cursor:pointer;white-space:nowrap" title="只显示声明在你项目包里的字段；框架 / 依赖库里的字段收起来只计数（如 ChangeNotifier 的 _count）。取消勾选看全部，扫描也不再跳过框架对象"><input id="dbg-var-mine" type="checkbox" checked style="margin:0" onchange="dbgVarMineToggle()">我的</label>
          <span id="dbg-var-fstat" class="muted" style="font-size:11px;flex:0 0 auto"></span>
        </div>
        <div id="dbg-vars" class="dbg-list"></div>
        <div class="row" style="margin-top:6px;gap:6px;flex-wrap:nowrap">
          <input id="dbg-eval" placeholder="选中帧里求值，如 widget.runtimeType" style="flex:1;min-width:0;font-size:12px" onkeydown="if(event.key==='Enter')dbgEval()">
          <button onclick="dbgEval()">求值</button>
        </div>
        <div id="dbg-eval-out" class="muted" style="font-size:12px;margin-top:4px;word-break:break-all;overflow:auto"></div>
      </div>
      <!-- 右栏：源码（点「源码下断点」才出现，关掉时中栏自动变宽） -->
      <div class="card dbg-col" id="dbg-src-card" style="display:none">
        <div class="row" style="gap:6px">
          <b>源码</b>
          <button onclick="dbgSrcClose()" style="margin-left:auto">收起</button>
        </div>
        <div class="dbg-srcadd">
          <input id="dbg-src-file" list="dbg-src-files" placeholder="输入文件名过滤，如 error_test_page.dart（回车打开）" onchange="dbgSrcPick()" onkeydown="if(event.key==='Enter')dbgSrcPick()">
          <datalist id="dbg-src-files"></datalist>
          <input id="dbg-src-cond" placeholder="条件（可空）" title="填了再点行号：这一行下的是条件断点">
          <input id="dbg-src-log" placeholder="日志表达式（可空，如 i=$i）" title="填了再点行号：这一行下的是日志断点（命中不暂停）">
        </div>
        <div id="dbg-src-info" class="muted" style="font-size:12px;margin-top:2px;margin-bottom:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"></div>
        <div id="dbg-src-code"></div>
      </div>
    </div>
    <!-- 底部：运行输出（VS Code 调试控制台的位置，自己滚，拖上沿可调高） -->
    <div class="card dbg-outcard">
      <div class="dbg-outgrip" id="dbg-outgrip" title="拖动调整运行输出高度，双击复位" onpointerdown="dbgOutHDrag(event)" ondblclick="dbgOutHReset()"></div>
      <div class="row"><b>运行输出</b><span id="dbg-out-n" class="muted" style="font-size:12px"></span>
        <input id="dbg-out-search" class="dbg-outq" placeholder="查找（高亮）" title="在运行输出里查找，命中片段高亮成黄色、行不过滤；Esc 清空" oninput="dbgOutQuery('s', this.value)" onkeydown="if(event.key==='Escape'){this.value='';dbgOutQuery('s','');}">
        <input id="dbg-out-filter" class="dbg-outq" placeholder="筛选（只留匹配行）" title="只保留包含关键字的行，命中片段高亮成绿色；两个框都填时同时命中显示橙色；Esc 清空" oninput="dbgOutQuery('f', this.value)" onkeydown="if(event.key==='Escape'){this.value='';dbgOutQuery('f','');}">
        <label class="chk" style="margin-left:auto;font-size:12px"><input type="checkbox" id="dbg-follow" checked>自动滚到底</label>
        <span class="lbtns" style="gap:8px"><button onclick="dbgOutCopy(this)" title="复制当前显示的全部输出（筛选后就只复制筛选后的行）">复制</button>
        <button onclick="dbgClearOut()">清屏</button></span>
      </div>
      <pre id="dbg-out"></pre>
    </div>
  </section>
  <section class="page" id="page-logs">
    <div class="row">
      <div class="fgroup">
        <b class="gtitle">设备日志</b>
        <label class="chk"><input type="checkbox" id="f-src-device" checked onchange="logToggleSrc()">启用</label>
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
        <label class="chk"><input type="checkbox" id="f-src-flutter" checked onchange="logToggleSrc()">启用</label>
        <span class="gsep"></span>
        <span class="muted" style="font-size:12px">按页头会话选择</span>
      </div>
      <input id="f-kw" placeholder="关键字过滤（空格分隔多个，任一命中即显示）" title="空格分隔多个关键字，日志包含任一关键字即保留" oninput="logKwInput()">
      <span class="lbtns">
        <button onclick="copyLogs(this)" title="复制当前显示（含过滤）的全部日志到剪贴板">复制</button>
        <button onclick="logTop()" title="滚动到最早日志">到顶</button>
        <button onclick="logBottom()" title="滚动到最新日志；到底后恢复自动跟随新日志">到底</button>
        <button onclick="togglePause(this)">暂停</button>
        <button onclick="clearLogs()">清屏</button>
        <a href="/api/logs.txt" target="_blank"><button>导出</button></a>
      </span>
    </div>
    <div id="logview"><span class="muted">暂无日志</span></div>
    <div class="muted" style="margin-top:6px">关键字过滤支持空格分隔多个，日志包含任一关键字即显示（实时生效，新日志到达时增量追加，不打断选中/复制；新行只在底部追加，往上翻不会被强制拉底，需回到底部跟随可点底部或再滚到底）。打印规则：未选 VM 也未选设备时不打印；选 VM 打印该会话的 Flutter 输出；选设备打印该设备的设备日志及属于该设备的 VM 输出；都选则两个源都打印（互不约束）。「设备日志」= 已连接设备的全量系统日志（logcat/hilog/iOS log）；「Flutter 输出」= 调试会话的 stdout/stderr。</div>
  </section>
  <section class="page" id="page-timeline">
    <div class="row">
      <div class="fgroup">
        <b class="gtitle">范围</b>
        <select id="tl-range" onchange="tlRender()">
          <option value="1">近 1 分钟</option>
          <option value="5" selected>近 5 分钟</option>
          <option value="30">近 30 分钟</option>
          <option value="0">全部</option>
        </select>
        <span class="gsep"></span>
        <span class="vlv">
          <label class="chk"><input type="checkbox" id="tl-t-route" checked onchange="tlRender()">路由</label>
          <label class="chk"><input type="checkbox" id="tl-t-net" checked onchange="tlRender()">网络</label>
          <label class="chk"><input type="checkbox" id="tl-t-log" checked onchange="tlRender()">日志</label>
          <label class="chk"><input type="checkbox" id="tl-t-exc" checked onchange="tlRender()">异常</label>
          <label class="chk"><input type="checkbox" id="tl-t-watch" checked onchange="tlRender()">监听</label>
        </span>
      </div>
      <div class="fgroup" title="日志量很大：默认只看 Flutter 输出的信息级与设备日志的警告/错误">
        <b class="gtitle">日志级别</b>
        <span class="vlv">
          <label class="chk"><input type="checkbox" id="tl-lv-flutter" checked onchange="tlRender()">Flutter I</label>
          <label class="chk"><input type="checkbox" id="tl-lv-warn" checked onchange="tlRender()">W/E</label>
          <label class="chk"><input type="checkbox" id="tl-lv-all" onchange="tlRender()">全部 D/V</label>
        </span>
      </div>
      <input id="tl-kw" placeholder="关键字（路由名/URL/日志/异常）" oninput="tlKwInput()" style="width:260px">
      <button onclick="tlPause(this)" id="tl-pause-btn">暂停</button>
      <button onclick="tlToLatest()" title="滚到最新事件">最新</button>
      <button onclick="tlClear()" title="清空时间轴当前显示的全部事件（路由/网络/监听/日志/异常）；各 Tab 的原始数据不受影响">清空</button>
      <button onclick="tlCopy()" title="复制当前过滤后的时间轴文本">复制</button>
      <span class="muted" id="tl-stat">请先选择 VM</span>
    </div>
    <div id="tl-body"><span class="muted">请先在页头右侧选择调试会话</span></div>
    <div id="tl-newbar" class="tl-newbar" style="display:none" onclick="tlToLatest()"></div>
    <div class="muted" style="margin-top:6px">把路由变化、网络请求、日志、异常按同一时间轴排列，看「点完按钮后发生了什么」不用来回切 Tab。路由/网络来自 app 内 xb_ume 记录（页面激活时 1.5s 增量同步，时间取 app 端记录时刻）；日志取电脑接收时刻，异常取捕获时刻。需要 app 在 MaterialApp 的 navigatorObservers 里加 XBUme.routeObserver（example 已配置）并接入 Network 模块。点击行展开详情，详情内可跳到对应 Tab 查看原始数据。</div>
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
  <section class="page" id="page-db">
    <div class="row">
      <b id="db-title" class="muted">未打开数据库</b>
      <span id="db-stat" class="muted"></span>
      <button onclick="dbReload()" title="从 app 沙盒重新拉取数据库文件（库更新后用）">重新拉取</button>
      <button onclick="dbClose()" title="关闭并删除本机缓存副本（不影响 app 内数据库）">关闭</button>
    </div>
    <div class="row">
      <input id="db-sql" placeholder="SELECT * FROM 表名 LIMIT 100（⌘/Ctrl+Enter 执行）" style="flex:1;min-width:320px;font-family:monospace" onkeydown="if(event.key==='Enter'&&(event.metaKey||event.ctrlKey))dbRun()">
      <button class="primary" onclick="dbRun()">执行</button>
      <a href="javascript:void(0)" onclick="dbCsv()"><button>导出 CSV</button></a>
      <span id="db-msg" class="muted"></span>
    </div>
    <div style="display:flex;gap:14px;align-items:flex-start;margin-top:8px">
      <div style="width:230px;flex:none">
        <div class="muted" style="margin-bottom:4px">表 / 视图</div>
        <div id="db-tables"><span class="muted">未打开</span></div>
      </div>
      <div style="flex:1;min-width:0">
        <div id="db-schema"></div>
        <div id="db-result" style="margin-top:6px"></div>
        <div class="row" id="db-pager" style="display:none">
          <button onclick="dbPage(-1)">上一页</button>
          <button onclick="dbPage(1)">下一页</button>
          <span class="muted" id="db-pageinfo"></span>
        </div>
      </div>
    </div>
    <div class="muted" style="margin-top:6px">在「应用沙盒」里点 .db / .sqlite 文件的「查询」进入：GUI 经 VM service 分段拉取文件到本机缓存（app 端零改动），再用本机 sqlite3 命令行只读执行——支持表结构、分页浏览、任意只读 SQL 与 CSV 导出。写操作会被拒绝；macOS 自带 sqlite3，Windows/Linux 需安装并加入 PATH。</div>
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
    <div id="nw-toolbar" style="display:flex;align-items:center;gap:10px">
      <input id="nw-kw" placeholder="关键字过滤（URL/方法/状态）" oninput="nwRender()" style="width:260px">
      <button onclick="nwRefresh()" title="重新拉取 app 内 ume 已捕获的请求">刷新</button>
      <button onclick="nwClear()" title="清空 app 内 ume 的 Network 记录">清空</button>
      <span class="muted">选中会话 app 内 xb_ume Network 模块捕获的请求（与手机端面板同源）</span>
    </div>
    <div id="nw-body"><span class="muted">请先选择 VM</span></div>
    <div class="muted" style="margin-top:6px">数据来自 app 内 xb_ume 的 Network 模块（需 app 接入 xb_ume 并配置 HttpOverrides/Dio 拦截）。点击行展开/收起详情（可同时展开多条，互不影响）；行内 cURL 复制到剪贴板；「重发」在电脑上直接按原方法/URL/请求头/请求体发起请求（不经过手机），结果附在该条详情下方。</div>
  </section>
  <section class="page" id="page-storage">
    <div id="st-toolbar" style="display:flex;align-items:center;gap:10px">
      <select id="st-file" onchange="stLoad()" style="max-width:420px"></select>
      <button onclick="stLoad()" title="重新读取选中的 shared_prefs 文件">刷新</button>
      <input id="st-kw" placeholder="关键字过滤" oninput="stRender()" style="width:180px">
      <button onclick="stAddRow()">新增</button>
      <button onclick="stReloadCache()" title="调用 app 内 SharedPreferences.reload() 重读存储，让直写文件后也能立即读到（平台层仍缓存时无效）">刷新 app 缓存</button>
      <span class="muted">shared_preferences 存储（shared_prefs XML）</span>
    </div>
    <div id="st-body"><span class="muted">请先选择 VM</span></div>
    <div class="muted" style="margin-top:6px">直接读写 app 的 shared_prefs XML 文件（Android / 鸿蒙 / iOS；经 VM service 写回手机）。保存时先写文件，再经 app 内 SharedPreferences API 把改动项写回（同时更新插件内存缓存与原生存储，立即生效）；app 内找不到实例或类型不支持时只写文件，需重启 app 生效。只想让 app 重读文件时用「刷新 app 缓存」。</div>
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
    <!-- 上部操作区 sticky（main 是滚动容器）：字段树很长时查找 / Watch / 实例
         列表始终可见，不用滚回顶部。两个列表各自限高内滚，避免多命中时
         把屏幕占满（见 #in-sticky 的 CSS）。 -->
    <div id="in-sticky">
    <div style="display:flex;align-items:center;gap:10px">
      <button onclick="inLoadStores()" title="列出 app 端 XBUme.registerStore 注册的实例">注册表 Store</button>
      <input id="in-cls" placeholder="类名（如 CounterState / UserNotifier）" style="width:260px" onkeydown="if(event.key==='Enter')inFind()">
      <button class="primary" onclick="inFind()" title="按类名查找：先遍历 Element 树找 State，再堆扫描捞全部实例">查找实例</button>
      <span id="in-stat" class="muted">选中会话 app 内的运行时实例（仅 debug 可 用）</span>
    </div>
    <div class="inwatch">
      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
        <b style="font-size:12px">Watch 监听</b>
        <input id="in-watch-expr" placeholder="表达式（如 DateTime.now().second）" style="width:280px" onkeydown="if(event.key==='Enter')inWatchExpr()">
        <input id="in-watch-lib" placeholder="库 uri（可选，默认 binding.dart）" style="width:230px">
        <select id="in-watch-ms">
          <option value="200">200ms</option>
          <option value="500" selected>500ms</option>
          <option value="1000">1s</option>
          <option value="2000">2s</option>
        </select>
        <button onclick="inWatchExpr()">监听表达式</button>
      </div>
      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:4px">
        <input id="in-watch-cond" placeholder="条件表达式（true 时自动截图，可空）" style="width:300px">
        <label style="font-size:12px;display:flex;align-items:center;gap:3px"><input type="checkbox" id="in-watch-shot" checked> 条件成立自动截图</label>
        <span class="muted" style="font-size:12px">字段监听：在字段行点「监听」；条件与监听同上下文求值</span>
      </div>
      <div id="in-watch-list" class="inwatch-list"></div>
    </div>
    <div id="in-list" style="margin-top:8px"></div>
    </div>
    <div id="in-tree" style="margin-top:8px"></div>
    <div class="muted" style="margin-top:6px">三条途径定位实例：「注册表 Store」读 app 端 XBUme.registerStore(id, obj) 注册的对象（如 Provider 的 ChangeNotifier）；「查找实例」按类名先遍历 Element 树（树上存活的 State），再堆扫描（getClassList + getInstances，覆盖不在树上的单例）。字段树可直接编辑基础类型字段（int/double/bool/String）并写回 app，ChangeNotifier 类型写回后自动 notifyListeners。「Watch 监听」按间隔轮询字段/表达式，值变化写入时间轴；条件表达式成立时自动截图（落盘 scenarios/artifacts）。</div>
  </section>
  <section class="page" id="page-shot">
    <div style="display:flex;gap:14px;align-items:flex-start;flex-wrap:wrap">
      <div style="flex:1;min-width:320px">
        <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
          <button class="primary" onclick="shRefresh()">刷新截图</button>
          <select id="sh-auto" onchange="shAuto(this.value)">
            <option value="">自动刷新：关</option>
            <option value="1">每 1 秒</option>
            <option value="2">每 2 秒</option>
            <option value="5">每 5 秒</option>
          </select>
          <button onclick="shSave()">下载 PNG</button>
          <button onclick="shCopy()" title="把当前显示的画面复制到剪贴板">复制图片</button>
          <label style="font-size:12px" title="开启后单击截图=Tap、按住拖拽=Swipe；开始录制会自动开启"><input type="checkbox" id="sh-remote" onchange="shRemote(this.checked)"> 遥控</label>
          <span id="sh-meta" class="muted"></span>
        </div>
        <div class="muted" id="sh-tip" style="display:none;margin-top:8px"></div>
        <div class="shwrap" style="margin-top:8px">
          <img id="sh-img" style="display:none;cursor:default" draggable="false"
               onpointerdown="shDown(event)" onpointermove="shMove(event)" onpointerup="shUp(event)" onpointercancel="shCancel(event)"
               alt="app 截图">
          <div id="sh-ring" class="shring"></div>
          <div id="sh-line" class="shline"></div>
        </div>
        <div style="display:flex;gap:8px;margin-top:8px;flex-wrap:wrap">
          <input id="sh-input" placeholder="输入文本（回车发送到 app 当前焦点输入框）" style="flex:1;min-width:240px" onkeydown="shInputKey(event)">
          <button class="primary" onclick="shSend()">发送</button>
        </div>
        <div id="sh-op" class="muted" style="margin-top:4px;font-size:12px"></div>
        <div class="muted" style="margin-top:6px;font-size:12px">开启「遥控」后：单击截图=Tap，按住拖拽=Swipe，上方输入框回车=Input；开始录制会自动开启遥控。截图按物理像素坐标映射，自动刷新建议选低频档。</div>
      </div>
      <div class="shrec" style="flex:0 0 340px;max-width:100%">
        <div class="hd">
          <span id="sh-rec-dot" class="dot"></span><b>录制</b>
          <span id="sh-rec-stat" class="muted" style="flex:1">未开始</span>
          <button id="sh-rec-btn" class="primary" onclick="shRecToggle()">● 开始录制</button>
        </div>
        <div style="display:flex;gap:6px;margin-top:8px;flex-wrap:wrap">
          <input id="sh-scn-name" placeholder="场景名" style="flex:1;min-width:110px">
          <button onclick="shSaveScn()">保存场景</button>
        </div>
        <div style="display:flex;gap:6px;margin-top:6px;flex-wrap:wrap">
          <button class="primary" onclick="shPlayNow()">▶ 回放当前步骤</button>
          <button onclick="shStopPlay()">■ 停止</button>
        </div>
        <div style="display:flex;gap:6px;margin-top:6px">
          <select id="sh-scn-sel" style="flex:1"><option value="">— 已保存场景 —</option></select>
          <button onclick="shLoadScn()">载入</button>
        </div>
        <div style="display:flex;gap:6px;margin-top:6px;flex-wrap:wrap">
          <button onclick="shUndo()">撤销上一步</button>
          <button onclick="shClear()">清空步骤</button>
          <span id="sh-steps-n" class="muted"></span>
        </div>
        <div id="sh-steps" class="shsteps"><span class="muted">暂无步骤</span></div>
        <div id="sh-play" class="shstatus"></div>
        <div class="muted" style="margin-top:6px;font-size:11px">步骤保存在 ~/.xb_ume_ide/scenarios；input 文本按原文写入 JSON，含密码等敏感信息时请注意。</div>
      </div>
    </div>
  </section>
  <section class="page" id="page-perf">
    <div class="row">
      <b>实时性能</b>
      <select id="pf-interval" onchange="pfSetInterval(this.value)" title="采集间隔；采样窗口 = min(间隔, 2 秒)">
        <option value="1000">每 1 秒</option>
        <option value="2000" selected>每 2 秒</option>
        <option value="5000">每 5 秒</option>
      </select>
      <button class="primary" onclick="pfPoll(true)" title="立即采集一次">刷新</button>
      <button id="pf-live-btn" onclick="pfToggleLive()">暂停</button>
      <button onclick="pfClear()" title="清空曲线与峰值统计（不清 app 内部数据）">清空</button>
      <button onclick="pfGc()" title="_collectAllGarbage：触发 app 主 isolate 全量 GC，然后重新采集">触发 GC</button>
      <span id="pf-stat" class="muted">请先在页头右侧选择调试会话</span>
    </div>
    <div class="pf-grid" style="margin-bottom:12px">
      <div class="pf-card"><div class="k" id="pf-cpu-k">CPU（Dart 主 isolate）</div><div class="v" id="pf-cpu">—</div><div class="s" id="pf-cpu-sub">—</div></div>
      <div class="pf-card"><div class="k">Dart 堆内存</div><div class="v" id="pf-heap">—</div><div class="s" id="pf-heap-sub">—</div></div>
      <div class="pf-card"><div class="k" id="pf-rss-k">进程内存</div><div class="v" id="pf-rss">—</div><div class="s" id="pf-rss-sub">—</div></div>
      <div class="pf-card"><div class="k">本次会话峰值</div><div class="v" id="pf-peak">—</div><div class="s" id="pf-peak-sub">—</div></div>
    </div>
    <div class="pf-charts">
      <div class="pf-chart">
        <div class="hd"><b>CPU 占用</b><span>近 90 个采样点</span><span id="pf-cpu-last" style="margin-left:auto"></span></div>
        <canvas id="pf-cpu-cv"></canvas>
      </div>
      <div class="pf-chart">
        <div class="hd"><b>内存</b>
          <span class="pf-legend"><span><i style="background:#00e5ff"></i>Dart 堆</span><span><i style="background:#f0b429"></i>进程内存</span></span>
          <span id="pf-mem-last" style="margin-left:auto"></span>
        </div>
        <canvas id="pf-mem-cv"></canvas>
      </div>
    </div>
    <div class="pf-chart" style="margin-top:12px">
      <div class="hd"><b id="pf-proc-k">进程内存构成</b><span id="pf-proc-stat"></span></div>
      <div id="pf-proc"><span class="muted">暂无数据</span></div>
    </div>
    <div class="muted" style="margin-top:6px;font-size:12px">数据来源：CPU 优先用 app 端服务扩展 <code>ext.xbume.processStats</code>（<code>getrusage</code> / <code>/proc</code> / <code>GetProcessTimes</code> 读整进程 user+sys CPU 时间，含全部线程）；iOS/macOS 按 Xcode 调试导航器口径（单核占满 100%，多核可超 100%），Windows 按任务管理器口径（以全部核心容量合计为 100%），Android / OHOS 按 Android Studio / DevEco Profiler 口径（以全部核心容量合计为 100%）。旧版 SDK 未注册扩展时回退 VM service <code>getCpuSamples</code>（窗口内采样数 × 采样周期 / 窗口时长，Idle 不计入；只反映 Dart 主 isolate）。进程内存：Android / OHOS 取 <code>/proc/self/smaps</code> 的 PSS（与 Android Studio 的 Total、DevEco Memory 泳道的 PSS 同源；分类按 dumpsys App Summary / DevEco 内存类型拆分；GPU memtrack 显存在 app 内不可读，可能与官方差一个 GL/Graph 值），iOS/macOS 取 <code>phys_footprint</code>（Xcode 内存 gauge 口径），Windows 取 <code>GetProcessMemoryInfo</code> 的 WorkingSetSize（任务管理器「内存」同源）；都不可用时回退 <code>getProcessMemoryUsage</code>。堆来自 <code>getMemoryUsage</code>（Dart 堆与堆外内存）；仅 debug 模式可用。离开本页或点「暂停」停止采集，避免持续占用调试通道。</div>
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
    </div>
    <div class="muted" style="margin-top:4px;font-size:12px">步骤 JSON：[{"type":"tap","x":400,"y":280,"phys":true},{"type":"input","text":"hi"},{"type":"swipe","x1":400,"y1":400,"x2":400,"y2":150,"ms":400,"phys":true},{"type":"wait","ms":1000},{"type":"back"},{"type":"navigate","name":"xxx"},{"type":"assertVisible","widget":"页面类名"},{"type":"assertRoute","name":"路由名"},{"type":"assertInstance","class":"类名"},{"type":"assertText","contains":"xx"},{"type":"assertRequest","urlContains":"/api/xx","method":"GET"},{"type":"assertLog","contains":"xx","level":"E"},{"type":"eval","expr":"1+1","expect":"2"}]。tap/swipe 坐标：phys=true 为截图物理像素，否则逻辑像素；assertText/assertRequest/assertLog 反向断言用 notContains / not:true，时间窗用 withinLastMs。</div>
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
      <button id="ai-report-btn" style="display:none" onclick="window.open('/api/ai/report')">⬇ 导出报告</button>
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
        <label><input type="checkbox" id="ai-ctx-elements" checked> 元素候选</label>
        <span class="muted">关闭后 AI 消息不含对应上下文、对应断言步骤被忽略</span>
      </div>
    </div>
    <div style="margin-top:6px"><span id="ai-prog" class="muted"></span></div>
    <div id="ai-report" style="margin-top:6px;max-height:45vh;overflow:auto"></div>
  </section>
  <section class="page" id="page-compare">
    <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
      <span>场景</span>
      <select id="cmp-sel" style="min-width:180px"><option value="">— 选择场景 —</option></select>
      <button onclick="cmpLoad()">刷新</button>
      <span style="margin-left:6px">A</span><select id="cmp-a" style="min-width:190px"></select>
      <span>B</span><select id="cmp-b" style="min-width:190px"></select>
      <label style="font-size:12px"><input type="checkbox" id="cmp-shot" checked> 每步截图</label>
      <label style="font-size:12px"><input type="checkbox" id="cmp-cont" checked> 失败继续</label>
      <button class="primary" onclick="cmpRun()">▶ 并排运行</button>
      <button onclick="cmpStop()">■ 停止</button>
    </div>
    <div class="muted" style="margin-top:4px;font-size:12px">选一个已保存场景，在两个调试会话上<b>并行</b>执行同一组步骤：逐步对比状态/实际值/耗时，截图并排，网络请求按运行时间窗口对比（A/B 需为不同会话）。</div>
    <div style="margin-top:6px;display:flex;align-items:center;gap:12px;flex-wrap:wrap">
      <span id="cmp-prog" class="muted"></span>
      <label id="cmp-onlydiff-wrap" style="display:none;font-size:12px"><input type="checkbox" id="cmp-onlydiff" onchange="cmpRender()"> 只看差异</label>
    </div>
    <div id="cmp-summary" style="margin-top:6px"></div>
    <div id="cmp-body" style="margin-top:6px"></div>
    <div id="cmp-net-wrap" style="margin-top:12px;display:none">
      <b style="font-size:13px">网络请求对比</b>
      <span class="muted" style="font-size:12px">（两侧运行窗口内的请求）</span>
      <div id="cmp-net" style="margin-top:4px"></div>
    </div>
  </section>
</main>
<!-- 调试浮动工具条（VSCode 风格）：连着会话就出现，暂停时高亮；跨 Tab 常驻 -->
<div id="dbg-bar">
  <span class="why" id="dbg-bar-why">调试中</span>
  <button id="dbg-b-pause" onclick="dbgPause()" title="暂停（异步停在最近的 Dart 代码）">⏸ 暂停</button>
  <button id="dbg-b-resume" onclick="dbgResume()" title="继续（F5）">▶ 继续</button>
  <button id="dbg-b-over" onclick="dbgResume('over')" title="单步跳过（F10）：执行完当前行">↷ 跳过</button>
  <button id="dbg-b-into" onclick="dbgResume('into')" title="单步进入（F11）：进入被调用函数">↘ 进入</button>
  <button id="dbg-b-out" onclick="dbgResume('out')" title="单步跳出（⇧F11）：跑完当前函数">↖ 跳出</button>
  <span class="sep"></span>
  <button id="dbg-b-hot" onclick="dbgHot(false)" title="热重载（r）：改完代码不重启进程">⟳ 热重载</button>
  <button id="dbg-b-restart" onclick="dbgHot(true)" title="热重启（R）：重建 isolate，断点自动重下">⥀ 热重启</button>
  <span class="sep"></span>
  <button onclick="dbgStop()" title="停止 flutter run（只停本工具拉起的，按精确 PID）">■ 停止</button>
  <button onclick="document.getElementById('dbg-bar').classList.remove('on')" title="收起（从调试页刷新或重新操作可再现）">✕</button>
</div>
<div id="dbg-toast"></div>
<script>
var XBUME_TOKEN = (document.querySelector('meta[name="xbume-token"]') || {}).content || '';
// 同源 fetch 统一带令牌：Cookie 之外的双保险（SameSite=Strict 已挡跨站）。
// 令牌随进程启动重新生成，重启后旧标签页里的令牌（meta + Cookie）全部失效；
// 这里遇到 403 自动重载一次，重载会拿到新页面与新 Cookie（限频防循环）。
var authReloaded = false;
(function(){
  if (!window.fetch) return;
  var nativeFetch = window.fetch.bind(window);
  window.fetch = function(input, init){
    init = init || {};
    try {
      var h = new Headers(init.headers || {});
      if (XBUME_TOKEN) h.set('X-XBUME-Token', XBUME_TOKEN);
      init.headers = h;
    } catch (e) {}
    return nativeFetch(input, init).then(function(r){
      if (r.status !== 403 || authReloaded) return r;
      authReloaded = true;
      try {
        var last = +(sessionStorage.getItem('xbume_auth_reload') || 0);
        // 刚重载过还是 403：说明不是令牌过期，停下（避免死循环刷新）。
        if (Date.now() - last < 15000) return r;
        sessionStorage.setItem('xbume_auth_reload', String(Date.now()));
      } catch (e) { return r; }
      setTimeout(function(){ location.reload(); }, 80);
      return r;
    });
  };
})();
var ws = null, devices = [], selected = null, logs = [], paused = false, vmFilter = '';
// 已开启屏幕常亮的设备 id（后端下发；GUI 重启后清空，重新勾一次即可，命令幂等）
var keepAwakeSet = {};
var fpBySource = {}, vmMiss = 0; // 会话指纹映射与瞬断容忍计数
// 所选会话指纹持久化：localStorage 存 fp，刷新/重开浏览器后自动选回同一会话；
// 手动选「未选择会话」才清除（saveVmFp/removeVmFp）
function loadVmFp(){ try { return localStorage.getItem('xbume_vm_fp') || ''; } catch (e) { return ''; } }
function saveVmFp(fp){ vmFilterFp = fp; try { fp ? localStorage.setItem('xbume_vm_fp', fp) : localStorage.removeItem('xbume_vm_fp'); } catch (e) {} }
var vmFilterFp = loadVmFp();
if (vmFilterFp) clog('页面加载：从 localStorage 恢复指纹 ' + vmFilterFp);
// 会话选择链路排障日志：上报后端落盘 ~/.xb_ume_ide/logs/vm_sel.log（fire-and-forget）
function clog(msg){ try { fetch('/api/clientlog', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({tag:'vmsel', msg: msg}) }); } catch (e) {} }
document.addEventListener('visibilitychange', function(){ clog('页面' + (document.hidden ? '进入后台' : '恢复前台')); });
var lastDaemonRunning = null;
var vmApps = {}; // 会话来源 → 应用包名（/api/daemon 返回，回放日志无 app 时兑底展示）
var vmUriBySource = {}; // 会话来源 → VM service ws uri（沙盒 Tab 用）
var platformNames = { android: 'Android', ohos: '鸿蒙', 'ios-sim': 'iOS 模拟器', 'ios-real': 'iOS 真机', windows: 'Windows', macos: 'macOS' };
function connect() {
  ws = new WebSocket('ws://' + location.host + '/ws?token=' + encodeURIComponent(XBUME_TOKEN));
  ws.onopen = function(){ document.getElementById('wsdot').classList.add('on'); };
  ws.onclose = function(){ document.getElementById('wsdot').classList.remove('on'); setTimeout(connect, 1500); };
  ws.onmessage = function(e){
    var msg = JSON.parse(e.data);
    if (msg.type === 'snapshot') { devices = msg.devices; selected = msg.selected; applyKeepAwake(msg.keepAwake); logs = msg.items; excItems = msg.exceptions || []; excBadge(); renderHdrDev(); renderLogs(); refreshDaemon(); if (tlOnTab()) tlSchedule(); }
    else if (msg.type === 'devices') { devices = msg.devices; applyKeepAwake(msg.keepAwake); renderHdrDev(); }
    else if (msg.type === 'logs') { msg.items.forEach(function(l){ l._seq = ++logSeq; }); logs = logs.concat(msg.items); trimLogs(); if (!paused) logFlushNew(); if (tlOnTab()) tlSchedule(); }
    else if (msg.type === 'cleared') { logs = []; renderLogs(); tlSchedule(); }
    else if (msg.type === 'exception') { excOnItem(msg.item); }
    else if (msg.type === 'exceptionsCleared') { excItems = []; excRender(); tlSchedule(); }
    else if (msg.type === 'tl') { tlMerge(msg.items || []); }
    else if (msg.type === 'tlCleared') { tlOrder = []; tlByKey = {}; tlExpanded = {}; tlRender(); }
    else if (msg.type === 'watch') { watchEventAdd(msg.item); }
    else if (msg.type === 'watchState') { inWatchApply(msg.item); }
    else if (msg.type === 'watchList') { inWatches = msg.items || []; inWatchRender(); }
    else if (msg.type === 'watchCleared') { watchEvents = []; if (tlOnTab()) tlRender(); }
    else if (msg.type === 'debug' || msg.type === 'debugState') { dbgApply(msg.state || {}); }
    else if (msg.type === 'debugOutput') { dbgOutAppend(msg.lines || [], msg.seq); }
  };
}
connect();
function showTab(t){
  var prevTab = document.querySelector('.tab.active');
  if (prevTab && prevTab.dataset.tab === 'timeline' && t.dataset.tab !== 'timeline') tlHide();
  if (prevTab && prevTab.dataset.tab === 'perf' && t.dataset.tab !== 'perf') pfStop();
  document.querySelectorAll('.tab').forEach(function(x){ x.classList.remove('active'); });
  document.querySelectorAll('.page').forEach(function(x){ x.classList.remove('active'); });
  t.classList.add('active');
  document.getElementById('page-' + t.dataset.tab).classList.add('active');
  if (t.dataset.tab === 'daemon') { refreshDaemon(); refreshMcp(); loadIdeOrder(); }
  else if (t.dataset.tab === 'ai') aiShow();
  else if (t.dataset.tab === 'debug') dbgShow();
  else if (t.dataset.tab === 'timeline') tlShow();
  else if (t.dataset.tab === 'sandbox') sbRefresh();
  else if (t.dataset.tab === 'db') dbRefresh();
  else if (t.dataset.tab === 'routes') rtRefresh();
  else if (t.dataset.tab === 'network') nwRefresh();
  else if (t.dataset.tab === 'storage') stRefresh();
  else if (t.dataset.tab === 'status') cnScan();
  else if (t.dataset.tab === 'instances') inRefresh();
  else if (t.dataset.tab === 'shot') { shRefresh(); shScnRefresh(); shRecStat(); }
  else if (t.dataset.tab === 'perf') pfShow();
  else if (t.dataset.tab === 'auto') { auLoad(); aiPoll(); aiGoalsLoad(); } // aiPoll 仅拉取渲染，不启动任务；页面重载后恢复报告
  else if (t.dataset.tab === 'compare') cmpLoad();
  else if (t.dataset.tab === 'wtree') wtLoad();
  else if (t.dataset.tab === 'exc') { document.getElementById('exc-overlay').style.display = 'none'; excBadge(); excRefresh(); }
}
document.querySelectorAll('.tab').forEach(function(t){ t.onclick = function(){ showTab(t); }; });
// 深链：#ai 直接落在这个 Tab（文档、脚本、截图都用同一个入口）。
window.addEventListener('load', function(){
  var want = (location.hash || '').replace(/^#/, '');
  if (!want) return;
  var t = document.querySelector('.tab[data-tab="' + want + '"]');
  if (t) showTab(t);
});
function esc(s){ var d = document.createElement('div'); d.textContent = s == null ? '' : String(s); return d.innerHTML; }
// -- 异常 Tab -------------------------------------------------------------
var excItems = [];      // 异常记录（后端 schema：id/summary/desc/widget/stack/…）
var excById = {};       // id → 记录（栈帧行「跳转」回调按 id+idx 反查，免转义）
var excAiCache = {};    // id → {loading/error/text/meta}：AI 归因结果（重渲染保留）
var excAiBusy = {};     // id → true：分析请求进行中，防重复点击
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
  if (tlOnTab()) tlSchedule();
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
    if (tlOnTab()) tlSchedule();
  }).catch(function(e){ document.getElementById('exc-stat').textContent = '拉取失败：' + e; });
}
function excClear(){
  fetch('/api/exceptions/clear', { method: 'POST' })
    .then(function(){ excItems = []; excRender(); if (tlOnTab()) tlSchedule(); })
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
  var h = '<div class="exccard" id="exccard-' + esc(String(it.id)) + '">';
  h += '<div class="exchead">' + esc(it.time || '') +
    ' <b style="color:' + (it.channel === 'framework' ? '#e74c3c' : '#e67e22') + '">' +
    (it.channel === 'framework' ? '框架' : '未捕获') + '</b> ' + esc(it.source || '');
  if (it.app) h += ' · ' + esc(it.app);
  if (it.os) h += ' · ' + esc(it.os);
  if (it.count > 1) h += ' <span style="color:#e67e22">×' + it.count + '</span>';
  h += ' <a href="javascript:void(0)" onclick="excCopy(' + it.id + ',this)" title="复制本条异常全部内容">复制</a>';
  h += ' <a href="javascript:void(0)" onclick="excAi(' + it.id + ',this)" title="把异常栈、相关源码与最近路由/网络/日志发给 AI 分析">AI 分析</a>';
  h += '</div>';
  h += '<div style="margin-top:4px">' + esc(it.summary || '') + '</div>';
  if (it.desc) h += '<div class="muted" style="margin-top:4px;white-space:pre-wrap">' + esc(it.desc) + '</div>';
  if (it.widget) {
    h += '<div style="margin-top:4px">Widget：' + esc(it.widget);
    if (it.widgetFile) h += ' <a href="javascript:void(0)" onclick="excJump(' + it.id + ',' + (it.widgetLine || 1) + ',this)">跳转</a>';
    if (it.widgetFile) h += ' <a href="javascript:void(0)" onclick="excQuickBp(' + it.id + ',' + (it.widgetLine || 1) + ')" title="在「调试」页下断点（已连会话立即生效，未连则记住、下次自动恢复）">断点</a>';
    h += '</div>';
  }
  if (it.stack && it.stack.length) {
    h += '<div style="margin-top:6px;font-size:12px">';
    it.stack.forEach(function(f, idx){
      var raw = f.raw || ((f.method || '') + ' (' + (f.uri || '') + ':' + (f.line || 0) + ')');
      h += '<div class="excframe">' + esc(raw);
      if (f.file) h += ' <a href="javascript:void(0)" onclick="excFrameJump(' + it.id + ',' + idx + ',this)">跳转</a>';
      if (f.file) h += ' <a href="javascript:void(0)" onclick="excFrameQuickBp(' + it.id + ',' + idx + ')" title="在这一帧下断点">断点</a>';
      h += '</div>';
    });
    h += '</div>';
  }
  var ai = excAiCache[it.id];
  h += '<div class="excai" id="exc-ai-' + it.id + '"' + (ai ? '' : ' style="display:none"') + '>' +
    (ai ? excAiInner(it.id, ai) : '') + '</div>';
  h += '</div>';
  return h;
}
function excUri(it){ // 优先异常来源会话，退回当前选中会话
  var u = (it && it.wsUri) ? it.wsUri : '';
  if (u) return u;
  return vmFilter ? (vmUriBySource[vmFilter] || '') : '';
}
function excAiInner(id, a){
  if (a.loading) return '<span class="muted">AI 分析中…（附带栈帧源码与最近上下文）</span>';
  if (a.error) return '<span style="color:#ff9d9d">分析失败：' + esc(a.error) + '</span>';
  var h = '<div class="aihead">AI 归因</div><div class="aitext">' + esc(a.text || '') + '</div>';
  var m = a.meta || {};
  var bits = [];
  if (m.sources) bits.push(m.sources + ' 个源码片段');
  if (m.frames) bits.push(m.frames + ' 帧栈');
  if (m.routes) bits.push('路由栈');
  if (m.network) bits.push(m.network + ' 条网络');
  if (m.logs) bits.push(m.logs + ' 条日志');
  if (bits.length) h += '<div class="muted" style="margin-top:4px">依据：' + esc(bits.join(' · ')) + '</div>';
  h += ' <a href="javascript:void(0)" onclick="excAiCopy(' + id + ',this)">复制分析</a>';
  return h;
}
function excAi(id, el){
  var it = excById[id];
  if (!it) return;
  if (excAiBusy[id]) return;
  var box = document.getElementById('exc-ai-' + id);
  if (!box) return;
  excAiBusy[id] = true;
  excAiCache[id] = {id: id, loading: true};
  box.style.display = '';
  box.innerHTML = excAiInner(id, excAiCache[id]);
  fetch('/api/exc/analyze', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({id: id, uri: excUri(it)})
  }).then(function(r){ return r.json(); }).then(function(d){
    excAiBusy[id] = false;
    if (!d.ok) { excAiCache[id] = {id: id, error: d.error || '未知错误'}; }
    else { excAiCache[id] = {id: id, text: d.analysis || '', meta: d.meta || {}}; }
    var box2 = document.getElementById('exc-ai-' + id);
    if (box2) box2.innerHTML = excAiInner(id, excAiCache[id]);
  }).catch(function(e){
    excAiBusy[id] = false;
    excAiCache[id] = {id: id, error: '请求失败：' + e};
    var box2 = document.getElementById('exc-ai-' + id);
    if (box2) box2.innerHTML = excAiInner(id, excAiCache[id]);
  });
}
function excAiCopy(id, el){
  var a = excAiCache[id];
  if (!a || !a.text) return;
  var done = function(){ el.textContent = '已复制✓'; setTimeout(function(){ el.textContent = '复制分析'; }, 1500); };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(a.text).then(done, function(){ copyLogsFallback(a.text); done(); });
  } else { copyLogsFallback(a.text); done(); }
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
// 「一键下断点」：异常栈帧 / 相关 Widget / 网络发起位置的源码行旁。
// 已连同一会话 → 立刻下；未连 → 记进「已记住」清单，下次启动/接入自动生效；
// 位置不属于当前调试会话（端口不同）→ 只把位置填到调试页，不默默下错会话。
function excQuickBp(id, line){ // 相关 widget 的断点
  var it = excById[id];
  if (!it || !it.widgetFile) return;
  dbgQuickBp(it.widgetFile, line, it.wsUri);
}
function excFrameQuickBp(id, idx){ // 栈帧行的断点
  var it = excById[id];
  var f = it && it.stack && it.stack[idx];
  if (!f || !f.file) return;
  dbgQuickBp(f.file, f.line, it.wsUri);
}
function nwInitQuickBp(id, idx){ // 网络发起位置栈帧的断点
  var f = (nwInitFrames[id] || [])[idx];
  if (!f || !f.file) return;
  var u = vmFilter ? (vmUriBySource[vmFilter] || '') : '';
  dbgQuickBp(f.file, f.line, u);
}
function dbgSamePort(a, b){ // 只看端口：wsUri 的 path/token 各来源不一致，比全串会误拦
  if (!a || !b) return true;
  var pa = /:(\d+)/.exec(a), pb = /:(\d+)/.exec(b);
  if (!pa || !pb) return a === b;
  return pa[1] === pb[1];
}
function dbgPrefillBp(file, line){ // 把位置填到调试页并切过去
  var p = dbgEl('dbg-bp-path'), l = dbgEl('dbg-bp-line');
  if (p) p.value = file || '';
  if (l) l.value = line ? String(line) : '';
  var dir = dbgEl('dbg-dir');
  if (dir && !dir.value) {
    // 目录空着：从候选里找文件所属的最长前缀回填，免得断点记到错项目。
    var best = '';
    var dl = dbgEl('dbg-dir-list');
    if (dl) Array.prototype.forEach.call(dl.options, function(o){
      var c = (o.value || '').replace(/[\\/]+$/, '');
      if (c && file.indexOf(c + '/') === 0 && c.length > best.length) best = c;
    });
    if (best) { dir.value = best; dbgLoadSaved(); }
  }
  var tab = document.querySelector('[data-tab="debug"]');
  if (tab) showTab(tab);
}
function dbgQuickBp(file, line, fromWs){
  if (!file || !line) return null;
  var name = String(file).split(/[\\/]/).pop();
  var where = name + ':' + line;
  if (dbgSt && dbgSt.attached) {
    if (!dbgSamePort(fromWs, dbgSt.wsUri)) {
      dbgPrefillBp(file, line);
      dbgToast('该位置来自另一条调试会话：已在「调试」页填好位置，接入对应会话后再点「加断点」');
      return null;
    }
    return dbgOp('addBreakpoint', {path: file, line: line}).then(function(d){
      if (d && d.ok) { dbgLoadSaved(); dbgToast('已下断点 ' + where); }
      return d;
    });
  }
  var dir = dbgDirValue();
  if (!dir) {
    dbgPrefillBp(file, line);
    dbgToast('未连接调试会话：已把位置填到「调试」页，先选项目目录再点「加断点」');
    return null;
  }
  return dbgOp('rememberBreakpoint', {dir: dir, path: file, line: line}).then(function(d){
    if (d && d.ok) {
      dbgSavedList = d.saved || [];
      dbgRenderSaved();
      dbgToast('已记住断点 ' + where + '：下次启动 / 接入自动生效');
    }
    return d;
  });
}

// 属性值转义：esc 只转 &<>，写进 data-file 还得挡引号。
function escAttr(s){ return esc(s).replace(/"/g, '&quot;').replace(/'/g, '&#39;'); }

// 用「守护进程 Tab 里排好的 IDE 顺序」打开 文件:行。
// 与路由栈 Tab 的「跳转」同一条通道：/api/openide → _guiLaunchIde →
// _guiIdeOrder（读 config.json 的 ideOrder）。找不到可用 IDE 时后端已把
// path:line 复制到剪贴板，把它的原因原样报出来。
function dbgIdeJump(anchor, file, line){
  if (!anchor) return;
  if (!file) { dbgToast('这个位置还没解析到文件，稍后再试'); return; }
  var old = anchor.getAttribute('data-label') || anchor.textContent || '跳转';
  anchor.setAttribute('data-label', old);
  anchor.textContent = '打开中…';
  fetch('/api/openide?file=' + encodeURIComponent(file) + '&line=' + (line || 1))
    .then(function(r){ return r.json(); })
    .then(function(d){
      var ok = !!(d && d.ok);
      anchor.textContent = ok ? '已打开 ✓' : '失败';
      anchor.title = (d && d.message) ? String(d.message) : (file + (line ? ':' + line : ''));
      if (!ok) dbgToast('打开失败：' + ((d && d.message) || '未知错误'));
      setTimeout(function(){ anchor.textContent = old; }, 2500);
    })
    .catch(function(e){
      anchor.textContent = old;
      dbgToast('请求失败：' + e);
    });
}

// 行内链接统一入口：参数走 data-file / data-line，不把路径拼进内联 onclick。
function dbgIdeJumpEl(el){
  if (!el) return;
  dbgIdeJump(el, el.getAttribute('data-file') || '',
    parseInt(el.getAttribute('data-line'), 10) || 0);
}
// -- 截图 Tab：实时截图 + 遥控（Tap/Swipe/Input）+ 录制/回放 ------------
var shTimer = null;      // 自动刷新定时器
var shCopyTimer = null;  // 复制结果提示的还原定时器
var shRefSoon = null;    // 操作后的去抖刷新
var shDrag = null;       // 当前拖拽（pointerId/起点/时间/物理起点）
var shOpQ = Promise.resolve(); // 串行化遥控请求，避免 pointer 事件交叉
var shOpPending = 0;
var shRec = {on: false, steps: [], lastAt: 0, startedAt: 0, timer: null};
var shRun = {on: false, timer: null, seen: false, t0: 0, name: '', total: 0};
var shRingTimer = null;
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
  var meta = document.getElementById('sh-meta');
  if (!uri) {
    img.style.display = 'none'; tip.style.display = '';
    tip.textContent = '请先在页头选择 VM 会话（仅 debug 模式可用）';
    if (meta) meta.textContent = '';
    return;
  }
  if (!img.getAttribute('src')) img.style.display = 'none';
  img.onerror = function(){
    tip.style.display = '';
    if (img.naturalWidth) {
      tip.textContent = '刷新截图失败，保留上一次画面（app 可能已断开）';
    } else {
      img.style.display = 'none';
      tip.textContent = '截图失败（app 需 debug 模式且在前台运行；会话可能已断开）';
    }
  };
  img.onload = function(){
    img.style.display = ''; tip.style.display = 'none';
    if (meta) meta.textContent = img.naturalWidth + '×' + img.naturalHeight + ' 物理像素 · 点击/拖拽映射';
  };
  img.src = '/api/screenshot?uri=' + encodeURIComponent(uri) + '&t=' + Date.now();
}
function shAuto(v){
  if (shTimer) { clearInterval(shTimer); shTimer = null; }
  if (v) shTimer = setInterval(function(){
    var t = document.querySelector('.tab.active');
    if (t && t.dataset.tab === 'shot' && !shDrag) shRefresh();
  }, (+v) * 1000);
}
function shSave(){
  var uri = shUri(); if (!uri) return;
  var a = document.createElement('a');
  a.href = '/api/screenshot?uri=' + encodeURIComponent(uri) + '&t=' + Date.now();
  a.download = 'xbume-shot-' + new Date().toISOString().replace(/[:.]/g, '-') + '.png';
  a.click();
}
function shCopyMsg(msg, ok){
  var meta = document.getElementById('sh-meta');
  if (!meta) { shSetOp(msg, ok ? 'ok' : 'err'); return; }
  var img = document.getElementById('sh-img');
  var base = (img && img.naturalWidth)
    ? img.naturalWidth + '×' + img.naturalHeight + ' 物理像素 · 点击/拖拽映射' : '';
  meta.textContent = msg;
  meta.style.color = ok ? '#4caf50' : '#ef5350';
  if (shCopyTimer) clearTimeout(shCopyTimer);
  shCopyTimer = setTimeout(function(){
    meta.textContent = base;
    meta.style.color = '';
  }, 2200);
}
function shCopy(){
  var img = document.getElementById('sh-img');
  if (!img || !img.naturalWidth || !img.naturalHeight) {
    shCopyMsg('暂无截图可复制，请先刷新截图', false);
    return;
  }
  if (!navigator.clipboard || !navigator.clipboard.write || !window.ClipboardItem) {
    shCopyMsg('当前浏览器不支持复制图片，请使用「下载 PNG」', false);
    return;
  }
  // 从当前显示的画面取像素，避免重新请求 /api/screenshot 又截一帧新的。
  var canvas = document.createElement('canvas');
  canvas.width = img.naturalWidth;
  canvas.height = img.naturalHeight;
  var ctx = canvas.getContext('2d');
  if (!ctx) { shCopyMsg('复制失败：无法读取截图', false); return; }
  var dataUrl;
  try {
    ctx.drawImage(img, 0, 0);
    dataUrl = canvas.toDataURL('image/png');
  } catch (e) {
    shCopyMsg('复制失败：' + (e && e.message ? e.message : e), false);
    return;
  }
  var blob;
  try {
    var bin = atob(dataUrl.substring(dataUrl.indexOf(',') + 1));
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    blob = new Blob([bytes], {type: 'image/png'});
  } catch (e) {
    shCopyMsg('复制失败：' + (e && e.message ? e.message : e), false);
    return;
  }
  try {
    var item = new ClipboardItem({'image/png': blob});
    navigator.clipboard.write([item]).then(function(){
      shCopyMsg('已复制到剪贴板', true);
    }, function(e){
      shCopyMsg('复制失败：' + (e && e.message ? e.message : e), false);
    });
  } catch (e) {
    shCopyMsg('复制失败：' + (e && e.message ? e.message : e), false);
  }
}
function shSetOp(s, cls){
  var el = document.getElementById('sh-op'); if (!el) return;
  el.textContent = s || '';
  el.style.color = cls === 'err' ? '#ef5350' : (cls === 'ok' ? '#4caf50' : '');
}
function shRefreshSoon(){
  if (shRefSoon) clearTimeout(shRefSoon);
  shRefSoon = setTimeout(function(){
    shRefSoon = null;
    if (!shDrag) shRefresh();
  }, 350);
}
function shPhys(ev){
  var img = document.getElementById('sh-img');
  var r = img.getBoundingClientRect();
  if (!img.naturalWidth || !r.width) return {x: 0, y: 0};
  return {
    x: Math.round((ev.clientX - r.left) * img.naturalWidth / r.width),
    y: Math.round((ev.clientY - r.top) * img.naturalHeight / r.height)
  };
}
function shLocal(ev){
  var img = document.getElementById('sh-img');
  var r = img.getBoundingClientRect();
  return {x: ev.clientX - r.left, y: ev.clientY - r.top};
}
function shRing(x, y, hold){
  var el = document.getElementById('sh-ring'); if (!el) return;
  el.style.display = '';
  el.style.left = x + 'px';
  el.style.top = y + 'px';
  if (shRingTimer) clearTimeout(shRingTimer);
  shRingTimer = setTimeout(function(){ el.style.display = 'none'; }, hold || 700);
}
function shRemote(on){
  var img = document.getElementById('sh-img');
  if (img) img.style.cursor = on ? 'crosshair' : 'default';
  if (!on) {
    shCancel();
    if (shRec.on) shRecStop('遥控已关闭，录制停止');
    shSetOp('遥控已关闭（截图仅查看）');
  } else {
    shSetOp('遥控已开启：单击=Tap，拖拽=Swipe，输入框回车=Input');
  }
}
function shDown(ev){
  if (!document.getElementById('sh-remote').checked) return;
  if (shRun.on) { shSetOp('回放中，暂不接受手动操作', 'err'); return; }
  if (!shUri()) { shSetOp('请先在页头选择 VM 会话', 'err'); return; }
  if (ev.pointerType === 'mouse' && ev.button !== 0) return;
  var img = document.getElementById('sh-img');
  if (!img.naturalWidth) return;
  ev.preventDefault();
  try { ev.target.setPointerCapture(ev.pointerId); } catch (e) {}
  var p = shLocal(ev);
  shDrag = {id: ev.pointerId, x0: p.x, y0: p.y, t0: Date.now(), p0: shPhys(ev)};
  var line = document.getElementById('sh-line'); line.style.display = 'none';
  shRing(p.x, p.y, 3000);
  shSetOp('按下（' + shDrag.p0.x + ', ' + shDrag.p0.y + '）');
}
function shMove(ev){
  if (!shDrag || ev.pointerId !== shDrag.id) return;
  ev.preventDefault();
  var p = shLocal(ev);
  var dx = p.x - shDrag.x0, dy = p.y - shDrag.y0;
  var len = Math.sqrt(dx * dx + dy * dy);
  shRing(p.x, p.y, 3000);
  var line = document.getElementById('sh-line');
  line.style.display = len > 6 ? '' : 'none';
  line.style.left = shDrag.x0 + 'px';
  line.style.top = shDrag.y0 + 'px';
  line.style.width = len + 'px';
  line.style.transform = 'rotate(' + Math.atan2(dy, dx) + 'rad)';
}
function shUp(ev){
  if (!shDrag || ev.pointerId !== shDrag.id) return;
  ev.preventDefault();
  try { ev.target.releasePointerCapture(ev.pointerId); } catch (e) {}
  var d = shDrag; shDrag = null;
  document.getElementById('sh-line').style.display = 'none';
  shRing(d.x0, d.y0, 450);
  var p1 = shPhys(ev);
  var dx = p1.x - d.p0.x, dy = p1.y - d.p0.y;
  var dist = Math.sqrt(dx * dx + dy * dy);
  if (dist < 8) {
    shQueueOp({type: 'tap', x: p1.x, y: p1.y, phys: true},
        'Tap (' + p1.x + ', ' + p1.y + ')');
  } else {
    var ms = Math.max(120, Math.min(1500, Date.now() - d.t0));
    shQueueOp({type: 'swipe', x1: d.p0.x, y1: d.p0.y, x2: p1.x, y2: p1.y, ms: ms, phys: true},
        'Swipe (' + d.p0.x + ',' + d.p0.y + ')→(' + p1.x + ',' + p1.y + ')');
  }
}
function shCancel(){
  shDrag = null;
  var line = document.getElementById('sh-line'); if (line) line.style.display = 'none';
  var ring = document.getElementById('sh-ring'); if (ring) ring.style.display = 'none';
}
function shQueueOp(step, label, done){
  if (shRun.on) { shSetOp('回放中，已忽略本次操作', 'err'); return; }
  var uri = shUri();
  if (!uri) { shSetOp('请先在页头选择 VM 会话', 'err'); return; }
  shOpPending++;
  shSetOp(label + ' 执行中…');
  shOpQ = shOpQ.then(function(){
    return fetch('/api/remote/op', {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({uri: uri, step: step})
    }).then(function(r){
      return r.json().catch(function(){ return {ok: false, error: 'HTTP ' + r.status}; });
    }).then(function(d){
      if (!d.ok) {
        shSetOp('失败：' + (d.error || d.actual || '未知错误'), 'err');
        return;
      }
      shSetOp(label + ' ✓', 'ok');
      if (shRec.on) shRecAdd(step);
      if (done) done();
      shRefreshSoon();
    }).catch(function(e){
      shSetOp('请求失败：' + e, 'err');
    });
  }).then(function(){
    shOpPending--;
    if (shOpPending <= 0 && shRec.on) shRecStat();
  }, function(e){
    shOpPending--;
    shSetOp('遥控请求失败：' + e, 'err');
  });
}
function shInputKey(ev){
  if (ev.key === 'Enter' && !ev.isComposing) { ev.preventDefault(); shSend(); }
}
function shSend(){
  if (!document.getElementById('sh-remote').checked) { shSetOp('请先勾选「遥控」', 'err'); return; }
  var el = document.getElementById('sh-input');
  var text = el.value;
  if (text.length > 5000) { shSetOp('输入文本过长（最多 5000 字）', 'err'); return; }
  var sent = text;
  shQueueOp({type: 'input', text: text}, 'Input', function(){
    if (el.value === sent) el.value = '';
    el.focus();
  });
}
function shRecStat(){
  var el = document.getElementById('sh-rec-stat');
  var n = document.getElementById('sh-steps-n');
  if (el) {
    if (shRec.on) {
      var sec = Math.floor((Date.now() - shRec.startedAt) / 1000);
      el.textContent = '录制中 ' + sec + 's · ' + shRec.steps.length + ' 步';
    } else if (shRec.steps.length) {
      el.textContent = '已停止 · ' + shRec.steps.length + ' 步';
    } else {
      el.textContent = '未开始';
    }
  }
  if (n) n.textContent = shRec.steps.length ? shRec.steps.length + ' 步' : '';
}
function shRecToggle(){
  if (shRec.on) { shRecStop(''); return; }
  if (!shUri()) { alert('请先在页头选择 VM 会话'); return; }
  if (shRec.steps.length && !confirm('开始录制会清空当前 ' + shRec.steps.length + ' 个步骤，继续？')) return;
  shRec.on = true;
  shRec.steps = [];
  shRec.lastAt = Date.now();
  shRec.startedAt = Date.now();
  document.getElementById('sh-remote').checked = true;
  shRemote(true);
  document.getElementById('sh-rec-dot').classList.add('on');
  document.getElementById('sh-rec-btn').textContent = '■ 停止录制';
  shRenderSteps(); shRecStat();
  shSetOp('录制已开始：操作截图或输入文本');
  if (shRec.timer) clearInterval(shRec.timer);
  shRec.timer = setInterval(shRecStat, 1000);
}
function shRecStop(msg){
  if (!shRec.on) { if (msg) shSetOp(msg); return; }
  shRec.on = false;
  if (shRec.timer) { clearInterval(shRec.timer); shRec.timer = null; }
  document.getElementById('sh-rec-dot').classList.remove('on');
  document.getElementById('sh-rec-btn').textContent = '● 开始录制';
  shRecStat();
  shSetOp(msg || ('录制已停止 · ' + shRec.steps.length + ' 步'));
}
function shRecAdd(step){
  var now = Date.now();
  // 人工停顿超过 0.9s 时补一步 wait（最长 4s），让回放等待页面/请求完成。
  // input 前面的间隔是打字时间，不算 app 等待，不插 wait。
  if (shRec.lastAt && step.type !== 'input') {
    var gap = now - shRec.lastAt;
    if (gap > 900) shRec.steps.push({type: 'wait', ms: Math.min(gap, 4000), waitAfter: 0});
  }
  shRec.steps.push(JSON.parse(JSON.stringify(step)));
  shRec.lastAt = now;
  shRenderSteps(); shRecStat();
}
function shStepDesc(s){
  var t = s.type || '?';
  if (t === 'tap') return '(' + s.x + ', ' + s.y + ') 物理像素';
  if (t === 'swipe') return '(' + s.x1 + ',' + s.y1 + ')→(' + s.x2 + ',' + s.y2 + ') · ' + (s.ms || 300) + 'ms';
  if (t === 'input') {
    var txt = String(s.text == null ? '' : s.text);
    return '「' + (txt.length > 80 ? txt.slice(0, 80) + '…' : txt) + '」';
  }
  if (t === 'wait') return (s.ms || 500) + 'ms';
  try { return JSON.stringify(s).slice(0, 120); } catch (e) { return t; }
}
function shRenderSteps(){
  var el = document.getElementById('sh-steps');
  var n = document.getElementById('sh-steps-n');
  if (!el) return;
  if (!shRec.steps.length) { el.innerHTML = '<span class="muted">暂无步骤</span>'; }
  else {
    var html = '';
    shRec.steps.forEach(function(s, i){
      html += '<div class="shstep">'
        + '<span class="idx">' + (i + 1) + '</span>'
        + '<span class="ty">' + esc(s.type || '?') + '</span>'
        + '<span class="ds">' + esc(shStepDesc(s)) + '</span>'
        + '<span class="del" onclick="shDelStep(' + i + ')" title="删除这一步">×</span>'
        + '</div>';
    });
    el.innerHTML = html;
    el.scrollTop = el.scrollHeight;
  }
  if (n) n.textContent = shRec.steps.length ? shRec.steps.length + ' 步' : '';
  shRecStat();
}
function shDelStep(i){
  if (i < 0 || i >= shRec.steps.length) return;
  shRec.steps.splice(i, 1);
  shRec.lastAt = Date.now();
  shRenderSteps();
}
function shUndo(){
  if (!shRec.steps.length) return;
  shRec.steps.pop();
  shRec.lastAt = Date.now();
  shRenderSteps();
}
function shClear(){
  if (shRec.steps.length && !confirm('清空当前 ' + shRec.steps.length + ' 个步骤？')) return;
  shRec.steps = []; shRec.lastAt = Date.now();
  shRenderSteps(); shSetOp('步骤已清空');
}
function shScnRefresh(pick){
  fetch('/api/auto/list').then(function(r){ return r.json(); }).then(function(j){
    var sel = document.getElementById('sh-scn-sel');
    var cur = pick || sel.value;
    var html = '<option value="">— 已保存场景 —</option>';
    (j.items || []).forEach(function(it){
      html += '<option value="' + esc(it.name) + '">' + esc(it.name) + '（' + it.steps + ' 步）</option>';
    });
    sel.innerHTML = html;
    if (cur) sel.value = cur;
  });
}
function shSaveScn(){
  var name = document.getElementById('sh-scn-name').value.trim();
  if (!shRec.steps.length) { alert('没有可保存的步骤'); return; }
  if (!name) { alert('请填写场景名'); return; }
  if (name.length > 64 || !/^[\w\u4e00-\u9fff-]+$/.test(name)) {
    alert('场景名只能包含中文、字母、数字、下划线、横线（不能含空格、点号等），长度 1-64');
    return;
  }
  if (shRec.on) shRecStop('保存前已停止录制');
  fetch('/api/auto/save', {method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({name: name, steps: shRec.steps})})
    .then(function(r){ return r.json().catch(function(){ return {ok: false, error: '保存失败（HTTP ' + r.status + '）'}; }); })
    .then(function(j){
      if (!j.ok) { shSetOp('保存失败：' + (j.error || '未知错误'), 'err'); return; }
      shSetOp('已保存场景 ' + name + '（' + shRec.steps.length + ' 步）', 'ok');
      shScnRefresh(name);
      if (typeof auLoad === 'function') auLoad();
    })
    .catch(function(e){ shSetOp('保存请求失败：' + e, 'err'); });
}
function shLoadScn(){
  var name = document.getElementById('sh-scn-sel').value;
  if (!name) { alert('请选择已保存场景'); return; }
  fetch('/api/auto/get?name=' + encodeURIComponent(name))
    .then(function(r){ return r.json(); })
    .then(function(j){
      if (!j.ok) { shSetOp('载入失败：' + (j.error || '未知错误'), 'err'); return; }
      if (shRec.on) shRecStop('载入前已停止录制');
      shRec.steps = Array.isArray(j.steps) ? j.steps : [];
      shRec.lastAt = 0;
      document.getElementById('sh-scn-name').value = j.name || name;
      shRenderSteps();
      shSetOp('已载入场景 ' + (j.name || name) + '（' + shRec.steps.length + ' 步）', 'ok');
    })
    .catch(function(e){ shSetOp('载入请求失败：' + e, 'err'); });
}
function shPlayStatus(html){ document.getElementById('sh-play').innerHTML = html || ''; }
function shPlayRows(results){
  var out = '';
  (results || []).forEach(function(r){
    var c = r.status === 'pass' ? '#4caf50' : (r.status === 'fail' ? '#ef5350' : '#8aa0b4');
    out += '<div><span style="color:' + c + '">' + esc(r.status) + '</span> #' + (r.index + 1)
      + ' ' + esc(r.type)
      + (r.error ? ' · <span class="err">' + esc(r.error) + '</span>' : '')
      + (r.shot ? ' · <a href="/api/auto/artifact?f=' + encodeURIComponent(r.shot) + '" target="_blank">截图</a>' : '')
      + '</div>';
  });
  return out;
}
function shGoAuto(){
  auTotal = shRun.total || 0;
  var t = document.querySelector('.tab[data-tab="auto"]');
  if (t) t.click();
  setTimeout(function(){ if (typeof auPoll === 'function') auPoll(); }, 250);
}
function shPlayNow(){
  var uri = shUri();
  if (!uri) { alert('请先在页头选择 VM 会话'); return; }
  if (!shRec.steps.length) { alert('步骤为空：先录制或载入场景'); return; }
  if (shRun.on) { alert('已有回放在执行'); return; }
  if (shRec.on) shRecStop('回放前已停止录制');
  var name = document.getElementById('sh-scn-name').value.trim() || '录制回放';
  var steps = shRec.steps;
  shRun = {on: true, timer: null, seen: false, t0: Date.now(), name: name, total: steps.length};
  shPlayStatus('回放请求中…');
  fetch('/api/auto/run?uri=' + encodeURIComponent(uri) + '&continue=0&name=' + encodeURIComponent(name),
    {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(steps)})
    .then(function(r){ return r.json().then(function(j){ j._code = r.status; return j; }); })
    .then(function(j){
      if (!j.ok) {
        shRun.on = false;
        shPlayStatus('<span class="err">启动失败：' + esc(j.error || ('HTTP ' + j._code)) + '</span>');
        return;
      }
      shRun.total = j.total || steps.length;
      if (shRun.timer) clearInterval(shRun.timer);
      shRun.timer = setInterval(shPlayPoll, 400);
      shPlayPoll();
    })
    .catch(function(e){
      shRun.on = false;
      shPlayStatus('<span class="err">回放请求失败：' + esc(e) + '</span>');
    });
}
function shStopPlay(){
  if (!shRun.on) return;
  fetch('/api/auto/stop', {method: 'POST'});
  shPlayStatus('正在停止回放…');
}
function shPlayPoll(){
  fetch('/api/auto/status').then(function(r){ return r.json(); }).then(function(j){
    if (!shRun.on) return;
    if (j.running) shRun.seen = true;
    var st = Date.parse(j.startedAt || '');
    // 防串到自动化 Tab 的旧报告：旧 run 的 startedAt 明显早于本次请求。
    if (!j.running && st && st < shRun.t0 - 1500) return;
    if (!j.running && !shRun.seen && Date.now() - shRun.t0 < 1200) return;
    var results = j.results || [];
    var fails = results.filter(function(r){ return r.status === 'fail'; }).length;
    var done = !j.running;
    var head;
    if (done) {
      head = fails
        ? '<span class="err">回放失败：' + fails + ' 步失败</span> · ' + results.length + ' 步'
        : '<span class="ok">回放通过</span> · ' + results.length + ' 步';
      head += ' · <a href="javascript:void(0)" onclick="shGoAuto()">在自动化 Tab 查看完整报告</a>';
      shRun.on = false;
      if (shRun.timer) { clearInterval(shRun.timer); shRun.timer = null; }
      shRefresh();
    } else {
      head = '回放中：' + esc(j.name || shRun.name) + ' · 步骤 ' + Math.min(j.cur + 1, shRun.total) + '/' + shRun.total;
    }
    shPlayStatus(head + '<div style="margin-top:4px">' + shPlayRows(results) + '</div>');
  }).catch(function(e){
    if (!shRun.on) return;
    shRun.on = false;
    if (shRun.timer) { clearInterval(shRun.timer); shRun.timer = null; }
    shPlayStatus('<span class="err">读取回放状态失败：' + esc(e) + '</span>');
  });
}
// ── P10 自动化路径：场景列表/编辑/运行/报告 ──
var auTimer = null;  // 运行状态轮询定时器
var auTotal = 0;     // 本次运行总步数（POST /api/auto/run 响应）
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
    document.getElementById('ai-ctx-elements').checked = c.elements !== false;
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
        log: document.getElementById('ai-ctx-log').checked,
        elements: document.getElementById('ai-ctx-elements').checked } }) })
    .then(function(r){ return r.json(); })
    .then(function(j){ alert(j.ok ? 'AI 配置已保存' : (j.error || '保存失败')); });
}
function aiStart(){
  var uri = shUri(); if (!uri) { alert('请先在页头选择 VM 会话'); return; }
  var goal = document.getElementById('ai-goal').value.trim();
  if (!goal) { alert('请先描述目标'); return; }
  document.getElementById('ai-report').innerHTML = '';
  document.getElementById('ai-save-btn').style.display = 'none';
  document.getElementById('ai-report-btn').style.display = 'none';
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
      : (j.summarizing
          ? ('执行结束：' + rounds.length + ' 轮 · 正在生成 AI 总结…')
          : (rounds.length ? ('结束：' + rounds.length + ' 轮' + (j.done ? ' · AI 判定目标完成' : (lastErr ? ' · ' + lastErr : ''))) : ''));
    // 总结生成期间继续轮询（summarizing=true），完成后才收尾显示保存/导出按钮。
    if (!j.running && !j.summarizing && aiTimer) {
      clearInterval(aiTimer); aiTimer = null;
      if (rounds.length) {
        document.getElementById('ai-save-btn').style.display = '';
        document.getElementById('ai-report-btn').style.display = '';
      }
    }
    aiRenderReport(j);
    // 页面刷新/切回自动化页时若执行或总结仍在进行，恢复轮询。
    if ((j.running || j.summarizing) && !aiTimer) aiTimer = setInterval(aiPoll, 800);
  });
}

// AI 总结卡片：总体结论/指标/需求覆盖/正文/问题与建议；无总结且无错误时不占位。
function aiSummaryHtml(j){
  if (j.summarizing) {
    return '<div style="border:1px solid var(--line);margin-bottom:6px;padding:6px">'
      + '<b style="font-size:12px">AI 总结</b>'
      + '<div style="font-size:12px;color:#8aa0b4;margin-top:4px">正在生成 AI 总结（逐条核对指令要求）…</div></div>';
  }
  var s = j.summary;
  if (!s) {
    return j.summaryError
      ? '<div style="border:1px solid var(--line);margin-bottom:6px;padding:6px"><b style="font-size:12px">AI 总结</b>'
        + '<div style="font-size:12px;color:#e6b800;margin-top:4px">未生成：' + esc(j.summaryError) + '</div></div>'
      : '';
  }
  var bd2 = 'padding:3px 6px;border-bottom:1px solid var(--line);vertical-align:top';
  var h = '<div style="border:1px solid var(--line);margin-bottom:6px;padding:6px">'
    + '<b style="font-size:12px">AI 总结</b>';
  if (s.verdict) h += '<div style="font-size:12px;font-weight:600;margin:4px 0">' + esc(s.verdict) + '</div>';
  if ((s.metrics || []).length) {
    h += '<table style="border-collapse:collapse;width:100%;font-size:12px;margin:4px 0">'
      + '<tr><th style="' + bd2 + ';text-align:left">指标</th><th style="' + bd2 + ';text-align:left">值</th>'
      + '<th style="' + bd2 + ';text-align:left">计数依据</th></tr>';
    s.metrics.forEach(function(m){
      h += '<tr><td style="' + bd2 + '">' + esc(m.name || '') + '</td>'
        + '<td style="' + bd2 + '"><b>' + esc(m.value || '') + '</b></td>'
        + '<td style="' + bd2 + '">' + esc(m.basis || '') + '</td></tr>';
    });
    h += '</table>';
  }
  if ((s.requirements || []).length) {
    var lbl = { met: '✅ 满足', partial: '⚠️ 部分满足', unmet: '❌ 未满足', unknown: '❔ 无法判断' };
    var col = { met: '#4caf50', partial: '#e6b800', unmet: '#ef5350', unknown: '#8aa0b4' };
    h += '<div style="font-size:12px;margin-top:6px"><b>需求覆盖</b></div>'
      + '<table style="border-collapse:collapse;width:100%;font-size:12px;margin:4px 0">'
      + '<tr><th style="' + bd2 + ';text-align:left">你的要求</th><th style="' + bd2 + ';text-align:left">判定</th>'
      + '<th style="' + bd2 + ';text-align:left">依据</th></tr>';
    s.requirements.forEach(function(q){
      h += '<tr><td style="' + bd2 + '">' + esc(q.requirement || '') + '</td>'
        + '<td style="' + bd2 + ';color:' + (col[q.status] || '#8aa0b4') + '">' + esc(lbl[q.status] || q.status || '—') + '</td>'
        + '<td style="' + bd2 + '">' + esc(q.evidence || '') + '</td></tr>';
    });
    h += '</table>';
  }
  if (s.summary) h += '<div style="font-size:12px;white-space:pre-wrap;margin:6px 0">' + esc(s.summary) + '</div>';
  if ((s.issues || []).length) {
    h += '<div style="font-size:12px;margin-top:6px"><b>问题与建议</b></div><ul style="margin:4px 0;padding-left:18px;font-size:12px">';
    s.issues.forEach(function(x){ h += '<li>' + esc(x) + '</li>'; });
    h += '</ul>';
  }
  if (s.coverageWarning) h += '<div style="font-size:12px;color:#e6b800">' + esc(s.coverageWarning) + '</div>';
  var info = [];
  if (j.summaryModel) info.push('模型 ' + j.summaryModel);
  if (j.summaryMs) info.push('耗时 ' + (j.summaryMs / 1000).toFixed(1) + 's');
  if (s.confidence) info.push('把握度 ' + ({ high: '高', medium: '中', low: '低' }[s.confidence] || s.confidence));
  if (info.length) h += '<div style="font-size:11px;color:#8aa0b4;margin-top:4px">生成信息：' + esc(info.join(' · ')) + '</div>';
  return h + '</div>';
}
function aiRenderReport(j){
  var rounds = (j && j.rounds) || [];
  var el = document.getElementById('ai-report');
  var bd = 'padding:3px 6px;border-bottom:1px solid var(--line)';
  var html = aiSummaryHtml(j || {});
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

// -- 多设备并排对比 --------------------------------------------------------
var cmpState = null, cmpTimer = null, cmpNet = { a: [], b: [] };
function cmpActive(){ var t = document.querySelector('.tab.active'); return t && t.dataset.tab === 'compare'; }
function cmpSelText(id){
  var el = document.getElementById(id);
  return el && el.selectedOptions && el.selectedOptions[0] ? el.selectedOptions[0].textContent : '';
}
function cmpFillSessions(){
  var a = document.getElementById('cmp-a'), b = document.getElementById('cmp-b');
  if (!a || !b) return;
  var srcs = Object.keys(vmUriBySource || {});
  // 与页头会话下拉一致：显示「应用包名 · 会话来源」，无包名时只显示来源。
  var opts = srcs.map(function(s){ return { v: vmUriBySource[s], l: (vmApps[s] ? vmApps[s] + ' · ' : '') + s }; });
  var html = opts.length
    ? opts.map(function(o){ return '<option value="' + esc(o.v) + '">' + esc(o.l) + '</option>'; }).join('')
    : '<option value="">（无可用会话）</option>';
  // 文本未变不重建，避免 5s 轮询打断正在展开的下拉。
  if (a.innerHTML !== html) a.innerHTML = html;
  if (b.innerHTML !== html) b.innerHTML = html;
  var vals = opts.map(function(o){ return o.v; });
  var pa = a.value, pb = b.value;
  if (vals.indexOf(pa) < 0) pa = vals[0] || '';
  if (vals.indexOf(pb) < 0 || pb === pa) pb = vals[1] || vals[0] || '';
  a.value = pa; b.value = pb;
}
function cmpLoad(){
  cmpFillSessions();
  fetch('/api/auto/list').then(function(r){ return r.json(); }).then(function(j){
    var sel = document.getElementById('cmp-sel');
    var cur = sel.value;
    sel.innerHTML = '<option value="">— 选择场景 —</option>' + (j.items || []).map(function(s){
      return '<option value="' + esc(s.name) + '">' + esc(s.name) + '（' + s.steps + ' 步）</option>';
    }).join('');
    if (cur) sel.value = cur;
  }).catch(function(){});
  cmpPoll(); // 页面重载后恢复上一次运行的结果
}
function cmpRun(){
  var name = document.getElementById('cmp-sel').value;
  if (!name) { alert('请先选择场景'); return; }
  var uriA = document.getElementById('cmp-a').value;
  var uriB = document.getElementById('cmp-b').value;
  if (!uriA || !uriB) { alert('请选择两个会话（页头右侧拉框需已发现调试会话）'); return; }
  if (uriA === uriB) { alert('A / B 不能是同一个会话'); return; }
  cmpNet = { a: [], b: [] };
  document.getElementById('cmp-net-wrap').style.display = 'none';
  document.getElementById('cmp-prog').textContent = '启动中…';
  fetch('/api/compare/run', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({
    name: name, uriA: uriA, uriB: uriB, labelA: cmpSelText('cmp-a'), labelB: cmpSelText('cmp-b'),
    continueOnFail: document.getElementById('cmp-cont').checked,
    shotEveryStep: document.getElementById('cmp-shot').checked
  })})
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { document.getElementById('cmp-prog').textContent = '启动失败：' + d.error; return; }
      clearTimeout(cmpTimer); cmpPoll();
    })
    .catch(function(e){ document.getElementById('cmp-prog').textContent = '启动失败：' + e; });
}
function cmpStop(){ fetch('/api/compare/stop', {method:'POST'}).catch(function(){}); }
function cmpPoll(){
  fetch('/api/compare/status').then(function(r){ return r.json(); }).then(function(d){
    cmpState = d;
    cmpRender();
    clearTimeout(cmpTimer);
    if (d.running) { cmpTimer = setTimeout(cmpPoll, 800); }
    else if (d.runId) { cmpNetLoad(); }
  }).catch(function(){});
}
function cmpStatusHtml(st){
  if (!st) return '<span class="muted">—</span>';
  var cls = st === 'pass' ? 'ok' : (st === 'fail' ? 'bad' : 'muted');
  return '<span class="' + cls + '">' + esc(st) + '</span>';
}
// 两侧步骤差异：状态/实际值/错误/耗时（阈值 200ms）。
function cmpDiffs(ra, rb){
  var ds = [];
  if (!ra || !rb) { ds.push('缺失'); return ds; }
  if (ra.status !== rb.status) ds.push('状态');
  if ((ra.actual || '') !== (rb.actual || '')) ds.push('实际值');
  if ((ra.error || '') !== (rb.error || '')) ds.push('错误');
  if (Math.abs((ra.ms || 0) - (rb.ms || 0)) >= 200) ds.push('耗时');
  return ds;
}
function cmpSideHtml(side, r){
  var label = side ? esc(side.label || side.uri || '') : '';
  var body = '<div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;font-size:12px">'
    + '<b>' + label + '</b>' + cmpStatusHtml(r && r.status)
    + (r && r.ms ? '<span class="muted">' + r.ms + 'ms</span>' : '')
    + (r && r.expect ? '<span class="muted">期望：' + esc(String(r.expect).slice(0, 80)) + '</span>' : '') + '</div>';
  if (r && r.actual) body += '<div style="font-family:monospace;font-size:12px;white-space:pre-wrap;word-break:break-all;margin-top:2px">' + esc(String(r.actual).slice(0, 600)) + '</div>';
  if (r && r.error) body += '<div class="bad" style="font-family:monospace;font-size:12px;white-space:pre-wrap;word-break:break-all;margin-top:2px">' + esc(r.error) + '</div>';
  if (r && r.shot) {
    var u = '/api/auto/artifact?f=' + encodeURIComponent(r.shot);
    body += '<div style="margin-top:4px"><img src="' + u + '" style="max-width:100%;max-height:200px;border:1px solid var(--line);border-radius:4px;cursor:zoom-in" title="点击查看原图" onclick="window.open(\'' + u + '\')"></div>';
  }
  return body;
}
function cmpRender(){
  var d = cmpState;
  var bodyEl = document.getElementById('cmp-body'), sumEl = document.getElementById('cmp-summary');
  var onlyEl = document.getElementById('cmp-onlydiff-wrap');
  if (!d || !d.runId) {
    sumEl.innerHTML = ''; bodyEl.innerHTML = '<span class="muted">还没有对比结果：选场景与 A/B 会话后点「并排运行」</span>';
    if (onlyEl) onlyEl.style.display = 'none';
    return;
  }
  var A = d.a || {}, B = d.b || {};
  var ra = A.results || [], rb = B.results || [];
  var n = Math.max(ra.length, rb.length);
  var passA = 0, failA = 0, passB = 0, failB = 0, diffSteps = 0, msA = 0, msB = 0;
  var cards = '';
  for (var i = 0; i < n; i++) {
    var x = ra[i], y = rb[i];
    if (x) { msA += x.ms || 0; if (x.status === 'pass') passA++; else if (x.status === 'fail') failA++; }
    if (y) { msB += y.ms || 0; if (y.status === 'pass') passB++; else if (y.status === 'fail') failB++; }
    var ds = cmpDiffs(x, y);
    if (ds.length) diffSteps++;
    var stepLabel = (x && x.type) || (y && y.type) || '?';
    var dsHtml = ds.length
      ? '<span class="bad" style="margin-left:auto;font-size:12px">差异：' + ds.join(' / ') + '</span>'
      : '<span class="ok" style="margin-left:auto;font-size:12px">一致</span>';
    cards += '<div class="cmpcard" data-diff="' + (ds.length ? '1' : '0') + '" style="border:1px solid var(--line);border-radius:8px;margin-bottom:8px;overflow:hidden">'
      + '<div style="display:flex;align-items:center;gap:10px;padding:5px 10px;background:#0d1117;border-bottom:1px solid var(--line);font-size:13px">'
      + '<b>#' + (i + 1) + '</b><span>' + esc(stepLabel) + '</span>' + dsHtml + '</div>'
      + '<div style="display:grid;grid-template-columns:1fr 1fr;gap:1px;background:var(--line)">'
      + '<div style="background:var(--bg);padding:6px 10px">' + cmpSideHtml(A, x) + '</div>'
      + '<div style="background:var(--bg);padding:6px 10px">' + cmpSideHtml(B, y) + '</div>'
      + '</div></div>';
  }
  var dur = d.startedAt ? ((d.finishedAt ? Date.parse(d.finishedAt) : Date.now()) - Date.parse(d.startedAt)) : 0;
  sumEl.innerHTML = '<div style="display:flex;gap:16px;flex-wrap:wrap;font-size:13px">'
    + '<span><b>A</b> ' + esc(A.label || '') + '：<span class="ok">' + passA + ' pass</span>' + (failA ? ' / <span class="bad">' + failA + ' fail</span>' : '') + ' · ' + (msA / 1000).toFixed(1) + 's</span>'
    + '<span><b>B</b> ' + esc(B.label || '') + '：<span class="ok">' + passB + ' pass</span>' + (failB ? ' / <span class="bad">' + failB + ' fail</span>' : '') + ' · ' + (msB / 1000).toFixed(1) + 's</span>'
    + '<span class="' + (diffSteps ? 'bad' : 'ok') + '">' + (diffSteps ? '不一致 ' + diffSteps + ' 步' : '✓ 两侧完全一致') + '</span>'
    + '<span class="muted">共 ' + n + ' 步 · 用时 ' + (dur / 1000).toFixed(1) + 's' + (d.name ? ' · 场景 ' + esc(d.name) : '') + '</span>'
    + '</div>';
  document.getElementById('cmp-prog').textContent = d.running ? '运行中…' : '已完成';
  if (onlyEl) onlyEl.style.display = n ? '' : 'none';
  var html = cards || '<span class="muted">无步骤</span>';
  bodyEl.innerHTML = html;
  if (document.getElementById('cmp-onlydiff').checked) cmpApplyOnlyDiff();
}
function cmpApplyOnlyDiff(){
  var only = document.getElementById('cmp-onlydiff').checked;
  document.querySelectorAll('#cmp-body .cmpcard').forEach(function(el){
    el.style.display = (!only || el.dataset.diff === '1') ? '' : 'none';
  });
}
function cmpKey(it){ return (it.method || '') + ' ' + (it.url || ''); }
function cmpAgg(items){
  var m = {};
  (items || []).forEach(function(it){
    var k = cmpKey(it);
    var g = m[k] || (m[k] = { n: 0, codes: {}, ms: 0, err: '' });
    g.n++;
    if (it.statusCode) g.codes[it.statusCode] = 1;
    var ms = parseInt(it.durationMs, 10); if (!isNaN(ms)) g.ms += ms;
    if (it.error) g.err = it.error;
  });
  return m;
}
function cmpCodes(g){
  if (!g) return '—';
  var ks = Object.keys(g.codes);
  return ks.length ? ks.join('/') : (g.err ? 'ERR' : '…');
}
function cmpNetLoad(){
  if (!cmpState || !cmpState.runId) return;
  var s = Date.parse(cmpState.startedAt) - 2000;
  var e = cmpState.finishedAt ? Date.parse(cmpState.finishedAt) + 2000 : Date.now();
  var aUri = (cmpState.a || {}).uri, bUri = (cmpState.b || {}).uri;
  if (!aUri || !bUri) return;
  function grab(uri){
    return fetch('/api/network?uri=' + encodeURIComponent(uri))
      .then(function(r){ return r.json(); })
      .then(function(d){ return (d.items || []).filter(function(it){ var t = Date.parse(it.time); return isNaN(t) || (t >= s && t <= e); }); })
      .catch(function(){ return []; });
  }
  Promise.all([grab(aUri), grab(bUri)]).then(function(res){
    cmpNet = { a: res[0], b: res[1] };
    cmpRenderNet();
  });
}
function cmpRenderNet(){
  var wrap = document.getElementById('cmp-net-wrap');
  wrap.style.display = '';
  var ga = cmpAgg(cmpNet.a), gb = cmpAgg(cmpNet.b);
  var keys = {};
  Object.keys(ga).forEach(function(k){ keys[k] = 1; });
  Object.keys(gb).forEach(function(k){ keys[k] = 1; });
  var list = Object.keys(keys);
  if (!list.length) { document.getElementById('cmp-net').innerHTML = '<span class="muted">运行窗口内两侧都没有网络请求</span>'; return; }
  var rows = '', diff = 0;
  list.sort().forEach(function(k){
    var x = ga[k], y = gb[k];
    var concl;
    if (!y) { concl = '<span class="bad">仅 A 有</span>'; diff++; }
    else if (!x) { concl = '<span class="bad">仅 B 有</span>'; diff++; }
    else if (cmpCodes(x) !== cmpCodes(y)) { concl = '<span style="color:#d29922">状态码不同</span>'; diff++; }
    else if (x.n !== y.n) { concl = '<span style="color:#d29922">次数不同</span>'; diff++; }
    else { concl = '<span class="ok">一致</span>'; }
    rows += '<tr><td style="font-family:monospace">' + esc(k) + '</td>'
      + '<td>' + (x ? x.n : '—') + '</td><td>' + cmpCodes(x) + '</td><td>' + (x ? x.ms + 'ms' : '—') + '</td>'
      + '<td>' + (y ? y.n : '—') + '</td><td>' + cmpCodes(y) + '</td><td>' + (y ? y.ms + 'ms' : '—') + '</td>'
      + '<td>' + concl + '</td></tr>';
  });
  document.getElementById('cmp-net').innerHTML = '<div class="muted" style="margin:2px 0;font-size:12px">A ' + cmpNet.a.length + ' 条 / B ' + cmpNet.b.length + ' 条，差异 ' + diff + ' 项</div>'
    + '<table class="sbtable"><tr><th>方法 URL</th><th>A 次数</th><th>A 状态</th><th>A 耗时</th><th>B 次数</th><th>B 状态</th><th>B 耗时</th><th>结论</th></tr>' + rows + '</table>';
}
function renderHdrDev() {
  var html = '<option value="">未选择设备</option>';
  devices.forEach(function(d){
    html += '<option value="' + esc(d.id) + '" ' + (d.id === selected ? 'selected' : '') + '>'
      + (platformNames[d.platform] || d.platform) + ' · ' + esc(d.name) + '（' + esc(d.state) + '）</option>';
  });
  document.getElementById('hdrdev').innerHTML = html;
  syncAwake();
}
// 常亮开关：只对 Android / 鸿蒙设备出现；勾选状态以后端下发的 keepAwake 为准
function applyKeepAwake(list){
  keepAwakeSet = {};
  (list || []).forEach(function(id){ keepAwakeSet[id] = 1; });
}
function syncAwake(){
  var wrap = document.getElementById('hdr-awake-wrap');
  var cb = document.getElementById('hdr-awake');
  var d = null;
  for (var i = 0; i < devices.length; i++) {
    if (devices[i].id === selected) { d = devices[i]; break; }
  }
  var ok = !!d && (d.platform === 'android' || d.platform === 'ohos');
  wrap.style.display = ok ? '' : 'none';
  cb.checked = ok && !!keepAwakeSet[d.id];
}
function setKeepAwake(on){
  if (!selected) return;
  var cb = document.getElementById('hdr-awake');
  var id = selected;
  cb.disabled = true;
  fetch('/api/keepawake', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ deviceId: id, on: on }) })
    .then(function(r){ return r.json().then(function(d){ return { ok: r.ok && d.ok !== false, message: d.message }; }); })
    .catch(function(e){ return { ok: false, message: '' + e }; })
    .then(function(res){
      if (!res.ok) alert('设置屏幕常亮失败：' + (res.message || '未知错误'));
      cb.disabled = false;
      syncAwake();
    });
}
function refreshDevices(){ ws.send(JSON.stringify({type:'refresh'})); }
function refreshAll(){ refreshDevices(); refreshDaemon(); }
function selectDevice(id){ selected = id; ws.send(JSON.stringify({type:'select', id: id})); renderLogs(); renderHdrDev(); if (tlOnTab()) tlRender(); }
var osByPlatform = { android: 'android', ohos: 'ohos', 'ios-sim': 'ios', 'ios-real': 'ios' };
var logSeq = 0, logCursor = 0, logDebounce = null, logLastKey = null;
// 是否跟随最新日志（距底 <40px）：滚动时维护，来源开关据此决定是否贴底，
// 避免点击时同步读 scrollHeight 强制 layout（几千行时一次 20ms+）。
var logFollow = true;
document.getElementById('logview').addEventListener('scroll', function(){
  var v = this;
  logFollow = v.scrollHeight - v.scrollTop - v.clientHeight < 40;
});
function trimLogs(){
  // 与服务端一致：1) 按来源（source|tag|device）各留最近 1000 条；2) 总量再留
  // 最近 5000 条，且优先丢最旧的非 Flutter 行。否则单个高频会话或设备日志
  // 洪流会把其他会话刚到达的日志挤掉，表现为「切到某会话后勾了 Flutter
  // 输出也没有日志」。
  // 批量裁剪：超过 5500 才裁回 5000，避免每批 WS 消息都重建一次数组
  if (logs.length <= 5500) return;
  var counts = {}, kept = [];
  for (var i = logs.length - 1; i >= 0; i--) {
    var l = logs[i];
    var k = (l.source || '') + '|' + (l.tag || '') + '|' + (l.device || '');
    var c = counts[k] || 0;
    if (c >= 1000) continue;
    counts[k] = c + 1;
    kept.push(l);
  }
  kept.reverse();
  var drop = kept.length - 5000;
  if (drop > 0) {
    var out = [];
    for (var j = 0; j < kept.length; j++) {
      var l2 = kept[j];
      var isF = l2.source && l2.source.indexOf('flutter') === 0;
      if (drop > 0 && !isF) { drop--; continue; }
      out.push(l2);
    }
    if (drop > 0) out = out.slice(drop);
    kept = out;
  }
  logs = kept;
}
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
  // 过滤条件签名：条件没变时新日志可增量追加，条件变了才全量重建。
  // 来源开关（设备日志/Flutter 输出）不进签名：它们只切 CSS 显隐（logToggleSrc），
  // 否则每勾一次都要重建几千行 DOM，设备日志高频时明显卡顿。
  p.key = JSON.stringify([p.kws, p.vmFilter, p.selected, p.devOs,
    Object.keys(p.lv).filter(function(k){ return p.lv[k]; }).sort()]);
  return p;
}
// 渲染用参数：设备行与 Flutter 行一律参与渲染，显隐交给 #logview 的 nodev/noflutter
function logViewParams(p) {
  return { wantDevice: true, wantFlutter: true, lv: p.lv, kws: p.kws,
    vmFilter: p.vmFilter, selected: p.selected, devOs: p.devOs };
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
// 日志视图最多保留的 DOM 行数：hilog/logcat 可达数千行且持续追加，全量挂 DOM
// 会让滚动、勾选来源开关、切 Tab 都变卡；更早的行仍可用「导出」查看。
// 已关闭来源的隐藏行不占用可见行的名额（见 renderLogs 归并裁剪）。
var kLogDomMax = 4000, kLogDomSlack = 200;
function logLineHtml(l) {
  var t = l.ts || l.rcv || '';
  var src = l.source + (l.device ? '·' + l.device : '');
  // fline/devline：来源开关只切 CSS 显隐，不重建 DOM
  var cat = l.source && l.source.indexOf('flutter') === 0 ? ' fline' : ' devline';
  return '<div class="lv-' + (l.level || 'I') + cat + '" data-seq="' + (l._seq || 0) + '"><span class="muted">' + esc(t) + '</span> <span class="src">[' + esc(src) + ']</span> <span class="tag">' + esc(l.app || vmApps[l.tag] || l.tag || '') + '</span> ' + esc(l.msg) + '</div>';
}
function renderLogs(keepSeq) {
  var view = document.getElementById('logview');
  var p = logParams();
  var vp = logViewParams(p);
  // 仅当原本贴底时才跟随滚动：用户往上翻/选中文字时不会被强制拉底
  var atBottom = view.scrollHeight - view.scrollTop - view.clientHeight < 40;
  logFollow = atBottom;
  var rows = [];
  // 分可见/隐藏两类收集：隐藏行（来源开关已关）不能挤掉用户正在看的行
  var hideDev = !p.wantDevice, hideFl = !p.wantFlutter;
  var vis = [], visSeq = [], hid = [], hidSeq = [];
  logs.forEach(function(l){
    if (l._seq === undefined) l._seq = ++logSeq;
    if (!logFilterOne(l, vp)) return;
    var isF = l.source && l.source.indexOf('flutter') === 0;
    var s = logLineHtml(l);
    if ((hideDev && !isF) || (hideFl && isF)) { hid.push(s); hidSeq.push(l._seq); }
    else { vis.push(s); visSeq.push(l._seq); }
  });
  // 定位场景（时间轴/异常跳日志）放宽上限，保证目标行一定渲染出来
  var maxKeep = keepSeq ? kLogDomMax * 2 : kLogDomMax;
  if (vis.length > maxKeep) { vis = vis.slice(-maxKeep); visSeq = visSeq.slice(-maxKeep); }
  var room = maxKeep - vis.length;
  if (hid.length > room) { hid = hid.slice(-room); hidSeq = hidSeq.slice(-room); }
  // 归并回时间顺序
  for (var a = 0, b = 0; a < vis.length || b < hid.length; ) {
    if (b >= hid.length || (a < vis.length && visSeq[a] <= hidSeq[b])) {
      rows.push(vis[a]); a++;
    } else {
      rows.push(hid[b]); b++;
    }
  }
  if (rows.length > maxKeep) rows = rows.slice(-maxKeep);
  view.innerHTML = rows.join('') || (!vmFilter && !selected
    ? '<span class="muted">未选择 VM 或设备，不显示日志（请在页头右侧选择）</span>'
    : '<span class="muted">暂无日志</span>');
  logSyncSrcClass(view, p);
  logLastKey = p.key;
  logCursor = logs.length ? logs[logs.length - 1]._seq : 0;
  if (!paused && atBottom) view.scrollTop = view.scrollHeight;
}
function logSyncSrcClass(view, p) {
  view.classList.toggle('nodev', !p.wantDevice);
  view.classList.toggle('noflutter', !p.wantFlutter);
}
// 勾选/取消「设备日志」「Flutter 输出」：只切显隐 + 按需贴底，不重建 DOM
function logToggleSrc() {
  syncGroup();
  var view = document.getElementById('logview');
  var p = logParams();
  // 边界：要打开的来源在 DOM 里已经被行数上限裁光了（但缓冲里还有），
  // 重建一次补齐；正常情况只切 class，不重建。
  if (logSrcMissing(view, p)) { renderLogs(); return; }
  logSyncSrcClass(view, p);
  // 贴底延到下一帧：点击时不同步读/写布局，避免几千行日志重排阻塞交互
  if (logFollow) requestAnimationFrame(function(){ view.scrollTop = view.scrollHeight; });
}
function logSrcMissing(view, p) {
  var needFl = p.wantFlutter && !view.querySelector('.fline');
  var needDev = p.wantDevice && !view.querySelector('.devline');
  if (!needFl && !needDev) return false;
  // DOM 缺对应来源：扫一遍缓冲确认它确实有命中行（否则本来就不该显示）
  var vp = logViewParams(p);
  for (var i = logs.length - 1; i >= 0; i--) {
    var l = logs[i];
    if (!logFilterOne(l, vp)) continue;
    var isF = l.source && l.source.indexOf('flutter') === 0;
    if (isF && needFl) return true;
    if (!isF && needDev) return true;
  }
  return false;
}
function logTrimDom(view, atBottom) {
  // 超上限时从顶部删：已关闭来源（不可见）的行优先丢，用户正在看的可见行尽量保留。
  // 批量删 + 只读一次高度差补偿：逐行读 offsetHeight 会每行强制一次同步布局。
  if (view.children.length <= kLogDomMax + kLogDomSlack) return;
  var rm = view.children.length - kLogDomMax, i, el, pick = [];
  var hideDev = view.classList.contains('nodev');
  var hideFl = view.classList.contains('noflutter');
  if (hideDev || hideFl) {
    for (i = 0; i < view.children.length && pick.length < rm; i++) {
      el = view.children[i];
      var c = el.classList;
      if ((hideDev && c.contains('devline')) || (hideFl && c.contains('fline'))) pick.push(el);
    }
  }
  var before = atBottom ? 0 : view.scrollHeight;
  for (i = 0; i < pick.length; i++) pick[i].remove();
  for (i = pick.length; i < rm; i++) {
    el = view.firstElementChild;
    if (!el) break;
    el.remove();
  }
  if (atBottom) view.scrollTop = view.scrollHeight;
  else if (before) view.scrollTop -= (before - view.scrollHeight);
}
function logFlushNew() {
  // 新日志到达：过滤条件未变且无截断缺口时只追加新命中行（DOM 不重建，
  // 保住选中文字/避免闪烁）；无命中行时 DOM 完全不动。条件已变或缓冲
  // 被截断（游标失效）则交由 renderLogs 全量重建。
  var view = document.getElementById('logview');
  var p = logParams();
  if (p.key !== logLastKey || (logs.length && logs[0]._seq > logCursor)) { renderLogs(); return; }
  var vp = logViewParams(p);
  var atBottom = view.scrollHeight - view.scrollTop - view.clientHeight < 40;
  logFollow = atBottom;
  // 从尾部找新增起点：只处理本批新行，不再每批都全量扫 5000 条
  var start = logs.length - 1;
  while (start >= 0 && logs[start]._seq > logCursor) start--;
  var html = '';
  for (var i = start + 1; i < logs.length; i++) {
    var l = logs[i];
    logCursor = l._seq;
    if (logFilterOne(l, vp)) html += logLineHtml(l);
  }
  if (!html) return;
  view.insertAdjacentHTML('beforeend', html);
  if (atBottom) view.scrollTop = view.scrollHeight;
  logTrimDom(view, atBottom);
}
function togglePause(btn){ paused = !paused; btn.textContent = paused ? '继续' : '暂停'; if (!paused) renderLogs(); }
function copyLogs(btn) {
  // 复制当前框中显示的全部日志（直接读 DOM 渲染行，所见即所得）。
  // 不能从 logs 缓冲重算：5000 条全局缓冲会被其他来源（hilog/其他会话）
  // 高频挤占，选中会话的行被挤出后重算结果会少于框中显示甚至为空。
  var view = document.getElementById('logview');
  var lines = [];
  view.querySelectorAll('div[class^="lv-"]').forEach(function(d){
    if (!d.getClientRects().length) return; // 被来源开关隐藏的行不计入
    lines.push(d.innerText);
  });
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
function clearLogs(){ logs = []; renderLogs(); if (tlOnTab()) tlSchedule(); }

// -- 时间轴 Tab ------------------------------------------------------------
// 合并四类数据：服务端推的路由/网络（tlOrder）+ 本地日志 logs + 异常 excItems。
// 日志与异常不进服务端，避免与已有 WS 通道重复传输。
var watchEvents = [];   // 监听事件（WS 推送 + 打开 Tab 时回填，服务端保留 500 条）
var tlOrder = [], tlByKey = {}, tlPaused = false, tlDirtyTimer = null;
var tlExpanded = {}, tlSubUri = '', tlNewCount = 0, tlKwTimer = null;
// 时间轴视图下限：点「清空」后早于此刻的事件不再显示。日志与异常是各 Tab
// 共用的本地数据（不能替用户删掉），只能靠这个下限把它们从时间轴里隐藏，
// 否则清空只清掉路由/网络，页面上还留着一屏日志，看起来就像没清。
// 记 uri 是为了切换会话后自动失效，不然新会话的历史也会被一起挡掉。
var tlFloor = { uri: '', ms: 0 };
function tlFloorMs(){
  var u = tlUri();
  // 只在两个非空会话之间切换时失效：新会话有自己的历史，不该被上一次的
  // 清空挡住。会话掉线（u 为空）或清空时本来没会话，都不算切换，否则
  // 已清空的日志会重新冒出来。
  if (u && tlFloor.uri && u !== tlFloor.uri) return 0;
  return tlFloor.ms;
}
// ms 缺失或不是数字（部分异常只有文本时间）时按「保留」处理，避免误杀新事件。
function tlBeforeFloor(ms){
  var f = tlFloorMs();
  return f > 0 && typeof ms === 'number' && ms > 0 && ms < f;
}
// 按住鼠标（准备点击/拖选）时不重建时间轴 DOM：否则 mousedown 与 mouseup
// 之间的行被 250ms 合帧刷新替换，click 不会触发，表现为要点两次才生效。
var tlPointerHeld = false, tlPointerReleaseTimer = null;
document.addEventListener('mousedown', function(e){
  if (e.target && e.target.closest && e.target.closest('#tl-body')) {
    tlPointerHeld = true;
    if (tlPointerReleaseTimer) { clearTimeout(tlPointerReleaseTimer); tlPointerReleaseTimer = null; }
  }
}, true);
document.addEventListener('mouseup', function(){
  // 松开后再保留 300ms：click 在 mouseup 之后单独派发，若这期间合帧刷新
  // 替换了行，click 仍会丢失（仍需点第二次）。
  if (tlPointerReleaseTimer) clearTimeout(tlPointerReleaseTimer);
  tlPointerReleaseTimer = setTimeout(function(){ tlPointerHeld = false; tlPointerReleaseTimer = null; }, 300);
}, true);

function tlOnTab(){ var t = document.querySelector('.tab.active'); return t && t.dataset.tab === 'timeline'; }
function tlUri(){ return vmFilter ? (vmUriBySource[vmFilter] || '') : ''; }
function tlStat(msg){ var el = document.getElementById('tl-stat'); if (el) el.textContent = msg; }
function tlCb(id){ var el = document.getElementById(id); return !!(el && el.checked); }

function tlShow(){
  tlRender();
  tlSubscribe();
  inWatchBackfill();
}

function tlHide(){
  // 切走即停轮询：避免后台持续 eval 影响 app（重新进入时再同步一次）
  tlSubUri = '';
  fetch('/api/timeline/off', { method: 'POST' }).catch(function(){});
}

function tlSubscribe(){
  var uri = tlUri();
  if (!uri) { tlStat('请先选择 VM（页头右侧会话下拉框）'); return; }
  if (uri === tlSubUri) return;
  tlSubUri = uri;
  tlStat('同步中…');
  fetch('/api/timeline/sub', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ uri: uri }) })
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { tlStat('同步失败：' + d.error); return; }
      tlOrder = []; tlByKey = {};
      tlMerge(d.items || []);
      tlRender();
      inWatchBackfill();
    })
    .catch(function(e){ tlStat('同步失败：' + e); });
}

function tlResub(){
  if (!tlOnTab()) return;
  tlSubUri = '';
  tlSubscribe();
}

function tlMerge(items){
  var changed = false;
  items.forEach(function(e){
    if (!e || !e.t) return;
    // 服务端清空失败或订阅重放时，别把清空前的历史又 merge 回来。
    if (tlBeforeFloor(e.ms)) return;
    var k = e.t + ':' + e.id;
    var old = tlByKey[k];
    if (old) {
      // 网络 pending → 完成：原地更新可变字段（不新增行，保持发起时间位置）
      var upd = false;
      ['code','dur','status','err'].forEach(function(f){ if (old[f] !== e[f]) { old[f] = e[f]; upd = true; } });
      if (upd) changed = true;
      return;
    }
    tlByKey[k] = e; tlOrder.push(e); changed = true;
  });
  if (changed) tlSchedule();
}

function tlSchedule(){
  if (!tlOnTab()) return;
  if (tlPaused) { tlNewCount = 1; tlUpdateNewBar(); return; }
  if (tlDirtyTimer) return;
  tlDirtyTimer = setTimeout(function(){
    tlDirtyTimer = null;
    if (tlPointerHeld) { tlSchedule(); return; } // 等松手后再渲染
    tlRender();
  }, 250);
}

function tlKwInput(){
  if (tlKwTimer) clearTimeout(tlKwTimer);
  tlKwTimer = setTimeout(function(){ tlKwTimer = null; tlRender(); }, 200);
}

function tlTime(ms){
  var d = new Date(ms || 0);
  function p(n, w){ n = String(n); while (n.length < (w || 2)) n = '0' + n; return n; }
  return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()) + '.' + p(d.getMilliseconds(), 3);
}

function tlLogVisible(l, wantFlutter, wantWarn, wantAll){
  var isFlutter = l.source && l.source.indexOf('flutter') === 0;
  if (isFlutter) {
    if (!wantFlutter) return false;
    if (vmFilter) return (l.tag || '') === vmFilter;
    return !!selected; // 只选设备时无法精确归属，宽松展示避免漏
  }
  if (!selected) return false;
  if ((l.device || '') !== selected) return false;
  var lv = l.level || 'I';
  if (lv === 'W' || lv === 'E' || lv === 'F') return wantWarn || wantAll;
  return wantAll;
}

function tlBuild(){
  var now = Date.now();
  var range = parseInt(document.getElementById('tl-range').value, 10) || 0;
  var cutoff = range > 0 ? now - range * 60000 : 0;
  var evs = [];
  if (tlCb('tl-t-route')) tlOrder.forEach(function(e){ if (e.t === 'route' && e.ms >= cutoff && !tlBeforeFloor(e.ms)) evs.push(e); });
  if (tlCb('tl-t-net')) tlOrder.forEach(function(e){ if (e.t === 'net' && e.ms >= cutoff && !tlBeforeFloor(e.ms)) evs.push(e); });
  if (tlCb('tl-t-log')) {
    var wantFlutter = tlCb('tl-lv-flutter'), wantWarn = tlCb('tl-lv-warn'), wantAll = tlCb('tl-lv-all');
    logs.forEach(function(l){
      if (l._seq === undefined) l._seq = ++logSeq;
      if (!tlLogVisible(l, wantFlutter, wantWarn, wantAll)) return;
      var ms = l.rcvMs || 0;
      if (ms < cutoff) return;
      if (tlBeforeFloor(ms)) return;
      evs.push({ t:'log', id:'l' + l._seq, ms: ms, level: l.level, tag: l.tag, app: l.app,
        msg: l.msg, ts: l.ts, source: l.source, device: l.device, _l: l });
    });
  }
  if (tlCb('tl-t-exc')) {
    excItems.forEach(function(it){
      var ms = it.ts || 0;
      if (ms < cutoff) return;
      if (tlBeforeFloor(ms)) return;
      evs.push({ t:'exc', id:'e' + it.id, ms: ms, item: it, count: it.count || 1, summary: it.summary || '' });
    });
  }
  if (tlCb('tl-t-watch')) {
    var wUri = tlUri();
    watchEvents.forEach(function(e){
      if (e.ms < cutoff) return;
      if (tlBeforeFloor(e.ms)) return;
      if (wUri && e.uri !== wUri) return;
      evs.push(e);
    });
  }
  var kw = (document.getElementById('tl-kw').value || '').trim().toLowerCase();
  if (kw) evs = evs.filter(function(e){ return tlHay(e).indexOf(kw) >= 0; });
  var weight = { exc: 4, net: 3, watch: 2, route: 2, log: 1 };
  evs.sort(function(a, b){ return a.ms - b.ms || weight[b.t] - weight[a.t]; });
  return evs;
}

function tlHay(e){
  if (e.t === 'route') return ((e.action || '') + ' ' + (e.name || '') + ' ' + (e.prev || '') + ' ' + (e.phase || '')).toLowerCase();
  if (e.t === 'net') return ((e.method || '') + ' ' + (e.url || '') + ' ' + (e.code || '') + ' ' + (e.status || '') + ' ' + (e.err || '')).toLowerCase();
  if (e.t === 'exc') return ((e.summary || '') + ' ' + ((e.item && (e.item.desc || e.item.widget || e.item.source)) || '')).toLowerCase();
  if (e.t === 'watch') {
    var w = e.w || {};
    return ((w.label || '') + ' ' + (w.expr || '') + ' ' + (w.old || '') + ' ' + (w.new || '') + ' ' + (w.condition || '') + ' ' + (w.error || '')).toLowerCase();
  }
  return ((e.msg || '') + ' ' + (e.tag || '') + ' ' + (e.app || '')).toLowerCase();
}

function tlPlain(e){
  if (e.t === 'route') return (e.action || 'push') + ' ' + (e.name || '<unnamed>') + (e.prev ? ' <- ' + e.prev : '');
  if (e.t === 'net') return (e.method || '') + ' ' + (e.url || '') + (e.code ? ' ' + e.code : '') + (e.dur ? ' ' + e.dur + 'ms' : '') + (e.err ? ' ERR ' + e.err : '');
  if (e.t === 'exc') return '异常 ' + (e.summary || '') + (e.count > 1 ? ' x' + e.count : '');
  if (e.t === 'watch') {
    var w = e.w || {};
    var head = '监听 ' + (w.label || w.expr || '');
    if (w.error) return head + ' 错误 ' + w.error;
    if (w.condMet) return head + ' 条件命中 ' + (w.new == null ? '' : w.new) + (w.shot ? ' [截图]' : '');
    return head + ' ' + (w.old == null ? '—' : w.old) + ' -> ' + (w.new == null ? '—' : w.new);
  }
  return '[' + (e.level || 'I') + '/' + (e.tag || '') + '] ' + (e.msg || '');
}

function tlShortUrl(u){
  u = u || '';
  return u.length > 110 ? u.substring(0, 110) + '…' : u;
}

function tlRowHtml(e){
  var k = e.t + ':' + e.id;
  var open = !!tlExpanded[k];
  var cls = 'tl-row tl-' + e.t;
  var sum = '', aux = '', badge = '';
  if (e.t === 'route') {
    badge = '路由';
    sum = esc(e.action || 'push') + ' ' + esc(e.name || '<unnamed>');
    if (e.prev) sum += ' <span class="muted">← ' + esc(e.prev) + '</span>';
    if (e.phase && e.phase !== 'idle') aux = '<span style="color:#d29922">' + esc(e.phase) + '</span>';
  } else if (e.t === 'net') {
    badge = '网络';
    var code = parseInt(e.code, 10);
    var color = (e.status === 'failure' || e.status === 'cancelled') ? '#f85149'
      : (e.status === 'pending' ? '#8b949e' : (code >= 200 && code < 400 ? '#7ee787' : '#f85149'));
    sum = esc(e.method) + ' ' + esc(tlShortUrl(e.url));
    if (!isNaN(code)) sum += ' <span style="color:' + color + '">' + code + '</span>';
    if (e.err) sum += ' <span class="bad">' + esc(String(e.err).substring(0, 80)) + '</span>';
    aux = e.dur ? e.dur + 'ms' : (e.status === 'pending' ? '进行中' : '');
  } else if (e.t === 'exc') {
    badge = '异常';
    sum = esc(e.summary || '(无摘要)');
    aux = e.count > 1 ? '×' + e.count : '';
  } else if (e.t === 'watch') {
    badge = '监听';
    var w = e.w || {};
    sum = esc(w.label || w.expr || '');
    if (w.error) {
      sum += ' <span class="bad">' + esc(String(w.error).substring(0, 90)) + '</span>';
    } else if (w.condMet) {
      sum += ' <span class="muted">条件命中，当前</span> <span style="color:#79c0ff">' + esc(w.new == null ? '' : String(w.new)) + '</span>';
    } else {
      sum += ' <span class="muted">' + esc(w.old == null ? '—' : String(w.old)) + '</span> → <span style="color:#79c0ff">' + esc(w.new == null ? '—' : String(w.new)) + '</span>';
    }
    if (w.shot) aux = '已截图';
    else if (w.condition) aux = '条件 ' + esc(w.condition);
    else aux = '#' + (w.changes || 0);
  } else {
    badge = '日志';
    var lv = e.level || 'I';
    if (lv === 'W' || lv === 'E' || lv === 'F') cls += ' tl-' + (lv === 'W' ? 'w' : 'e');
    sum = esc(String(e.msg || '').substring(0, 400));
    aux = esc(e.app || e.tag || '');
  }
  var html = '<div class="' + cls + (open ? ' tl-open' : '') + '" onclick="tlToggle(\'' + esc(k) + '\')" title="点击展开">'
    + '<span class="tl-t">' + tlTime(e.ms) + '</span>'
    + '<span class="tl-badge">' + badge + '</span>'
    + '<span class="tl-sum">' + sum + '</span>'
    + '<span class="tl-aux">' + aux + '</span></div>';
  if (open) html += '<div class="tl-detail">' + tlDetailHtml(e) + '</div>';
  return html;
}

function tlDetailHtml(e){
  var rows = [];
  function row(k, v){ if (v !== undefined && v !== null && v !== '') rows.push('<div><span class="muted">' + k + '：</span>' + esc(String(v)) + '</div>'); }
  if (e.t === 'route') {
    row('动作', e.action); row('路由名', e.name); row('上一路由', e.prev); row('SchedulerPhase', e.phase);
    rows.push('<div style="margin-top:6px"><a href="javascript:void(0)" onclick="tlGoRoutesById(\'' + esc(e.id) + '\')">在路由栈中定位该路由</a></div>');
  } else if (e.t === 'net') {
    row('方法', e.method); row('URL', e.url); row('状态码', e.code); row('耗时', e.dur ? e.dur + 'ms' : '');
    row('状态', e.status); row('错误', e.err);
    rows.push('<div style="margin-top:6px"><a href="javascript:void(0)" onclick="tlGoNet(\'' + esc(e.id) + '\')">在 Network 中查看详情</a></div>');
  } else if (e.t === 'exc') {
    var it = e.item || {};
    row('摘要', it.summary); row('相关 Widget', it.widget); row('来源', it.source); row('通道', it.channel);
    if (it.desc) rows.push('<div style="margin-top:4px">' + esc(String(it.desc).substring(0, 1200)) + '</div>');
    rows.push('<div style="margin-top:6px"><a href="javascript:void(0)" onclick="tlGoExc(' + esc(String(it.id)) + ')">在异常 Tab 中定位该条</a></div>');
  } else if (e.t === 'watch') {
    var w = e.w || {};
    row('类型', w.kind === 'field' ? '字段' : '表达式'); row('监听', w.label); row('表达式', w.expr);
    row('旧值', w.old); row('新值', w.new); row('条件', w.condition);
    row('条件命中', w.condMet ? '是' : ''); row('累计变化', w.changes); row('累计截图', w.shots);
    row('错误', w.error);
    if (w.shot) rows.push('<div style="margin-top:6px"><a href="/api/auto/artifact?f=' + encodeURIComponent(w.shot) + '" target="_blank">查看条件截图 ' + esc(w.shot) + '</a></div>');
    if (w.kind === 'field') rows.push('<div style="margin-top:6px"><a href="javascript:void(0)" onclick="tlGoWatch(\'' + esc(w.watchId || '') + '\')">在实例 Tab 中定位该监听</a></div>');
  } else {
    var l = e._l || {};
    row('时间', l.ts || ''); row('来源', (l.source || '') + (l.device ? ' · ' + l.device : ''));
    row('级别', l.level); row('Tag', l.tag); row('应用', l.app);
    rows.push('<div style="margin-top:4px">' + esc(String(l.msg || '')) + '</div>');
    rows.push('<div style="margin-top:6px"><a href="javascript:void(0)" onclick="tlGoLogs(' + (l._seq || 0) + ')">在日志 Tab 中定位该行</a></div>');
  }
  return rows.join('');
}

function tlRender(){
  if (!tlOnTab()) return;
  var body = document.getElementById('tl-body');
  var evs = tlBuild();
  var total = evs.length;
  var LIMIT = 1500;
  var truncated = total > LIMIT;
  if (truncated) evs = evs.slice(total - LIMIT);
  var atBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 40;
  var prevTop = body.scrollTop;
  var html = '';
  evs.forEach(function(e){ html += tlRowHtml(e); });
  if (!html) html = '<span class="muted" style="padding:8px;display:block">' + (tlUri() ? '当前范围/过滤下没有事件（触发一次操作后再看，或放宽范围）' : '请先选择调试会话') + '</span>';
  if (truncated) html = '<div class="muted" style="padding:4px 8px">仅显示最新 ' + LIMIT + ' 条（共 ' + total + ' 条），请缩小时间范围或加关键字</div>' + html;
  body.innerHTML = html;
  if (!tlPaused && atBottom) body.scrollTop = body.scrollHeight;
  else body.scrollTop = prevTop;
  // 会话掉线后日志仍会继续到达，此时行区有内容就别再写「请先选择 VM」，
  // 否则统计文字与行区自相矛盾。
  tlStat((tlUri() || total > 0)
    ? '共 ' + total + ' 条' + (truncated ? '（显示最新 ' + LIMIT + '）' : '')
    : '请先选择 VM');
  tlUpdateNewBar();
}

function tlToggle(k){
  tlExpanded[k] = !tlExpanded[k];
  tlRender();
}

function tlUpdateNewBar(){
  var bar = document.getElementById('tl-newbar');
  if (!bar) return;
  if (tlPaused && tlNewCount > 0) {
    bar.style.display = 'block';
    bar.textContent = '有新事件（点击恢复并跳到底部）';
  } else { bar.style.display = 'none'; }
}

function tlPause(btn){
  tlPaused = !tlPaused;
  btn.textContent = tlPaused ? '继续' : '暂停';
  if (!tlPaused) { tlNewCount = 0; tlRender(); }
}

function tlToLatest(){
  if (tlPaused) { tlPaused = false; document.getElementById('tl-pause-btn').textContent = '暂停'; }
  tlNewCount = 0;
  tlRender();
  var body = document.getElementById('tl-body');
  body.scrollTop = body.scrollHeight;
  tlUpdateNewBar();
}

function tlClear(){
  // 点了就清，不再二次确认：先本地立即清空（视图下限兜住日志/异常），
  // 再异步通知服务端丢弃已累积的路由/网络/监听，失败也不影响页面。
  tlFloor = { uri: tlUri(), ms: Date.now() };
  tlOrder = []; tlByKey = {}; tlExpanded = {}; watchEvents = [];
  tlNewCount = 0;
  tlRender();
  fetch('/api/timeline/clear', { method: 'POST' }).then(function(){
    return fetch('/api/watch/clear', { method: 'POST' });
  }).catch(function(e){ tlStat('服务端清空失败（页面已清空）：' + e); });
}

function tlCopy(){
  var evs = tlBuild();
  var lines = evs.map(function(e){ return tlTime(e.ms) + ' [' + e.t + '] ' + tlPlain(e); });
  if (!lines.length) return;
  var text = lines.join('\n');
  var done = function(){ tlStat('已复制 ' + lines.length + ' 条'); };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done, function(){ copyLogsFallback(text); done(); });
  } else { copyLogsFallback(text); done(); }
}

// -- 时间轴详情 → 目标 Tab 的具体位置 ---------------------------------------
// 目标 Tab 的渲染是异步的（Network/异常/路由栈切过去才拉数据），这里轮询等待
// 目标行出现后滚动到视野中央并闪烁高亮；等待超时给出明确提示。
var locateToastTimer = null;
function locateToast(msg){
  var el = document.getElementById('locate-toast');
  if (!el) { el = document.createElement('div'); el.id = 'locate-toast'; document.body.appendChild(el); }
  el.textContent = msg;
  el.style.display = 'block';
  if (locateToastTimer) clearTimeout(locateToastTimer);
  locateToastTimer = setTimeout(function(){ el.style.display = 'none'; locateToastTimer = null; }, 3200);
}
function locateWhenFound(find, failMsg){
  var tries = 0;
  (function wait(){
    var el = find();
    if (el) {
      el.scrollIntoView({ block:'center' });
      el.classList.remove('locate-flash');
      void el.offsetWidth; // 重启动画
      el.classList.add('locate-flash');
      setTimeout(function(){ el.classList.remove('locate-flash'); }, 2600);
      return;
    }
    if (++tries > 40) { if (failMsg) locateToast(failMsg); return; }
    setTimeout(wait, 150);
  })();
}
function tlGoRoutesById(id){
  // 路由名可能含引号/空格，不能直接拼进 onclick，先按事件 id 反查名字
  var e = tlByKey['route:' + id];
  if (!e) { locateToast('该路由事件已不在时间轴中'); return; }
  tlGoRoutes(e.name || '');
}
function tlGoRoutes(name){
  document.querySelector('.tab[data-tab="routes"]').click();
  locateWhenFound(function(){
    var rows = document.querySelectorAll('#rt-body tr[data-rt-name]');
    for (var i = 0; i < rows.length; i++) {
      if ((rows[i].getAttribute('data-rt-name') || '') === name) return rows[i];
    }
    return null;
  }, '当前路由栈里没有该路由（可能已 pop 或尚未加载完成）');
}
function tlGoExc(id){
  document.querySelector('.tab[data-tab="exc"]').click();
  var kw = document.getElementById('exc-kw');
  if (kw && kw.value) { kw.value = ''; } // 关键字过滤会藏掉目标卡片
  locateWhenFound(function(){ return document.getElementById('exccard-' + id); },
    '异常列表里没有这条记录（可能已被清空）');
}
function tlGoLogs(seq){
  document.querySelector('.tab[data-tab="logs"]').click();
  // 日志 Tab 有独立的来源/级别/关键字过滤：临时放开，保证目标行可见
  var changed = false;
  var kw = document.getElementById('f-kw');
  if (kw && kw.value) { kw.value = ''; changed = true; }
  ['f-src-device', 'f-src-flutter'].forEach(function(id){
    var c = document.getElementById(id);
    if (c && !c.checked) { c.checked = true; changed = true; }
  });
  document.querySelectorAll('.f-lv').forEach(function(c){
    if (!c.checked) { c.checked = true; changed = true; }
  });
  if (changed) syncGroup();
  renderLogs(seq); // 无条件重建：即使日志 Tab 处于暂停，也把目标行渲染出来
  locateWhenFound(function(){ return document.querySelector('#logview [data-seq="' + seq + '"]'); },
    '日志视图里没有该行（可能已被过滤，或超出 5000 条缓冲）');
}
function tlGoNet(id){
  document.querySelector('.tab[data-tab="network"]').click();
  var tries = 0;
  (function wait(){
    var hit = nwItems.filter(function(x){ return x.id === id; })[0];
    if (hit) {
      var kw = document.getElementById('nw-kw');
      if (kw && kw.value) { kw.value = ''; } // 关键字过滤会藏掉目标行
      nwOpen[id] = true;
      nwRender();
      // 等切页触发的 nwRefresh 落地（会再渲染一次），避免高亮被重渲染冲掉
      setTimeout(function(){
        locateWhenFound(function(){ return document.getElementById('nwrow-' + id); },
          'Network 列表里没有该请求（可能已被 app 端清空）');
      }, 500);
      return;
    }
    if (++tries > 30) { locateToast('Network 列表尚未加载到该请求，请稍后重试'); return; }
    setTimeout(wait, 150);
  })();
}
function refreshDaemon(){
  fetch('/api/daemon').then(function(r){ return r.json(); }).then(function(d){
    var el = document.getElementById('daemon-status');
    var vm = document.getElementById('vmstat');
    var sel = document.getElementById('vmsel');
    if (!d.running) {
      if (lastDaemonRunning !== false) clog('daemon 未运行（会话下拉隐藏）');
      lastDaemonRunning = false;
      el.innerHTML = '<span class="bad">未运行</span>（启动：dart run xb_ume:ide --install）';
      vm.style.display = ''; vm.textContent = 'VM 未连接'; vm.title = '守护进程未运行';
      sel.style.display = 'none';
      var aselDown = document.getElementById('dbg-attach');
      if (aselDown) {
        dbgAttachList = [];
        aselDown.innerHTML = '<option value="">守护进程未运行（只能在本页点「启动」）</option>';
      }
    } else {
      if (lastDaemonRunning === false) clog('daemon 恢复运行');
      lastDaemonRunning = true;
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
      // 「调试」页的接入下拉与页头同源：值用下标，接入时能一并拿到
      // vm uri 与项目根（断点相对路径的基准）。
      var asel = document.getElementById('dbg-attach');
      if (asel) {
        dbgAttachList = ss;
        var ahtml = '<option value="">选择一条调试会话（共 ' + ss.length + ' 个）</option>';
        ss.forEach(function(s, i){
          ahtml += '<option value="' + i + '">'
            + esc((s.app ? s.app + ' · ' : '') + (s.source || s.uri)) + '</option>';
        });
        var apv = asel.value;
        asel.innerHTML = ahtml;
        asel.value = apv;
      }
      // 对比页的 A/B 会话下拉与页头同源（名称同显包名），已激活时同步刷新。
      if (typeof cmpActive === 'function' && cmpActive()) cmpFillSessions();
      // 保持用户选择：会话瞬断（休眠唤醒/热重启/ws 断链）不立即回退，
      // 缺失时按实例指纹（fp，端口无关）每轮尝试找回同一会话（含掉选后
      // 自愈与刷新页面后恢复）；连续 3 个周期仍缺失才回退显示为未选择，
      // 但保留指纹，会话回来自动重选。手动选「未选择会话」才清指纹。
      var prevVmFilter = vmFilter;
      var stillEntry = null;
      ss.forEach(function(s){ if ((s.source || s.uri) === vmFilter) stillEntry = s; });
      if (stillEntry) {
        vmMiss = 0;
        if (stillEntry.fp) saveVmFp(stillEntry.fp);
        sel.value = vmFilter;
      } else {
        var restored = vmFilterFp ? ss.find(function(s){ return s.fp === vmFilterFp; }) : null;
        if (restored) {
          clog('指纹找回会话: ' + (restored.source || restored.uri) + ' (fp=' + vmFilterFp + ')');
          vmFilter = restored.source || restored.uri;
          if (restored.fp) saveVmFp(restored.fp);
          sel.value = vmFilter;
          vmMiss = 0;
        } else if (vmFilter) {
          vmMiss++;
          if (vmMiss === 1) clog('会话缺失第 1 轮（容忍 3 轮）: ' + vmFilter + '；当前列表 ' + ss.map(function(s){ return s.source || s.uri; }).join(', ') + '；fp=' + vmFilterFp);
          if (vmMiss >= 3) {
            clog('会话缺失 ' + vmMiss + ' 轮，回退未选择（保留指纹 ' + vmFilterFp + ' 待自愈）');
            vmFilter = ''; vmMiss = 0;
          }
        }
      }
      if (vmFilter !== prevVmFilter) {
        renderLogs(); sbRefresh(); rtRefresh(); nwRefresh(); stRefresh(); pfOnVmChange();
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

// ── MCP 服务状态 ──
// 后端只读探测（/api/mcp）：HTTP 模式握手拿工具数，stdio 模式看进程命令行。
var mcpStatus = null;
// 用户点过「复制配置」后 #mcp-detail 展示的是要手动复制的 JSON，轮询不再
// 覆盖它（否则 15 秒后文本消失，剪贴板被拦时无兜底）；点「刷新」才恢复摘要。
var mcpConfigShown = false;
// 返回 Promise：供 copyMcpConfig 在首屏状态未到时等一次结果。
function refreshMcp(force){
  return fetch('/api/mcp').then(function(r){ return r.json(); }).then(function(d){
    mcpStatus = d;
    mcpApplyStatus(d, force);
  }).catch(function(){
    document.getElementById('mcp-status').textContent = '查询失败';
  });
}
// 状态行/按钮/开关总是跟着刷新；详情区在用户点过「复制」后不被覆盖
// （否则 15 秒轮询把配置文本冲掉，剪贴板被拦时没兑底）。
function mcpApplyStatus(d, force){
  var el = document.getElementById('mcp-status');
  var det = document.getElementById('mcp-detail');
  var btn = document.getElementById('mcp-toggle');
  var auto = document.getElementById('mcp-auto');
  if (auto) auto.checked = d.autoStart === true;
  var ev = document.getElementById('mcp-eval');
  if (ev) ev.checked = d.allowEval === true;
  if (btn) {
    if (d.running && d.mode === 'http') {
      btn.textContent = '停止';
      btn.disabled = false;
      btn.title = d.managedPid ? '停止工具箱启动的 MCP 服务（pid ' + d.managedPid + '）'
        : '这个服务不是工具箱启动的，停止会拒绝';
    } else if (d.running) {
      btn.textContent = '启动';
      btn.disabled = true;
      btn.title = '已有 stdio 模式的 MCP 进程（由客户端拉起，需在客户端里关闭）';
    } else if (d.launchable === false) {
      btn.textContent = '启动';
      btn.disabled = true;
      btn.title = '未找到 ~/.xb_ume_ide/mcp.dart，请先执行 dart run xb_ume:ide --install';
    } else {
      btn.textContent = '启动';
      btn.disabled = false;
      btn.title = '后台启动 MCP HTTP 服务（全部工具组，默认端口 46140）';
    }
  }
  if (!d.running) {
    el.innerHTML = '<span class="bad">未运行</span>';
    if (!mcpConfigShown || force) {
      det.innerHTML = '点「启动」后台拉起（默认 46140，仅本机回环，需 token）；也可手动：<code>'
        + esc(d.hint || 'dart run xb_ume:mcp') + '</code>；接入步骤见 MCP_GUIDE.md';
    }
    return;
  }
  if (d.mode === 'http') {
    el.innerHTML = '<span class="ok">运行中</span> · HTTP ' + d.port + ' · ' + (d.toolCount ? d.toolCount + ' 个工具' : '工具数未知');
    if (!mcpConfigShown || force) {
      det.innerHTML = '地址 <code>' + esc(d.url) + '</code>（仅本机回环，需 token）；协议 '
        + esc(d.protocolVersion || '未知')
        + '；已开放全部工具组（含装包/卸包/停进程，高危操作仍需 confirm）'
        + (d.allowEval ? '；已开启 eval' : '')
        + '；日志 logs/mcp.log';
    }
  } else {
    el.innerHTML = '<span class="ok">运行中</span> · stdio · pid ' + (d.pids || []).join(', ');
    if (!mcpConfigShown || force) {
      det.textContent = '由 MCP 客户端以子进程拉起（无监听端口）；工具数在客户端会话中可见';
    }
  }
}
function toggleMcp(btn){
  var running = !!(mcpStatus && mcpStatus.running && mcpStatus.mode === 'http');
  if (btn) { btn.disabled = true; btn.textContent = running ? '停止中…' : '启动中…'; }
  mcpConfigShown = false;
  fetch(running ? '/api/mcp/stop' : '/api/mcp/start', { method: 'POST' })
    .then(function(r){ return r.json(); })
    .then(function(d){
      return refreshMcp(true).then(function(){
        if (d.ok === false) {
          var det = document.getElementById('mcp-detail');
          if (det) det.innerHTML = '<span class="bad">' + esc(d.message || '操作失败') + '</span>';
        }
      });
    })
    .catch(function(e){
      if (btn) { btn.disabled = false; btn.textContent = running ? '停止' : '启动'; }
      var det = document.getElementById('mcp-detail');
      if (det) det.innerHTML = '<span class="bad">' + esc('请求失败：' + e) + '</span>';
    });
}
function setMcpAuto(cb){
  var on = !!(cb && cb.checked);
  fetch('/api/mcp/auto?on=' + (on ? '1' : '0'), { method: 'POST' })
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.ok !== true) { if (cb) cb.checked = !on; return; }
      if (mcpStatus) mcpStatus.autoStart = !!d.autoStart;
      // 勾上时服务没跑就顺手拉起：开关立刻见效，不必再点一次「启动」。
      // 取消勾选不停服务（可能正被客户端用着），要停点「停止」。
      if (on && mcpStatus && mcpStatus.launchable !== false
          && !(mcpStatus.running && mcpStatus.mode === 'http')) {
        toggleMcp(document.getElementById('mcp-toggle'));
      }
    })
    .catch(function(){ if (cb) cb.checked = !on; });
}
function setMcpEval(cb){
  var on = !!(cb && cb.checked);
  fetch('/api/mcp/eval?on=' + (on ? '1' : '0'), { method: 'POST' })
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.ok !== true) { if (cb) cb.checked = !on; return; }
      if (mcpStatus) mcpStatus.allowEval = !!d.allowEval;
      // --allow-eval 只在拉起时读取：正在跑的服务要重启才会变，说清楚。
      if (mcpStatus && mcpStatus.running && mcpStatus.mode === 'http') {
        var det = document.getElementById('mcp-detail');
        if (det) det.innerHTML = '<span class="bad">已保存</span>：'
          + (on ? '点「停止」再「启动」后 <code>xbume_eval</code> 才可用'
                : '当前进程仍开放 <code>xbume_eval</code>，重启服务后关闭');
      }
    })
    .catch(function(){ if (cb) cb.checked = !on; });
}
// ── AI 调试 ──
var aiPromptText = '';
var aiConfigText = '';
// 最近一次从 /api/ai/config 拉到的会话项目根与最近目录（成功后刷新候选时继续保留）。
var aiSessionDirs = [];
var aiRecentDirs = [];
// 项目目录候选 = 当前已存目录 + 会话反推的项目根 + 最近用过（去重，保持顺序）。
function aiFillDirs(sessionDirs, recent, current){
  var list = [];
  [current].concat(sessionDirs || [], recent || []).forEach(function(p){
    if (p && list.indexOf(p) < 0) list.push(p);
  });
  var dl = document.getElementById('ai-dir-list');
  if (dl) dl.innerHTML = list.map(function(p){ return '<option value="' + esc(p) + '"></option>'; }).join('');
  var inp = document.getElementById('ai-dir');
  if (inp && !inp.value) inp.value = current || list[0] || '';
}
// 设备下拉：自动 + 发现到的设备（含 macOS 桌面）；保留用户当前选择，其次配置，再次右上角设备。
function aiFillDevices(list, cur, fallback){
  var sel = document.getElementById('ai-device');
  if (!sel) return;
  var prev = sel.value;
  var html = '<option value="">自动（唯一手机 > 桌面）</option>';
  (list || []).forEach(function(d){
    // 桌面端已是带平台名的名字（「macOS 桌面」/「Windows 桌面」），不再加前缀。
    var isDesktop = d.id === 'macos' || d.id === 'windows'
      || d.platform === 'macos' || d.platform === 'windows';
    var prefix = isDesktop
      ? ''
      : (platformNames[d.platform] || d.platform || '') + ' · ';
    var lbl = prefix + (d.name || d.id) + (d.state ? '（' + d.state + '）' : '');
    html += '<option value="' + esc(d.id) + '">' + esc(lbl) + '</option>';
  });
  sel.innerHTML = html;
  var want = prev || cur || fallback || '';
  sel.value = want;
  if (sel.value !== want) sel.value = '';
}
function aiShow(){
  fetch('/api/ai/config').then(function(r){ return r.json(); }).then(function(d){
    aiSessionDirs = d.sessionDirs || [];
    aiRecentDirs = d.recentDirs || [];
    aiFillDirs(aiSessionDirs, aiRecentDirs, d.projectDir);
    aiFillDevices(d.devices, d.device, d.selectedDevice);
  }).catch(function(){});
  refreshMcp();
}
// ── 项目目录选择器 ──
// 浏览器自己的 <input type=file webkitdirectory> 只给相对路径，拿不到能当 cwd 的
// 绝对路径，所以改成后台列子目录、前端点选。只列目录，不读文件内容。
var aiPickCur = '';    // 当前浏览到的目录
var aiPickParent = ''; // 上一级（根目录为空）
function aiPickDir(){
  var inp = document.getElementById('ai-dir');
  var ov = document.getElementById('ai-dir-pick');
  if (ov) ov.style.display = 'block';
  aiPickLoad(inp ? (inp.value || '').trim() : '');
}
function aiPickClose(){
  var ov = document.getElementById('ai-dir-pick');
  if (ov) ov.style.display = 'none';
}
function aiPickUp(){ if (aiPickParent) aiPickLoad(aiPickParent); }
function aiPickChoose(){
  var inp = document.getElementById('ai-dir');
  if (inp && aiPickCur) inp.value = aiPickCur;
  aiPickClose();
}
function aiPickLoad(p){
  var list = document.getElementById('ai-pick-list');
  var tip = document.getElementById('ai-pick-tip');
  if (list) list.innerHTML = '<div class="muted" style="padding:10px 12px">读取中…</div>';
  fetch('/api/fs/dirs?path=' + encodeURIComponent(p || ''))
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.ok !== true) {
        if (list) list.innerHTML = '<div class="bad" style="padding:10px 12px">'
          + esc(d.message || '读取失败') + '</div>';
        return;
      }
      aiPickCur = d.path || '';
      aiPickParent = d.parent || '';
      var pi = document.getElementById('ai-pick-path');
      if (pi) pi.value = aiPickCur;
      var up = document.getElementById('ai-pick-up');
      if (up) up.disabled = !aiPickParent;
      if (tip) tip.innerHTML = d.flutter === true
        ? '<span class="ok">此目录含 pubspec.yaml，可直接选定</span>'
        : '此目录没有 pubspec.yaml（不是 Flutter 项目根，可继续进子目录找）';
      aiPickCand();
      var rows = d.entries || [];
      if (!rows.length) {
        if (list) list.innerHTML = '<div class="muted" style="padding:10px 12px">没有子目录</div>';
        return;
      }
      if (list) list.innerHTML = rows.map(function(e){
        var badge = e.flutter
          ? '<span class="ok" style="font-size:11px;margin-left:8px;white-space:nowrap">Flutter</span>' : '';
        return '<div class="ai-pick-row" data-path="' + esc(e.path) + '"'
          + ' style="display:flex;align-items:center;padding:6px 10px;border-radius:6px;cursor:pointer;font-size:13px"'
          + ' onclick="aiPickLoad(this.dataset.path)" title="' + esc(e.path) + '">'
          + '<span style="margin-right:8px;opacity:.65">📁</span>'
          + '<span style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">'
          + esc(e.name) + '</span>' + badge + '</div>';
      }).join('');
      Array.prototype.forEach.call(list.querySelectorAll('.ai-pick-row'), function(el){
        el.onmouseenter = function(){ el.style.background = '#16202b'; };
        el.onmouseleave = function(){ el.style.background = 'transparent'; };
      });
    })
    .catch(function(e){
      if (list) list.innerHTML = '<div class="bad" style="padding:10px 12px">'
        + esc(String(e)) + '</div>';
    });
}
// 快捷候选：调试会话反推的项目根 + 最近用过的目录，点一下直接跳过去。
function aiPickCand(){
  var box = document.getElementById('ai-pick-cand');
  if (!box) return;
  var list = [];
  aiSessionDirs.concat(aiRecentDirs).forEach(function(p){
    if (p && list.indexOf(p) < 0) list.push(p);
  });
  list = list.slice(0, 6);
  if (!list.length) { box.style.display = 'none'; return; }
  box.style.display = 'flex';
  box.innerHTML = '<span class="muted" style="font-size:12px;white-space:nowrap;align-self:center">会话/最近</span>'
    + list.map(function(p){
        var name = p.split(/[\\\/]/).pop() || p;
        return '<button data-p="' + esc(p) + '" title="' + esc(p) + '"'
          + ' style="padding:3px 9px;font-size:12px;max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"'
          + ' onclick="aiPickLoad(this.dataset.p)">' + esc(name) + '</button>';
      }).join('');
}
document.addEventListener('keydown', function(e){
  if (e.key !== 'Escape') return;
  var ov = document.getElementById('ai-dir-pick');
  if (ov && ov.style.display === 'block') aiPickClose();
});
function aiSetup(btn){
  var dir = (document.getElementById('ai-dir').value || '').trim();
  var dev = (document.getElementById('ai-device').value || '').trim();
  var st = document.getElementById('ai-status');
  var pre = document.getElementById('ai-prompt');
  if (btn) { btn.disabled = true; btn.textContent = '准备中…'; }
  if (st) st.textContent = '正在准备 MCP 与指令…';
  fetch('/api/ai/setup', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({dir: dir, device: dev})
  }).then(function(r){ return r.json(); }).then(function(d){
    if (btn) { btn.disabled = false; btn.textContent = '一键开启'; }
    if (d.ok !== true) {
      if (st) st.innerHTML = '<span class="bad">未就绪</span>';
      if (pre) pre.textContent = d.message || '准备失败';
      return;
    }
    aiPromptText = d.prompt || '';
    aiConfigText = d.config || '';
    if (pre) pre.textContent = aiPromptText;
    // 成功后刷新候选（新目录置顶；会话反推的候选不丢），设备按后端最终值回填。
    aiRecentDirs = d.recentDirs || aiRecentDirs;
    aiFillDirs(aiSessionDirs, aiRecentDirs, d.projectDir);
    var devSel = document.getElementById('ai-device');
    if (devSel) devSel.value = d.deviceId || '';
    var m = d.mcp || {};
    if (st) st.innerHTML = '<span class="ok">已就绪</span> · ' + (m.toolCount || 0)
      + ' 个工具 · eval ' + (m.hasEval ? '已开' : '未开');
    // 下一步就是粘给 AI，所以直接写剪贴板。
    var done = function(ok){
      if (st) st.innerHTML += ok ? ' · 指令已复制'
        : ' · <span class="bad">浏览器拦了剪贴板，请点「复制 AI 指令」手动全选</span>';
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(aiPromptText).then(function(){ done(true); },
        function(){ done(false); });
    } else { done(false); }
    refreshMcp(true);
  }).catch(function(e){
    if (btn) { btn.disabled = false; btn.textContent = '一键开启'; }
    if (st) st.innerHTML = '<span class="bad">请求失败</span>';
    if (pre) pre.textContent = String(e);
  });
}
function aiCopyPrompt(btn){
  if (!aiPromptText) {
    var pre = document.getElementById('ai-prompt');
    aiPromptText = pre ? pre.textContent : '';
  }
  if (!aiPromptText) return;
  navigator.clipboard.writeText(aiPromptText).then(function(){
    if (btn) { var t = btn.textContent; btn.textContent = '已复制';
      setTimeout(function(){ btn.textContent = t; }, 1200); }
  }, function(){
    if (btn) { var t = btn.textContent; btn.textContent = '被拦，请手动全选';
      setTimeout(function(){ btn.textContent = t; }, 1600); }
  });
}
function aiCopyConfig(btn){
  if (!aiConfigText) return;
  navigator.clipboard.writeText(aiConfigText).then(function(){
    if (btn) { var t = btn.textContent; btn.textContent = '已复制';
      setTimeout(function(){ btn.textContent = t; }, 1200); }
  }, function(){
    if (btn) { var t = btn.textContent; btn.textContent = '被拦，请手动全选';
      setTimeout(function(){ btn.textContent = t; }, 1600); }
  });
}
function mcpConfigText(token){
  var d = mcpStatus || {};
  if (d.running && d.mode === 'http' && d.url) {
    var cfg = {mcpServers: {xb_ume: {type: 'http', url: d.url}}};
    // token 必带：服务端对 HTTP 请求做了回环 Host 与 token 双重校验。
    if (token) cfg.mcpServers.xb_ume.headers = {'X-XBUME-Token': token};
    return JSON.stringify(cfg, null, 2);
  }
  return JSON.stringify({mcpServers: {xb_ume: {command: 'dart', args: ['run', 'xb_ume:mcp']}}}, null, 2);
}
function copyMcpConfig(btn){
  // 首屏探测未回来时先等一次：否则 HTTP 服务会被当成 stdio，复制出的配置
  // 与正在跑的服务对不上。只重试一次，失败就按现状降级。
  if (!mcpStatus && !copyMcpConfig.retried) {
    copyMcpConfig.retried = true;
    refreshMcp().then(function(){ copyMcpConfig(btn); });
    return;
  }
  var d = mcpStatus || {};
  var write = function(token){
    var text = mcpConfigText(token);
    // 同时把配置显示在下方：剪贴板被浏览器拦下时也能手动选中复制。
    var det = document.getElementById('mcp-detail');
    if (det) det.innerHTML = '<pre style="margin:4px 0 0;white-space:pre-wrap">' + esc(text) + '</pre>';
    mcpConfigShown = true;
    var done = function(){ if (btn) { btn.textContent = '已复制'; setTimeout(function(){ btn.textContent = '复制 MCP 配置'; }, 1500); } };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function(){ copyLogsFallback(text); done(); });
    } else { copyLogsFallback(text); done(); }
  };
  if (d.running && d.mode === 'http') {
    fetch('/api/mcp?token=1').then(function(r){ return r.json(); })
      .then(function(x){ write(x.token || ''); })
      .catch(function(){ write(''); });
  } else { write(''); }
}
setInterval(refreshMcp, 15000);
function setVmFilter(v){
  vmFilter = v; saveVmFp(fpBySource[v] || '');
  clog('用户选择: ' + (v || '(未选择)') + ' fp=' + (fpBySource[v] || ''));
  sbPath = null; dbReset(); renderLogs(); sbRefresh(); rtRefresh(); nwRefresh(); stRefresh(); tlResub();
  pfOnVmChange();
}

// -- 性能 Tab：当前调试会话的 CPU / 内存实时监控 --------------------------
var pfTimer = null, pfLive = true, pfBusy = false, pfInterval = 2000;
var pfMaxPts = 90;
var pfHist = { cpu: [], heap: [], proc: [] }; // 曲线数据：CPU % / Dart 堆 MB / 进程内存 MB
var pfPeak = { cpu: null, heap: null, proc: null };
function pfActive(){ var t = document.querySelector('.tab.active'); return !!t && t.dataset.tab === 'perf'; }
function pfUri(){ return vmFilter ? (vmUriBySource[vmFilter] || '') : ''; }
function pfSetText(id, txt){ var el = document.getElementById(id); if (el) el.textContent = txt; }
function pfStat(msg, bad){ var el = document.getElementById('pf-stat'); if (!el) return; el.textContent = msg || ''; el.className = bad ? 'bad' : 'muted'; }
function pfMB(n){
  if (n == null || isNaN(n)) return '—';
  if (n >= 1073741824) return (n / 1073741824).toFixed(2) + ' GB';
  return (n / 1048576).toFixed(1) + ' MB';
}
function pfSetInterval(v){
  pfInterval = parseInt(v, 10) || 2000;
  if (pfActive() && pfLive) { pfStart(); pfPoll(true); }
}
function pfBtn(){ var b = document.getElementById('pf-live-btn'); if (b) b.textContent = pfLive ? '暂停' : '继续'; }
function pfStart(){ pfStop(); if (pfLive) pfTimer = setInterval(function(){ pfPoll(); }, pfInterval); }
function pfStop(){ if (pfTimer) { clearInterval(pfTimer); pfTimer = null; } }
function pfToggleLive(){
  pfLive = !pfLive; pfBtn();
  if (pfLive) { pfStart(); pfPoll(true); } else { pfStop(); pfStat('已暂停采集'); }
}
function pfShow(){
  pfBtn();
  pfRenderCharts();
  if (!pfUri()) { pfStop(); pfStat('请先在页头右侧选择调试会话'); return; }
  if (!pfLive) { pfStat('已暂停采集'); return; }
  pfStart();
  pfPoll(true);
}
function pfClear(){
  pfHist = { cpu: [], heap: [], proc: [] };
  pfPeak = { cpu: null, heap: null, proc: null };
  pfRenderCharts();
  ['pf-cpu','pf-cpu-sub','pf-heap','pf-heap-sub','pf-rss','pf-rss-sub','pf-peak','pf-peak-sub','pf-cpu-last','pf-mem-last'].forEach(function(id){ pfSetText(id, '—'); });
  pfSetText('pf-cpu-last', ''); pfSetText('pf-mem-last', '');
  pfSetText('pf-cpu-k', 'CPU（Dart 主 isolate）');
  pfSetText('pf-rss-k', '进程内存');
  pfSetText('pf-proc-k', '进程内存构成');
  pfSetText('pf-proc-stat', '');
  var proc = document.getElementById('pf-proc');
  if (proc) proc.innerHTML = '<span class="muted">暂无数据</span>';
  var cpu = document.getElementById('pf-cpu'); if (cpu) cpu.style.color = '';
}
function pfReset(){ pfStop(); pfClear(); pfStat('请先在页头右侧选择调试会话'); }
function pfOnVmChange(){ pfReset(); if (pfActive()) pfShow(); }
function pfPoll(force){
  if (!pfActive() || pfBusy || (!pfLive && !force)) return;
  if (document.hidden) return;
  var uri = pfUri();
  if (!uri) { pfStop(); pfStat('请先在页头右侧选择调试会话'); return; }
  pfBusy = true;
  var t0 = Date.now();
  // 采样窗口不超过 2 秒：getCpuSamples 会返回窗口内全部样本（含栈），
  // 窗口过大会让响应体积和 JSON 解析耗时暴涨。
  var win = Math.min(pfInterval, 2000);
  fetch('/api/perf?uri=' + encodeURIComponent(uri) + '&windowMs=' + win)
    .then(function(r){ return r.json(); })
    .then(function(d){
      pfBusy = false;
      if (!d || !d.ok) { pfStat('采集失败：' + ((d && d.error) || '未知错误'), true); return; }
      pfApply(d, Date.now() - t0);
    })
    .catch(function(e){ pfBusy = false; pfStat('采集失败：' + e, true); });
}
function pfPush(arr, v){
  arr.push(v == null ? null : v);
  while (arr.length > pfMaxPts) arr.shift();
}
// 官方口径标签：CPU 按平台切换（Xcode 单核 100% / Studio、DevEco 全核 100%），
// 进程内存优先 PSS（Android/OHOS）或 footprint（iOS/macOS）。
function pfCpuLabel(plat, scope){
  if (scope === 'total') {
    if (plat === 'android') return 'CPU（整进程 · Android Studio 口径）';
    if (plat === 'ohos') return 'CPU（整进程 · DevEco 口径）';
    if (plat === 'windows') return 'CPU（整进程 · 任务管理器口径）';
    return 'CPU（整进程 · 全核容量）';
  }
  if (plat === 'ios' || plat === 'macos') return 'CPU（整进程 · Xcode 口径）';
  return 'CPU（整进程）';
}
function pfMemLabel(plat, pss, fp){
  if (pss) {
    if (plat === 'ohos') return '进程内存（PSS · DevEco 口径）';
    if (plat === 'android') return '进程内存（PSS · Android Studio 口径）';
    return '进程内存（PSS）';
  }
  if (fp) return '进程内存（footprint · Xcode 口径）';
  if (plat === 'windows') return '进程内存（WorkingSet）';
  return '进程内存';
}
function pfApply(d, ms){
  var isoCpu = (d.cpu && typeof d.cpu.percent === 'number') ? d.cpu.percent : null;
  var pstat = d.processStats || null;
  var plat = (pstat && pstat.platform) ? String(pstat.platform) : '';
  var scope = (pstat && pstat.cpuScope) ? String(pstat.cpuScope) : 'core';
  var cores = (pstat && typeof pstat.cpuCores === 'number') ? pstat.cpuCores : null;
  var procCpu = (pstat && typeof pstat.cpuPercent === 'number') ? pstat.cpuPercent : null;
  // 整进程 CPU 优先（iOS/macOS 同 Xcode，Android/OHOS 同 Studio/DevEco）；
  // app 端未注册扩展时回退到 isolate 采样。
  var cpu = procCpu != null ? procCpu : isoCpu;
  var heap = d.heap || null;
  var proc = (d.process && d.process.rss) ? d.process : null;
  var rss = proc ? proc.rss : null;
  // 进程内存取官方口径：Android/OHOS 的 PSS、iOS/macOS 的 footprint，回退 RSS。
  var pss = (pstat && typeof pstat.pss === 'number' && pstat.pss > 0) ? pstat.pss : null;
  var fp = (pstat && pstat.footprint) ? pstat.footprint : null;
  var memVal = pss || fp || rss;
  var heapMb = heap ? heap.used / 1048576 : null;
  var memMb = memVal ? memVal / 1048576 : null;

  var cpuEl = document.getElementById('pf-cpu');
  if (cpuEl) {
    cpuEl.textContent = cpu == null ? '—' : cpu.toFixed(1) + '%';
    cpuEl.style.color = cpu == null ? '' : (cpu >= 80 ? '#ef5350' : (cpu >= 50 ? '#f5c451' : '#46d68c'));
  }
  pfSetText('pf-cpu-k', procCpu != null ? pfCpuLabel(plat, scope) : 'CPU（Dart 主 isolate）');
  if (procCpu != null) {
    var sub = ['整进程'];
    if (scope === 'total') sub.push('全核容量' + (cores ? '（' + cores + ' 核）' : ''));
    if (pstat.windowMs) sub.push('窗口 ' + pstat.windowMs + ' ms');
    if (isoCpu != null) sub.push('Dart isolate ' + isoCpu.toFixed(1) + '%');
    else if (d.cpuError) sub.push('isolate 采样不可用');
    pfSetText('pf-cpu-sub', sub.join(' · '));
  } else if (d.cpu) {
    pfSetText('pf-cpu-sub', '采样 ' + d.cpu.busy + '/' + d.cpu.samples + ' · GC 样本 ' + d.cpu.gc +
      ' · 窗口 ' + Math.round((d.cpu.extentUs || 0) / 1000) + ' ms' +
      (d.cpuAutoEnabled ? ' · 已开启采样' : ''));
  } else {
    pfSetText('pf-cpu-sub', d.cpuError ? ('不可用：' + d.cpuError) : '—');
  }
  if (heap) {
    pfSetText('pf-heap', pfMB(heap.used));
    var hp = heap.capacity > 0 ? Math.min(100, Math.max(0, heap.used * 100 / heap.capacity)) : 0;
    pfSetText('pf-heap-sub', '容量 ' + pfMB(heap.capacity) + ' · 占用 ' + hp.toFixed(0) + '% · 堆外 ' + pfMB(heap.external));
  } else {
    pfSetText('pf-heap', '—');
    pfSetText('pf-heap-sub', d.heapError ? ('不可用：' + d.heapError) : '—');
  }
  pfSetText('pf-rss-k', pfMemLabel(plat, pss, fp));
  if (memVal) {
    pfSetText('pf-rss', pfMB(memVal));
    // 首个采样时进程内存可能尚未涨起来（会小于 Dart 堆），占比按 0–100% 截断。
    var share = heap && memVal > 0 ? Math.min(100, Math.max(0, heap.used * 100 / memVal)) : null;
    var bits = [];
    if (share != null) bits.push('Dart 堆占进程 ' + share.toFixed(0) + '%');
    if (rss && memVal !== rss) bits.push('RSS ' + pfMB(rss));
    else if (!rss && proc && proc.description) bits.push(proc.description);
    pfSetText('pf-rss-sub', bits.length ? bits.join(' · ') : '—');
  } else {
    pfSetText('pf-rss', '—');
    pfSetText('pf-rss-sub', d.processError ? ('不可用：' + d.processError) : '该平台不支持进程内存');
  }

  if (cpu != null) pfPeak.cpu = Math.max(pfPeak.cpu == null ? -1 : pfPeak.cpu, cpu);
  if (heapMb != null) pfPeak.heap = Math.max(pfPeak.heap == null ? -1 : pfPeak.heap, heapMb);
  if (memMb != null) pfPeak.proc = Math.max(pfPeak.proc == null ? -1 : pfPeak.proc, memMb);
  pfSetText('pf-peak', pfPeak.cpu == null ? '—' : pfPeak.cpu.toFixed(1) + '% CPU');
  pfSetText('pf-peak-sub', '堆 ' + (pfPeak.heap == null ? '—' : pfPeak.heap.toFixed(1) + ' MB') +
    ' · 进程 ' + (pfPeak.proc == null ? '—' : pfPeak.proc.toFixed(1) + ' MB'));

  pfPush(pfHist.cpu, cpu);
  pfPush(pfHist.heap, heapMb);
  pfPush(pfHist.proc, memMb);
  pfRenderCharts();
  pfRenderProc(d, proc, pstat, memVal);

  pfSetText('pf-cpu-last', cpu == null ? '' : ('当前 ' + cpu.toFixed(1) + '%'));
  pfSetText('pf-mem-last', (heapMb == null ? '' : '堆 ' + heapMb.toFixed(1) + ' MB') +
    (memMb == null ? '' : ' · 进程 ' + memMb.toFixed(1) + ' MB'));

  var info = [];
  if (d.vm && d.vm.os) info.push(d.vm.os);
  if (d.vm && d.vm.isolates > 1) info.push(d.vm.isolates + ' isolates');
  pfStat('已更新 ' + new Date(d.ts || Date.now()).toLocaleTimeString() + ' · 采集 ' + Math.round(ms) + ' ms' +
    (info.length ? ' · ' + info.join(' · ') : ''));
}
function pfRenderProc(d, proc, pstat, memVal){
  var el = document.getElementById('pf-proc');
  var stat = document.getElementById('pf-proc-stat');
  if (!el) return;
  var pss = (pstat && typeof pstat.pss === 'number' && pstat.pss > 0) ? pstat.pss : null;
  var items = (pstat && pstat.pssItems && typeof pstat.pssItems === 'object') ? pstat.pssItems : null;
  // 标题标明这部分统计的口径，避免与上方进程内存卡片（PSS/footprint）混读。
  pfSetText('pf-proc-k', pss ? '进程内存构成（PSS）' : '进程内存构成（RSS）');
  // Android/OHOS：按官方分类展示 PSS 构成（各行之和 = PSS 总量）。
  if (pss) {
    var tool = (pstat.platform === 'ohos') ? 'DevEco' : (pstat.platform === 'android' ? 'Android Studio' : '');
    if (stat) stat.textContent = '总 PSS ' + pfMB(pss) + (tool ? '（' + tool + ' 口径）' : '');
    var keys = items ? Object.keys(items).filter(function(k){ return items[k] > 0; }) : [];
    keys.sort(function(a, b){ return items[b] - items[a]; });
    if (!keys.length) {
      el.innerHTML = '<span class="muted">该设备仅能读取 PSS 总量，暂无分类</span>';
      return;
    }
    var total = memVal || pss;
    var pssRows = keys.map(function(k){
      var pct = total > 0 ? Math.min(100, Math.max(1, Math.round(items[k] * 100 / total))) : 0;
      return '<tr><td style="width:140px">' + esc(k) + '</td>' +
        '<td class="muted" style="font-size:11px"></td>' +
        '<td style="width:90px;text-align:right;white-space:nowrap">' + pfMB(items[k]) + '</td>' +
        '<td style="width:140px"><div class="bar"><i style="width:' + pct + '%"></i></div></td></tr>';
    });
    el.innerHTML = '<table class="pf-memtable">' + pssRows.join('') + '</table>';
    return;
  }
  if (!proc) {
    pfSetText('pf-proc-k', '进程内存构成');
    if (stat) stat.textContent = d.processError ? ('不可用：' + d.processError) : '';
    // 有 PSS/footprint 但 VM 不给分项时，说明只能读到总量而不是“不支持进程内存”。
    el.innerHTML = '<span class="muted">' + (memVal
      ? '该设备仅能读取进程总内存，暂无分项'
      : (d.processError ? '该调试会话不支持 getProcessMemoryUsage' : '暂无数据')) + '</span>';
    return;
  }
  if (stat) stat.textContent = '总 ' + pfMB(proc.rss) + (proc.name ? '（' + proc.name + '）' : '');
  var list = proc.items || [];
  if (!list.length) { el.innerHTML = '<span class="muted">暂无分项数据</span>'; return; }
  var rows = list.map(function(it){
    var pct = proc.rss > 0 ? Math.min(100, Math.max(1, Math.round(it.size * 100 / proc.rss))) : 0;
    return '<tr><td style="width:140px">' + esc(it.name || '—') + '</td>' +
      '<td class="muted" style="font-size:11px;max-width:460px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + esc(it.description || '').replace(/"/g, '&quot;') + '">' + esc(it.description || '') + '</td>' +
      '<td style="width:90px;text-align:right;white-space:nowrap">' + pfMB(it.size) + '</td>' +
      '<td style="width:140px"><div class="bar"><i style="width:' + pct + '%"></i></div></td></tr>';
  });
  el.innerHTML = '<table class="pf-memtable">' + rows.join('') + '</table>';
}
function pfCv(id){
  var cv = document.getElementById(id);
  if (!cv) return null;
  var dpr = window.devicePixelRatio || 1;
  var w = cv.clientWidth || 0;
  var h = cv.clientHeight || 150;
  if (!w) return null;
  if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) {
    cv.width = Math.round(w * dpr);
    cv.height = Math.round(h * dpr);
  }
  var ctx = cv.getContext('2d');
  if (!ctx) return null;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  return { ctx: ctx, w: w, h: h };
}
function pfNice(v){
  if (!(v > 0)) return 1;
  var p = Math.pow(10, Math.floor(Math.log(v) / Math.LN10));
  var n = v / p;
  var m = n <= 1 ? 1 : (n <= 2 ? 2 : (n <= 5 ? 5 : 10));
  return m * p;
}
function pfAxis(v){
  if (v === 0) return '0';
  if (v >= 10) return String(Math.round(v));
  if (v >= 1) return String(Math.round(v * 10) / 10);
  return String(Math.round(v * 100) / 100);
}
function pfRenderCharts(){
  pfChart('pf-cpu-cv', [{ v: pfHist.cpu, color: '#00e5ff', fill: 'rgba(0,229,255,.12)' }], 100, true);
  pfChart('pf-mem-cv', [
    { v: pfHist.heap, color: '#00e5ff', fill: 'rgba(0,229,255,.10)' },
    { v: pfHist.proc, color: '#f0b429', fill: 'rgba(240,180,41,.08)' }
  ], 0, false);
}
function pfChart(id, series, maxY, fixedMax){
  var c = pfCv(id);
  if (!c) return;
  var ctx = c.ctx, w = c.w, h = c.h;
  var L = 36, R = 6, T = 6, B = 14;
  var iw = Math.max(10, w - L - R), ih = Math.max(10, h - T - B);
  var n = pfMaxPts;
  if (!fixedMax) {
    var m = 0;
    series.forEach(function(s){ s.v.forEach(function(v){ if (v != null && v > m) m = v; }); });
    maxY = pfNice(m > 0 ? m * 1.12 : 1);
  }
  ctx.strokeStyle = '#223041';
  ctx.fillStyle = '#8aa0b4';
  ctx.lineWidth = 1;
  ctx.font = '10px -apple-system, "Segoe UI", sans-serif';
  ctx.textAlign = 'right';
  ctx.textBaseline = 'middle';
  for (var g = 0; g <= 4; g++) {
    var y = T + ih - ih * g / 4;
    ctx.beginPath(); ctx.moveTo(L, y); ctx.lineTo(L + iw, y); ctx.stroke();
    ctx.fillText(pfAxis(maxY * g / 4), L - 5, y);
  }
  series.forEach(function(s){
    var start = n - s.v.length;
    var pts = [];
    for (var i = 0; i < s.v.length; i++) {
      var v = s.v[i];
      if (v == null) { pts.push(null); continue; }
      pts.push({ x: L + iw * (start + i) / (n - 1), y: T + ih - ih * Math.min(v, maxY) / maxY });
    }
    if (s.fill) {
      var seg = [];
      var flush = function(){
        if (seg.length >= 2) {
          ctx.beginPath();
          ctx.moveTo(seg[0].x, T + ih);
          seg.forEach(function(p){ ctx.lineTo(p.x, p.y); });
          ctx.lineTo(seg[seg.length - 1].x, T + ih);
          ctx.closePath();
          ctx.fillStyle = s.fill;
          ctx.fill();
        }
        seg = [];
      };
      pts.forEach(function(p){ if (p == null) flush(); else seg.push(p); });
      flush();
    }
    ctx.beginPath();
    ctx.strokeStyle = s.color;
    ctx.lineWidth = 1.5;
    var started = false;
    pts.forEach(function(p){
      if (p == null) { started = false; return; }
      if (!started) { ctx.moveTo(p.x, p.y); started = true; } else { ctx.lineTo(p.x, p.y); }
    });
    ctx.stroke();
  });
}
function pfGc(){
  var uri = pfUri();
  if (!uri) { pfStat('请先在页头右侧选择调试会话', true); return; }
  pfStat('触发 GC 中…');
  fetch('/api/runtime/op?uri=' + encodeURIComponent(uri) + '&op=gc', { method: 'POST' })
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d && d.ok) { pfStat('GC 已触发 ✓'); pfPoll(true); }
      else { pfStat('GC 失败：' + ((d && d.error) || '未知错误'), true); }
    })
    .catch(function(e){ pfStat('GC 失败：' + e, true); });
}

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
  // 定位失败原因单独一行展示：只看 — 与 \ 无法判断是换目录没重新
  // pub get、还是调试的机器上没有这份源码。
  var html = '<div id="rt-locdiag" class="muted" style="font-size:12px;margin:2px 0"></div>';
  navs.forEach(function(nav){
    var routes = nav.routes || [];
    html += '<div style="margin:8px 0 2px;display:flex;align-items:center;gap:8px;flex-wrap:wrap"><b>Navigator #' + (nav.index + 1) + '</b> <span class="muted">（' + routes.length + ' 个路由）</span>'
      + '<input id="rt-name-' + nav.index + '" placeholder="pushNamed 路由名，如 /" style="width:200px;margin-left:10px" onkeydown="if(event.key===\'Enter\')rtPush(' + nav.index + ')">'
      + '<button onclick="rtPush(' + nav.index + ')" title="在 app 内经 Navigator.pushNamed 压入指定名字的路由">pushNamed</button>'
      + '<span id="rt-pushmsg-' + nav.index + '" class="muted"></span></div>';
    if (!routes.length) { html += '<span class="muted">空栈</span>'; return; }
    html += '<table class="sbtable"><tr><th>栈序</th><th>路由名</th><th>Widget / State / VM / Notifier</th><th>文件</th><th>类型</th><th>参数</th><th>定位</th><th>操作</th></tr>';
    routes.forEach(function(r, i){
      var pos = i === 0 ? '栈底' : (i === routes.length - 1 ? '栈顶' : '');
      var name = r.name ? esc(r.name) : '<span class="muted">&lt;unnamed&gt;</span>';
      var cur = r.current ? ' <span style="color:var(--acc);font-weight:600">● 当前</span>' : '';
      var fileCell = '<td id="rtf-' + nav.index + '-' + i + '"><span class="muted">…</span></td>';
      var args = r.argsType
        ? '<span title="' + esc(r.argsType + (r.args ? ' ' + r.args : '')) + '">' + esc((r.args || '').length > 60 ? r.args.substring(0, 60) + '…' : (r.args || '空')) + ' <span class="muted">(' + esc(r.argsType) + ')</span></span>'
        : '<span class="muted">—</span>';
      // Widget/State/VM/Notifier 名称由 rtResolve→rtInfo 静态解析后填充，
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
      html += '<tr data-rt-name="' + esc(r.name || '') + '"><td>' + (i + 1) + (pos ? ' <span class="muted">' + pos + '</span>' : '') + '</td><td>' + name + cur + '</td>' + instCell + fileCell + '<td>' + esc(r.type) + '</td><td>' + args + '</td><td>' + jump + '</td><td style="white-space:nowrap">' + (ops || '<span class="muted">—</span>') + '</td></tr>';
    });
    html += '</table>';
  });
  return html;
}
// Widget/State/VM/Notifier 名称单元格：无则显示 \\，有则可点击跳实例 Tab。
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
function rtLocErr(m){
  if (m === 'NO_SUBTREE') return '该路由页面不在树上（maintainState=false 或转场尚未完成）';
  if (m === 'BAD_NAV' || m === 'BAD_IDX') return '路由栈已变化，请刷新重试';
  return m || '未定位到文件';
}
function rtResolve(nav, i){
  var uri = rtUri();
  if (!uri) return;
  fetch('/api/routelocate?uri=' + encodeURIComponent(uri) + '&nav=' + nav + '&idx=' + i + '&open=0')
    .then(function(r){ return r.json(); })
    .then(function(d){
      var cell = document.getElementById('rtf-' + nav + '-' + i);
      if (!cell) return;
      if (d.error || !d.file) {
        cell.innerHTML = '<span class="muted" title="' + esc(rtLocErr(d.error)) + '">—</span>';
        var re = document.getElementById('rti-' + nav + '-' + i);
        if (re) re.innerHTML = '<span class="muted">\\</span>';
        var diag = document.getElementById('rt-locdiag');
        if (diag) diag.textContent = '定位失败：' + rtLocErr(d.error);
        return;
      }
      var fileName = d.file.split('/').pop();
      var pos = fileName + (d.line ? ':' + d.line : '');
      cell.innerHTML = '<span title="' + esc(d.file + (d.className ? '（' + d.className + '）' : '')) + '">' + esc(pos) + '</span>';
      // 已定位到用户 widget 类的源文件：静态解析 State / ChangeNotifier 名。
      if (d.className && d.file) rtInfo(nav, i, d.className, d.file);
      else { var rc = document.getElementById('rti-' + nav + '-' + i); if (rc) rc.innerHTML = '<span class="muted" title="未定位到用户代码 Widget">\\</span>'; }
    })
    .catch(function(){ var cell = document.getElementById('rtf-' + nav + '-' + i); if (cell) cell.innerHTML = '<span class="muted">—</span>'; var rc = document.getElementById('rti-' + nav + '-' + i); if (rc) rc.innerHTML = '<span class="muted">\\</span>'; });
}
// 用 routelocate 已定位到的 widget 类与源文件静态解析 State / VM / Notifier 名。
function rtInfo(nav, i, widgetCls, file){
  fetch('/api/routeinfo?class=' + encodeURIComponent(widgetCls) + '&file=' + encodeURIComponent(file))
    .then(function(r){ return r.json(); })
    .then(function(d){
      var cell = document.getElementById('rti-' + nav + '-' + i);
      if (!cell) return;
      if (!d || !d.ok) { cell.innerHTML = '<span class="muted">\\</span>'; return; }
      // Widget/State/XBVM/其它 ChangeNotifier 全部可点击。
      var parts = [rtInstLink(d.widget, 'Widget 实例（堆扫描）'), rtInstLink(d.state, 'State 实例（Element 树 + 堆扫描）')];
      (d.vm || []).forEach(function(v){ parts.push(rtInstLink(v, 'XBVM 实例（堆扫描）')); });
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
var nwItems = [], nwDetails = {}, nwOpen = {}, nwReplays = {}, nwFetching = {}, nwEditOpen = {}, nwEditVals = {}, nwInitFrames = {};
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
  var html = '<div class="muted nwhead">共 ' + rows.length + ' 条</div>';
  html += '<table class="sbtable nwtable"><tr><th>时间</th><th>方法</th><th>URL</th><th>状态</th><th>耗时</th><th>操作</th></tr>';
  rows.forEach(function(it, i){
    var code = parseInt(it.statusCode, 10);
    var codeHtml = isNaN(code) ? '<span class="muted">…</span>' : '<span style="color:' + nwStatusColor(it.status, code) + '">' + code + '</span>';
    var t = (it.time || '').replace('T', ' ').substring(5);
    var url = it.url || '';
    var short = url.length > 80 ? url.substring(0, 80) + '…' : url;
    var open = !!nwOpen[it.id];
    html += '<tr id="nwrow-' + esc(it.id) + '" style="cursor:pointer;' + (open ? 'background:var(--bg2,#161b22)' : '') + '" onclick="nwToggle(\'' + esc(it.id) + '\')">'
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
  // 统计行/表头的 sticky top 依赖工具栏实际高度，渲染后立即实测写入（同步执行，
  // 不加 rAF，否则重建 DOM 到下一帧之间表头无 top 不吸顶，重渲染时会闪一下）。
  (function(){
    var tb = document.getElementById('nw-toolbar');
    var hd = body.querySelector('.nwhead');
    var ths = body.querySelectorAll('.nwtable th');
    if (!tb || !ths.length) return;
    var hTop = tb.offsetHeight, tTop = hTop + (hd ? hd.offsetHeight : 0);
    if (hd) hd.style.top = hTop + 'px';
    for (var k = 0; k < ths.length; k++) ths[k].style.top = tTop + 'px';
  })();
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
  // 发起位置：app 端在请求开始时捕获的用户代码栈帧（首帧即调用点）。
  if (d.initiatorFrames && d.initiatorFrames.length) {
    var fs = d.initiatorFrames;
    nwInitFrames[id] = fs;
    var initHtml = fs.map(function(f, idx){
      return '<div style="font-family:monospace;font-size:12px;word-break:break-all">' + esc(f.raw || '')
        + (f.file ? ' <a href="javascript:void(0)" onclick="nwInitJump(\'' + esc(id) + '\',' + idx + ',this)">跳转</a>' : '')
        + (f.file ? ' <a href="javascript:void(0)" onclick="nwInitQuickBp(\'' + esc(id) + '\',' + idx + ')" title="在这一帧下断点">断点</a>' : '') + '</div>';
    }).join('');
    if (fs.length > 1) {
      initHtml = fs.slice(0, 1).map(function(f, idx){
        return '<div style="font-family:monospace;font-size:12px;word-break:break-all">' + esc(f.raw || '')
          + (f.file ? ' <a href="javascript:void(0)" onclick="nwInitJump(\'' + esc(id) + '\',' + idx + ',this)">跳转</a>' : '')
          + (f.file ? ' <a href="javascript:void(0)" onclick="nwInitQuickBp(\'' + esc(id) + '\',' + idx + ')" title="在这一帧下断点">断点</a>' : '') + '</div>';
      }).join('')
        + '<details style="margin-top:4px"><summary class="muted">完整调用栈（' + fs.length + ' 帧）</summary>'
        + fs.slice(1).map(function(f, i){
            var idx = i + 1;
            return '<div style="font-family:monospace;font-size:12px;word-break:break-all">' + esc(f.raw || '')
              + (f.file ? ' <a href="javascript:void(0)" onclick="nwInitJump(\'' + esc(id) + '\',' + idx + ',this)">跳转</a>' : '')
              + (f.file ? ' <a href="javascript:void(0)" onclick="nwInitQuickBp(\'' + esc(id) + '\',' + idx + ')" title="在这一帧下断点">断点</a>' : '') + '</div>';
          }).join('')
        + '</details>';
    }
    html += sec('发起位置', initHtml);
  } else {
    html += sec('发起位置', '<span class="muted">未记录（app 端 xb_ume 需 0.3.0+，且该请求需发生在升级后）</span>');
  }
  html += sec('Query', kvTable(d.query));
  html += sec('请求头', kvTable(d.requestHeaders));
  html += sec('请求体', pretty(d.requestBody));
  html += sec('响应头', kvTable(d.responseHeaders));
  html += sec('响应体', pretty(d.responseBody));
  if (d.stack) html += sec('错误堆栈', pretty(d.stack));
  return html + '</div>';
}
function nwInitJump(id, idx, el){ // 发起位置栈帧的 IDE 跳转（仅解析到本机文件的帧）
  var f = (nwInitFrames[id] || [])[idx];
  if (!f || !f.file) return;
  excOpenIde(f.file, f.line, el);
}
function nwDetailRowHtml(id){
  var it = nwItems.filter(function(x){ return x.id === id; })[0] || {};
  var d = nwDetails[id];
  var head = '<div style="margin:2px 0 6px"><b>' + esc(it.method + ' ' + (it.url || '')) + '</b> '
    + '<a href="javascript:void(0)" onclick="nwCopyAll(\'' + esc(id) + '\',this)" title="复制本请求全部内容（概要/Query/请求头/请求体/响应头/响应体/错误堆栈/重发响应）">复制全部</a> '
    + '<a href="javascript:void(0)" onclick="nwCurl(\'' + esc(id) + '\',this)"> 复制 cURL</a> '
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
function nwCopyAll(id, a){
  // 复制展开详情的全部内容为纯文本；未加载详情时先取。包含重发响应（如有）。
  var it = nwItems.filter(function(x){ return x.id === id; })[0];
  if (!it) return;
  nwGetDetail(id, function(d){
    var lines = [];
    var headLine = (it.method || 'GET') + ' ' + (it.url || '');
    var meta = [];
    if (it.time) meta.push('时间: ' + String(it.time).replace('T', ' '));
    if (it.statusCode) meta.push('状态码: ' + it.statusCode);
    if (it.durationMs) meta.push('耗时: ' + it.durationMs + 'ms');
    if (it.error) meta.push('错误: ' + it.error);
    if (meta.length) headLine += '\n  ' + meta.join('  ');
    lines.push(headLine);
    if (d.initiatorFrames && d.initiatorFrames.length) {
      lines.push('', '发起位置:');
      d.initiatorFrames.forEach(function(f){ lines.push('  ' + (f.raw || '')); });
    }
    var kv = function(title, rows){
      if (!rows || !rows.length) return;
      lines.push('', title + ':');
      rows.forEach(function(h){ if (h.k) lines.push('  ' + h.k + ': ' + (h.v || '')); });
    };
    kv('Query', d.query);
    kv('请求头', d.requestHeaders);
    if (d.requestBody) { lines.push('', '请求体:'); lines.push(d.requestBody); }
    kv('响应头', d.responseHeaders);
    if (d.responseBody) { lines.push('', '响应体:'); lines.push(d.responseBody); }
    if (d.error) { lines.push('', '错误:'); lines.push(d.error); }
    if (d.stack) { lines.push('', '错误堆栈:'); lines.push(d.stack); }
    var rep = nwReplays[id];
    if (rep) {
      lines.push('', '重发响应（电脑直发，不经 app）:');
      if (rep.error) { lines.push('  重发失败: ' + rep.error); }
      else {
        lines.push('  状态码: ' + rep.statusCode);
        Object.keys(rep.headers || {}).forEach(function(k){
          lines.push('  ' + k + ': ' + (rep.headers[k] || []).join(', '));
        });
        if (rep.body) { lines.push('  响应体:'); lines.push(String(rep.body).split('\n').map(function(l){ return '  ' + l; }).join('\n')); }
      }
    }
    var text = lines.join('\n');
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).catch(function(){ copyLogsFallback(text); });
    } else {
      copyLogsFallback(text);
    }
    var old = a.textContent; a.textContent = '已复制✓'; setTimeout(function(){ a.textContent = old; }, 1500);
  });
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
  fetch('/api/network/replay?uri=' + encodeURIComponent(uri) + '&id=' + encodeURIComponent(id), {method: 'POST'})
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
  fetch('/api/network/clear?uri=' + encodeURIComponent(uri), {method: 'POST'})
    .then(function(r){ return r.json(); })
    .then(function(d){ if (d.error) { alert(d.error); return; } nwItems = []; nwDetails = {}; nwOpen = {}; nwReplays = {}; nwRender(); })
    .catch(function(e){ alert(String(e)); });
}

// -- Storage Tab（shared_prefs XML 直读直写）--------------------------------
var stFiles = [], stXml = '', stRows = [], stFile = '', stFmt = 'android', stDirty = {};
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
      stDirty = {};
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
  html += '<div style="margin-top:8px"><button id="st-save-btn" onclick="stSave()">保存写入（写回手机）</button></div>';
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
function stSet(i, k, v){ if (stRows[i]) { stRows[i][k] = v; stMark(i); } }
function stMark(i){
  // 记录改动项：保存时经 app 内 API 写回（立即生效）；raw/rawios 不可编辑不算。
  var r = stRows[i];
  if (!r || r.type === 'raw' || r.type === 'rawios') return;
  var n = (r.name || '').trim();
  if (!n) return;
  stDirty[n] = { name: n, type: r.type, value: r.value };
}
function stDel(i){
  var r = stRows[i];
  if (r && !r.isNew && (r.name || '').trim()) {
    stDirty[r.name.trim()] = { name: r.name.trim(), del: true };
  }
  stRows.splice(i, 1);
  stRender();
}
function stAddRow(){ stRows.push({ name: '', type: 'string', value: '', isNew: true }); stRender(); }
function stReloadCache(){
  var uri = stUri();
  if (!uri) { alert('请先选择 VM（页头右侧会话下拉框）'); return; }
  fetch('/api/storage/reload?uri=' + encodeURIComponent(uri))
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { alert('刷新缓存失败：' + d.error); return; }
      alert('已让 app 重读 SharedPreferences 缓存' + (d.keys != null ? '（当前 ' + d.keys + ' 项）' : '')
        + '。若值仍是旧的，说明平台层自己缓存了文件（Android/鸿蒙/iOS 都可能），需重启 app。');
    })
    .catch(function(e){ alert(String(e)); });
}
function stRestoreSaveBtn(){
  var b = document.getElementById('st-save-btn');
  if (b) { b.disabled = false; b.textContent = '保存写入（写回手机）'; }
}
function stSave(){
  var uri = stUri();
  if (!uri) { alert('请先在页头右侧选择会话'); return; }
  if (!stFile) { alert('请先选择要写入的存储文件'); return; }
  // 大文件分块写入需要时间，按钮立即进入写入中状态，避免误以为没反应而重复点击。
  var btn0 = document.getElementById('st-save-btn');
  if (btn0) { btn0.disabled = true; btn0.textContent = '写入中…'; }
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
  var dirty = Object.keys(stDirty).map(function(k){ return stDirty[k]; });
  fetch('/api/storage/write?uri=' + encodeURIComponent(uri) + '&file=' + encodeURIComponent(stFile), {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({xml: xml, dirty: dirty})
  })
    .then(function(r){ return r.json(); })
    .then(function(d){
      stRestoreSaveBtn();
      if (d.error) { alert('写入失败：' + d.error); return; }
      stDirty = {};
      var live = d.live, msg, detail = '';
      if (d.liveError) {
        msg = '✓ 已写入文件，但经 app 内 API 写回失败';
        detail = d.liveError + '\n\n改动已落盘，重启 app 后生效。';
      } else if (!live) {
        msg = '✓ 已写入文件（需重启 app 生效）';
        detail = 'app 内没找到 SharedPreferences 实例（app 尚未读写过 preferences？），改动已落盘，重启 app 后生效。';
      } else {
        var n = live.applied || 0, fails = live.failed || [], skips = live.skipped || [];
        if (live.verified === false) {
          msg = '✓ 已写入文件，但校验未通过';
          detail = '经 app 内 API 写回 ' + n + ' 项，但读回值与预期不一致（平台层可能仍缓存）。请重启 app 确认。';
        } else if (!fails.length && !skips.length) {
          msg = n > 0 ? '✓ 已写入并生效（' + n + ' 项）' : '✓ 已写入并刷新缓存';
        } else {
          msg = '✓ 已写入文件（' + n + ' 项已生效，部分需重启 app）';
          detail = '经 app 内 API 写回 ' + n + ' 项'
            + (fails.length ? '，失败 ' + fails.length + ' 项：\n  ' + fails.slice(0, 5).join('\n  ') : '')
            + (skips.length ? '\n' + skips.length + ' 项不支持即时写入（无 flutter. 前缀或类型不支持）' : '')
            + '\n\n这些项已写入文件，重启 app 后生效。';
        }
      }
      // 成功与失败都弹窗反馈；成功也附上文件与字节数，便于确认写的是哪份存储。
      alert(msg + (detail ? '\n\n' + detail : '')
        + '\n\n文件：' + stFile.split('/').pop() + '（' + (d.bytes || 0) + ' 字节）');
    })
    .catch(function(e){ stRestoreSaveBtn(); alert('写入失败：' + e); });
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
    var isDb = !e.dir && /\.(db|sqlite3?|db3)$/i.test(e.name);
    var act = (e.dir
      ? '<a href="/api/sandbox/downloadDir?uri=' + q + '&path=' + p + '"><button title="递归打包为 tar（无压缩）下载">下载 .tar</button></a>'
      : (isDb ? '<a href="javascript:void(0)" onclick="dbOpenFromSandbox(this)" data-p="' + p + '" title="用本机 sqlite3 只读浏览表结构与数据"><button>查询</button></a> ' : '')
        + '<a href="javascript:void(0)" onclick="sbOpenSub(\'view\',this)" data-p="' + p + '"><button title="新标签页展示文件内容">查看</button></a>'
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
// -- 数据库（SQLite） --------------------------------------------------
var dbState = { id:'', name:'', path:'', table:'', offset:0, limit:100, mode:'' };
function dbActive(){ var t = document.querySelector('.tab.active'); return t && t.dataset.tab === 'db'; }
function dbSetMsg(s, bad){
  var el = document.getElementById('db-msg');
  if (!el) return;
  el.textContent = s || '';
  el.className = bad ? 'bad' : 'muted';
}
function dbReset(){
  dbState = { id:'', name:'', path:'', table:'', offset:0, limit:100, mode:'' };
  var t = document.getElementById('db-title'); if (t) t.textContent = '未打开数据库';
  var st = document.getElementById('db-stat'); if (st) st.textContent = '';
  var tb = document.getElementById('db-tables'); if (tb) tb.innerHTML = '<span class="muted">未打开</span>';
  var sc = document.getElementById('db-schema'); if (sc) sc.innerHTML = '';
  var rs = document.getElementById('db-result'); if (rs) rs.innerHTML = '';
  var pg = document.getElementById('db-pager'); if (pg) pg.style.display = 'none';
  var sq = document.getElementById('db-sql'); if (sq) sq.value = '';
  dbSetMsg('');
}
function dbRefresh(){
  if (dbActive() && !dbState.id) dbSetMsg('从「应用沙盒」里点 .db / .sqlite 文件的「查询」打开数据库');
}
function dbOpenFromSandbox(el){
  var p = decodeURIComponent(el.dataset.p);
  var tab = document.querySelector('.tab[data-tab="db"]');
  if (tab) tab.click();
  dbOpen(p, false);
}
function dbOpen(path, force){
  var uri = sbUri();
  if (!uri) { dbSetMsg('请先选择 VM', true); return; }
  dbSetMsg(force ? '正在重新拉取…' : '正在拉取数据库文件（大文件需要几秒）…');
  fetch('/api/db/open', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({uri:uri, path:path, force:!!force})})
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { dbSetMsg('打开失败：' + d.error, true); return; }
      dbState.id = d.dbId; dbState.name = d.name; dbState.path = d.path;
      dbState.table = ''; dbState.offset = 0; dbState.mode = '';
      document.getElementById('db-title').textContent = d.name;
      document.getElementById('db-stat').textContent = fmtSize(d.size)
        + (d.cached ? ' · 本机缓存' : ' · 已拉取')
        + (d.sqlite ? ' · SQLite ' + d.sqlite : '')
        + ' · ' + (d.tables || []).length + ' 个表/视图';
      var tables = d.tables || [];
      document.getElementById('db-tables').innerHTML = tables.length
        ? tables.map(function(t){
            return '<div style="margin:2px 0"><a href="javascript:void(0)" onclick="dbTable(decodeURIComponent(\''
              + encodeURIComponent(t.name) + '\'))">' + esc(t.name) + '</a>'
              + ' <span class="muted" style="font-size:11px">' + (t.type === 'view' ? '视图' : '表') + '</span></div>';
          }).join('')
        : '<span class="muted">（无表）</span>';
      if (tables.length) dbTable(tables[0].name);
      else dbSetMsg('数据库已打开，但没有表');
    })
    .catch(function(e){ dbSetMsg('打开失败：' + String(e), true); });
}
function dbTable(name){
  if (!dbState.id) return;
  dbState.table = name; dbState.offset = 0; dbState.mode = 'table';
  var sql = 'SELECT * FROM "' + name.replace(/"/g, '""') + '" LIMIT ' + dbState.limit + ' OFFSET 0';
  document.getElementById('db-sql').value = sql;
  dbSchema(name);
  dbFetch(sql);
}
function dbSchema(name){
  fetch('/api/db/schema?dbId=' + encodeURIComponent(dbState.id) + '&table=' + encodeURIComponent(name))
    .then(function(r){ return r.json(); })
    .then(function(d){
      var host = document.getElementById('db-schema');
      if (d.error) { host.innerHTML = '<span class="bad">结构读取失败：' + esc(d.error) + '</span>'; return; }
      var cols = d.columns || [];
      var html = '<div class="muted" style="margin-bottom:2px">结构：' + esc(name) + '</div>'
        + '<table class="sbtable"><tr><th>列</th><th>类型</th><th>非空</th><th>主键</th><th>默认值</th></tr>'
        + cols.map(function(c){
            return '<tr><td>' + esc(c.name) + '</td><td>' + esc(c.type || '') + '</td>'
              + '<td>' + (c.notnull ? '是' : '') + '</td><td>' + (c.pk ? '是' : '') + '</td>'
              + '<td>' + (c.dflt_value == null ? '' : esc(String(c.dflt_value))) + '</td></tr>';
          }).join('')
        + '</table>';
      if (d.sql) html += '<details style="margin-top:4px"><summary class="muted">建表 SQL</summary><pre class="muted" style="white-space:pre-wrap;font-size:12px">' + esc(d.sql) + '</pre></details>';
      host.innerHTML = html;
    })
    .catch(function(e){ document.getElementById('db-schema').innerHTML = '<span class="bad">结构读取失败：' + esc(String(e)) + '</span>'; });
}
function dbRun(){
  var sql = document.getElementById('db-sql').value.trim();
  if (!sql) { dbSetMsg('SQL 为空', true); return; }
  dbState.mode = 'sql';
  dbFetch(sql);
}
function dbFetch(sql){
  if (!dbState.id) { dbSetMsg('请先从「应用沙盒」打开 .db 文件', true); return; }
  dbSetMsg('执行中…');
  fetch('/api/db/query', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({dbId:dbState.id, sql:sql})})
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (d.error) { dbSetMsg('执行失败：' + d.error, true); return; }
      dbRenderResult(d);
      var n = (d.rows || []).length;
      dbSetMsg(n + ' 行 · ' + d.ms + 'ms' + (d.truncated ? ' · 结果过大已截断' : ''));
      var pager = document.getElementById('db-pager');
      pager.style.display = dbState.mode === 'table' ? '' : 'none';
      document.getElementById('db-pageinfo').textContent =
        '第 ' + (dbState.offset + 1) + ' ~ ' + (dbState.offset + n) + ' 行（每页 ' + dbState.limit + '）';
    })
    .catch(function(e){ dbSetMsg('执行失败：' + String(e), true); });
}
function dbRenderResult(d){
  var cols = d.columns || [], rows = d.rows || [];
  var host = document.getElementById('db-result');
  if (!rows.length) { host.innerHTML = '<span class="muted">0 行</span>'; return; }
  var head = '<tr><th style="width:46px">#</th>' + cols.map(function(c){ return '<th>' + esc(c) + '</th>'; }).join('') + '</tr>';
  var body = rows.map(function(r, i){
    return '<tr><td class="muted">' + (dbState.offset + i + 1) + '</td>' + r.map(function(v){
      if (v === null || v === undefined) return '<td class="muted">NULL</td>';
      var s = String(v);
      var show = s.length > 300 ? s.slice(0, 300) + '…' : s;
      return '<td style="max-width:420px;word-break:break-all" title="' + esc(s.slice(0, 2000)) + '">' + esc(show) + '</td>';
    }).join('') + '</tr>';
  }).join('');
  host.innerHTML = '<div style="max-height:460px;overflow:auto"><table class="sbtable">' + head + body + '</table></div>';
}
function dbPage(delta){
  if (dbState.mode !== 'table' || !dbState.table) return;
  var next = dbState.offset + delta * dbState.limit;
  if (next < 0) next = 0;
  dbState.offset = next;
  var sql = 'SELECT * FROM "' + dbState.table.replace(/"/g, '""') + '" LIMIT ' + dbState.limit + ' OFFSET ' + next;
  document.getElementById('db-sql').value = sql;
  dbFetch(sql);
}
function dbCsv(){
  if (!dbState.id) { dbSetMsg('请先打开数据库', true); return; }
  var sql = document.getElementById('db-sql').value.trim();
  if (!sql) { dbSetMsg('SQL 为空', true); return; }
  window.location = '/api/db/csv?dbId=' + encodeURIComponent(dbState.id) + '&sql=' + encodeURIComponent(sql);
}
function dbReload(){
  if (!dbState.path) { dbSetMsg('请先从「应用沙盒」打开 .db 文件', true); return; }
  dbOpen(dbState.path, true);
}
function dbClose(){
  if (!dbState.id) { dbReset(); return; }
  fetch('/api/db/close', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({dbId:dbState.id})})
    .then(function(){ dbReset(); })
    .catch(function(){ dbReset(); });
}
function syncGroup(){
  var on = document.getElementById('f-src-device').checked;
  var g = document.getElementById('vlv');
  g.classList.toggle('dim', !on);
  g.querySelectorAll('input').forEach(function(c){ c.disabled = !on; });
}
syncGroup();
// ── 服务控制（顶栏）：GUI / 守护进程的启停与重启、重新部署 ──
var svcInfo = null, svcToastTimer = null;
function svcEl(id){ return document.getElementById(id); }
function svcToggle(e){
  if (e) e.stopPropagation();
  svcEl('svc-menu').classList.toggle('open');
  svcPoll();
}
// 点空白处收起下拉（按钮自身已 stopPropagation，菜单内部点击不关）。
document.addEventListener('click', function(e){
  var m = svcEl('svc-menu');
  if (m && !m.contains(e.target) && e.target.id !== 'svc-btn') m.classList.remove('open');
});
function svcToast(msg, isErr){
  var t = svcEl('svc-toast');
  t.textContent = msg;
  t.className = isErr ? 'err' : '';
  t.style.display = 'block';
  if (svcToastTimer) clearTimeout(svcToastTimer);
  svcToastTimer = setTimeout(function(){ t.style.display = 'none'; }, 6000);
}
function svcPoll(){
  fetch('/api/svc/status').then(function(r){ return r.json(); }).then(function(d){
    svcInfo = d; svcRender();
  }).catch(function(){}).finally(function(){ setTimeout(svcPoll, 5000); });
}
function svcRender(){
  var g = svcEl('svc-badge-gui'), dm = svcEl('svc-badge-daemon');
  var gi = svcInfo && svcInfo.gui;
  g.textContent = gi ? ('GUI ' + gi.port) : 'GUI ○';
  g.className = 'svc-badge ' + (gi ? 'on' : 'off');
  if (gi) {
    var m = Math.floor((gi.uptimeSec || 0) / 60);
    g.title = 'GUI 进程 pid=' + gi.pid + '，已运行 ' + (m >= 60 ? Math.floor(m / 60) + ' 小时 ' : '') + (m % 60) + ' 分钟\n脚本：' + (gi.script || '');
  }
  var d = svcInfo && svcInfo.daemon;
  if (d) {
    dm.textContent = 'daemon ' + ((d.sessions || []).length) + ' 会话';
    dm.className = 'svc-badge on';
    dm.title = '守护进程 pid=' + d.pid + '，已运行 ' + Math.round((d.uptimeSec || 0) / 60) + ' 分钟';
  } else {
    dm.textContent = 'daemon ○';
    dm.className = 'svc-badge off';
    dm.title = '守护进程未运行（IDE 双击跳转会失效）';
  }
  var rd = svcEl('svc-redeploy'), hint = svcEl('svc-redeploy-hint');
  var hasSrc = !!(svcInfo && svcInfo.sourceRoot);
  rd.classList.toggle('disabled', !hasSrc);
  rd.onclick = hasSrc ? function(){ svcAct('redeploy'); } : null;
  hint.style.display = hasSrc ? 'none' : 'block';
  rd.title = hasSrc ? ('从源码重新部署到 ' + svcInfo.sourceRoot + ' 并重启') : '';
}
// 遮罩 + 自动重连：重启 / 重新部署后轮询 /ping，恢复后 reload。
function svcOverlay(title, sub, waitMs){
  var o = svcEl('svc-overlay');
  o.querySelector('.t').textContent = title;
  o.querySelector('.s').textContent = sub;
  o.style.display = 'flex';
  if (!waitMs) return;
  var t0 = Date.now();
  (function tick(){
    if (Date.now() - t0 > waitMs) {
      o.querySelector('.t').textContent = '服务没有按时恢复';
      o.querySelector('.s').textContent = '请双击「xb_ume 工具箱」重新打开；部署问题看 ~/.xb_ume_ide/install.log';
      return;
    }
    fetch('/ping', {cache: 'no-store'}).then(function(r){ return r.text(); }).then(function(t){
      if (t.trim() === 'xbume-gui') { location.reload(); return; }
      setTimeout(tick, 600);
    }).catch(function(){ setTimeout(tick, 600); });
  })();
}
function svcAct(action, target){
  var key = action + '-' + (target || 'all');
  var tips = {
    'restart-gui': '重启 GUI：页面会断开约 3~5 秒后自动恢复，确定？',
    'restart-daemon': '重启守护进程？正在进行的调试会话会自动重连。',
    'restart-all': '重启守护进程与 GUI：页面会断开约 5 秒后自动恢复，确定？',
    'stop-gui': '停止 GUI 后本页面会失去连接，需要双击「xb_ume 工具箱」才能重新打开。确定？',
    'stop-daemon': '停止守护进程后，IDE 双击跳转会失效，直到重新开启。确定？',
    'redeploy-all': '从源码重新部署并重启：页面会断开 10~60 秒；若一直没恢复，请双击工具箱或查看部署日志。确定？'
  };
  if (!confirm(tips[key] || (action === 'redeploy' ? tips['redeploy-all'] : ('确定执行 ' + action + '？')))) return;
  svcEl('svc-menu').classList.remove('open');
  var url = '/api/svc/' + action + (target ? '?target=' + target : '');
  fetch(url, {method: 'POST'}).then(function(r){ return r.json(); }).then(function(d){
    svcToast(d.message || (d.ok ? '已执行' : '失败'), !d.ok);
    if (!d.ok) { svcPoll(); return; }
    var target2 = target || 'all';
    if (action === 'redeploy') {
      svcOverlay('正在重新部署并重启…', '从源码部署到 ~/.xb_ume_ide 后再启动；通常 10~60 秒。若超过 2 分钟没恢复，请双击「xb_ume 工具箱」或查看部署日志。', 120000);
    } else if (action === 'restart' && (target2 === 'gui' || target2 === 'all')) {
      svcOverlay('GUI 正在重启…', '页面会自动恢复；若 30 秒内没反应，请双击「xb_ume 工具箱」。', 30000);
    } else if (action === 'stop' && (target2 === 'gui' || target2 === 'all')) {
      svcOverlay('GUI 服务已停止', '双击「xb_ume 工具箱」可重新开启。', 0);
    } else if (action === 'stop') {
      if (typeof refreshDaemon === 'function') refreshDaemon();
      svcPoll();
    } else {
      if (typeof refreshDaemon === 'function') refreshDaemon();
      svcPoll();
    }
  }).catch(function(e){ svcToast('请求失败: ' + e, true); svcPoll(); });
}
function svcShowLog(){
  svcEl('svc-menu').classList.remove('open');
  svcEl('svc-logbox').style.display = 'block';
  svcEl('svc-log-pre').textContent = '读取中…';
  fetch('/api/svc/log').then(function(r){ return r.json(); }).then(function(d){
    svcEl('svc-log-pre').textContent = (d && d.text) ? d.text : '（还没有部署日志；点「重新部署并重启」后生成）';
  }).catch(function(e){ svcEl('svc-log-pre').textContent = '读取失败: ' + e; });
}
svcPoll();

function restartDaemon(){
  svcAct('restart', 'daemon');
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
    // GET 只扫描不落盘；有新增/去重时由页面显式 POST 保存（保持原自动追加语义）。
    if ((d.added && d.added.length) || (d.removed && d.removed.length)) {
      fetch('/api/ideorder', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ideOrder: ideOrder})}).catch(function(){});
    }
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
    inWatches = [];
    inWatchRender();
    return;
  }
  inWatchRefresh();
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
      + (canEdit ? ' <a href="javascript:void(0)" style="font-size:12px" onclick="inEdit(this, ' + nameAttr + ', \'' + vtype + '\', ' + ownerAttr + ')">编辑</a>' : '')
      + (n.name && ownerId && watchFieldOkJs(n.name) ? ' <a href="javascript:void(0)" style="font-size:12px" onclick="inWatchField(' + ownerAttr + ', ' + nameAttr + ')" title="按上方设定的间隔/条件监听该字段，变化写入时间轴">监听</a>' : '');
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
      + (!primitive && n.id ? ' <a href="javascript:void(0)" style="font-size:12px" onclick="inExpand(this, \'' + esc(n.id) + '\', ' + nameAttr + ', ' + pathAttr + ')">展开</a>' : '')
      + (n.name && ownerId && watchFieldOkJs(n.name) ? ' <a href="javascript:void(0)" style="font-size:12px" onclick="inWatchField(' + ownerAttr + ', ' + nameAttr + ')" title="监听该字段的值（对象显示类名与 id 尾号），变化写入时间轴">监听</a>' : '');
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
// ── Watch 监听：实例字段 / eval 表达式变化写入时间轴，条件命中自动截图 ──
var inWatches = [];
function watchFieldOkJs(name){ return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name || ''); }
function inWatchOpts(){
  var shot = document.getElementById('in-watch-shot');
  return {
    lib: (document.getElementById('in-watch-lib').value || '').trim(),
    condition: (document.getElementById('in-watch-cond').value || '').trim(),
    autoShot: !!(shot && shot.checked),
    intervalMs: parseInt(document.getElementById('in-watch-ms').value, 10) || 500
  };
}
function inWatchAdd(body, okMsg){
  if (!inUri()) { inStat('请先选择 VM'); return; }
  var payload = Object.assign({ uri: inUri() }, inWatchOpts(), body);
  inStat('添加监听…');
  fetch('/api/watch/add', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(payload) })
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (!d.ok) { inStat('添加失败：' + (d.error || '')); return; }
      inStat(d.duplicated ? '该监听已存在' : (okMsg || '已添加监听'));
      if (d.item) { inWatchUpsert(d.item); inWatchRender(); }
    })
    .catch(function(e){ inStat('添加失败：' + String(e)); });
}
function inWatchExpr(){
  var el = document.getElementById('in-watch-expr');
  var expr = (el.value || '').trim();
  if (!expr) { inStat('请输入表达式'); el.focus(); return; }
  inWatchAdd({ kind:'expr', expr: expr }, '已添加表达式监听');
}
function inWatchField(ownerId, name){
  if (!watchFieldOkJs(name)) { inStat('字段名不合法：' + name); return; }
  inWatchAdd({ kind:'field', targetId: ownerId, expr: name, label: name }, '已监听字段 ' + name);
}
function inWatchUpsert(item){
  if (!item || !item.id) return;
  for (var i = 0; i < inWatches.length; i++) {
    if (inWatches[i].id === item.id) { inWatches[i] = item; return; }
  }
  inWatches.push(item);
}
function inWatchApply(item){
  if (!item || !item.id) return;
  inWatchUpsert(item);
  // 只更新行内状态文本：全量重渲染会打断滚动/定位高亮与按钮点击。
  var row = document.querySelector('#in-watch-list .wrow[data-wid="' + item.id + '"]');
  if (!row) return;
  var stat = row.querySelector('.wstat');
  if (stat) stat.textContent = '变化 ' + (item.changes || 0) + ' · 截图 ' + (item.shots || 0);
  var st = row.querySelector('.wst');
  if (st) st.innerHTML = inWatchStatus(item);
}
function inWatchStatus(w){
  if (w.paused) return '<span class="bad">已暂停</span>';
  if (w.lastError) return '<span class="bad">' + esc(String(w.lastError).substring(0, 90)) + '</span>';
  if (!w.hasValue) return '<span class="muted">等待首次采样…</span>';
  return '<span class="muted">当前 ' + esc(w.lastValue == null ? '' : String(w.lastValue)) + '</span>';
}
function inWatchRefresh(){
  if (!inUri()) { inWatches = []; inWatchRender(); return; }
  fetch('/api/watch/list?uri=' + encodeURIComponent(inUri()))
    .then(function(r){ return r.json(); })
    .then(function(d){ if (!d.ok) return; inWatches = d.items || []; inWatchRender(); })
    .catch(function(){});
}
function inWatchRender(){
  var box = document.getElementById('in-watch-list');
  if (!box) return;
  var uri = inUri();
  var items = inWatches.filter(function(w){ return !uri || w.uri === uri; });
  if (!items.length) {
    box.innerHTML = '<span class="muted" style="font-size:12px">暂无监听：在上方输入表达式，或在字段行点「监听」</span>';
    return;
  }
  box.innerHTML = items.map(function(w){
    var meta = esc(w.expr) + ' · ' + (w.intervalMs || 500) + 'ms';
    if (w.condition) meta += ' · 条件 ' + esc(w.condition) + (w.autoShot === false ? '（不截图）' : '');
    var stat = '<span class="wstat muted">变化 ' + (w.changes || 0) + ' · 截图 ' + (w.shots || 0) + '</span>';
    var st = '<span class="wst">' + inWatchStatus(w) + '</span>';
    return '<div class="wrow" data-wid="' + esc(w.id) + '">'
      + '<span class="muted" style="font-size:12px;flex:none">' + (w.kind === 'field' ? '字段' : '表达式') + '</span>'
      + '<b style="flex:none">' + esc(w.label || w.expr) + '</b>'
      + '<span class="muted" style="font-size:12px">' + meta + '</span>'
      + stat + st
      + '<button style="flex:none" onclick="inWatchPause(\'' + esc(w.id) + '\', ' + (w.paused ? 'false' : 'true') + ')">' + (w.paused ? '恢复' : '暂停') + '</button>'
      + '<button style="flex:none" onclick="inWatchRemove(\'' + esc(w.id) + '\')">删除</button>'
      + '</div>';
  }).join('');
}
function inWatchPause(id, paused){
  fetch('/api/watch/pause?id=' + encodeURIComponent(id) + '&on=' + (paused ? '1' : '0'), { method:'POST' })
    .then(function(r){ return r.json(); })
    .then(function(d){ if (!d.ok) inStat('操作失败：监听可能已被删除'); })
    .catch(function(e){ inStat('操作失败：' + String(e)); });
}
function inWatchRemove(id){
  fetch('/api/watch/remove?id=' + encodeURIComponent(id), { method:'POST' })
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (!d.ok) { inStat('删除失败：监听可能已不存在'); return; }
      inWatches = inWatches.filter(function(w){ return w.id !== id; });
      inWatchRender(); inStat('已删除监听');
    })
    .catch(function(e){ inStat('删除失败：' + String(e)); });
}
// 监听事件 → 时间轴（WS 实时推送 + 打开时间轴时回填服务端最近 500 条）。
function watchEventAdd(item, silent){
  if (!item || !item.id) return;
  var key = 'watch:' + item.id;
  for (var i = 0; i < watchEvents.length; i++) {
    if (watchEvents[i].id === key) return;
  }
  watchEvents.push({ t:'watch', id:key, ms:item.ms || Date.now(), uri:item.uri || '', w:item });
  if (watchEvents.length > 500) watchEvents.splice(0, watchEvents.length - 500);
  if (!silent) tlSchedule();
}
function inWatchBackfill(){
  var uri = tlUri();
  if (!uri) return;
  fetch('/api/watch/events?uri=' + encodeURIComponent(uri))
    .then(function(r){ return r.json(); })
    .then(function(d){
      if (!d.ok) return;
      (d.items || []).forEach(function(it){ watchEventAdd(it, true); });
      if (tlOnTab()) tlRender();
    })
    .catch(function(){});
}
function tlGoWatch(watchId){
  var tab = document.querySelector('.tab[data-tab="instances"]');
  if (tab) tab.click();
  locateWhenFound(function(){
    return document.querySelector('#in-watch-list .wrow[data-wid="' + watchId + '"]');
  }, '监听列表里没有该项（可能已被删除）');
}
loadIdeOrder();
// 默认激活的就是「守护进程」页：立即拉一次 MCP 状态。仅靠 setInterval
// 会导致首屏最多 15 秒显示「查询中…」。
refreshMcp();
// ── 调试 Tab（flutter run + VM 断点）──────────────────────────────────────
// 所有动作打 /api/debug/op，响应 = 状态快照 + 本次结果；事件与运行输出走
// WebSocket（debug / debugState / debugOutput）。断点只调 VM service，
// 不改源码、不需要编辑器：这里是「调试器控制面板」。
var dbgSt = {};            // 最新状态快照（后端 status()）
var dbgFrames = [];        // 当前调用栈（暂停后自动拉）
var dbgFrameIdx = 0;       // 选中帧（求值用它）
var dbgPauseKeyShown = ''; // 已拉过栈的暂停点，避免状态推送重复拉栈
var dbgStackLoaded = false; // 当前暂停点已拉过一次栈（空栈也能说清楚）
var dbgStacking = false;   // 拉栈进行中
var dbgAttachList = [];    // 可接入的调试会话（/api/daemon）
var dbgOutLines = [];      // 运行输出（前端最多留 2000 行）
var dbgOutSeq = 0;         // 已渲染到的输出序号（旧的 status 快照不回退）
var dbgToastTimer = null;
var dbgEditBpId = '';      // 非空 = 正在改这条断点的条件 / 日志（位置不可改）

function dbgEl(id){ return document.getElementById(id); }

function dbgShow(){
  dbgLoadOpts();
  dbgLoadSaved();
  dbgProfileRefresh();
  refreshDaemon(); // 顺手刷新「接入会话」下拉
  dbgStatus();
}

// 项目目录候选 + 设备下拉。默认选本机桌面（macos / windows）：不自动选手机，
// 避免在手机会话上误操作（手机上的会话请用「接入」）。
function dbgDesktop(){
  var ua = navigator.userAgent || '';
  if (/Windows/i.test(ua)) return 'windows';
  if (/Linux/i.test(ua) && !/Android/i.test(ua)) return 'linux';
  return 'macos';
}

// 设备 id → 平台（/api/ai/config 已带回，如 android / ohos / ios-real）。
// 启动时传给后端，运行配置据此选参数（不传让后端自己识别也行，但会多一次
// `flutter devices --machine`）。
var dbgDevPlatforms = {};

function dbgPlatformOf(dev){
  if (dbgDevPlatforms[dev]) return dbgDevPlatforms[dev];
  if (dev === 'macos' || dev === 'windows' || dev === 'linux') return dev;
  return '';
}

function dbgLoadOpts(){
  fetch('/api/ai/config').then(function(r){ return r.json(); }).then(function(d){
    var dirl = dbgEl('dbg-dir-list');
    if (dirl) {
      dirl.innerHTML = '';
      [d.projectDir].concat(d.sessionDirs || [], d.recentDirs || []).forEach(function(p){
        if (!p) return;
        var o = document.createElement('option');
        o.value = p;
        dirl.appendChild(o);
      });
    }
    var dir = dbgEl('dbg-dir');
    if (dir && !dir.value) {
      dir.value = d.projectDir || (d.sessionDirs || [])[0] || (d.recentDirs || [])[0] || '';
    }
    var sel = dbgEl('dbg-device');
    if (!sel) return;
    var prev = sel.value;
    var list = d.devices || [];
    var html = '';
    dbgDevPlatforms = {};
    list.forEach(function(x){
      if (x.platform) dbgDevPlatforms[x.id] = x.platform;
      html += '<option value="' + esc(x.id) + '">'
        + esc((platformNames[x.platform] || x.platform || '') + ' · ' + (x.name || x.id)) + '</option>';
    });
    var desk = dbgDesktop();
    var hasDesk = list.some(function(x){ return x.id === desk; });
    sel.innerHTML = html || '<option value="' + desk + '">本机桌面</option>';
    sel.value = prev;
    if (!sel.value) sel.value = hasDesk ? desk : (list.length ? list[0].id : desk);
    dbgLoadSaved(); // 目录默认值已回填，顺手刷新「已记住」
    dbgProfileRefresh(); // 目录 / 设备都就位了，顺手刷新运行配置摘要
  }).catch(function(){});
}

// 已记住的断点（$XB_UME_HOME/debug/breakpoints.json，按项目根）：没连会话也能看/清。
var dbgSavedList = [];
var dbgSavedAllMode = false;
var dbgSavedAllProjects = [];

function dbgDirValue(){ return (dbgEl('dbg-dir').value || '').trim(); }

// 运行配置摘要（$XB_UME_HOME/debug/run_profiles.json，按项目根）：
// 只读展示「启动前要跑什么、额外参数、停止后清理什么」，具体内容是文件里的，
// 改它用「打开配置」。没配置 / 读不到都只是提示，不影响启动。
function dbgProfileText(d){
  var p = d.profile;
  if (!p) return d.exists ? '未配置（点「打开配置」加本项目的配置）' : '未配置（点「打开配置」新建文件）';
  var parts = [];
  if ((p.platforms || []).length) parts.push('仅 ' + p.platforms.join('/'));
  if ((p.preRun || []).length) parts.push('预启动 ' + p.preRun.length + ' 条');
  if ((p.postStop || []).length) parts.push('停止清理 ' + p.postStop.length + ' 条');
  var args = p.runArgs || {};
  Object.keys(args).forEach(function(k){
    var v = (args[k] || []).join(' ');
    if (v) parts.push((k === '*' ? '所有平台' : k) + ': ' + v);
  });
  if (p.continueOnError) parts.push('预启动失败仍继续');
  return esc(parts.length ? parts.join(' · ') : '已配置（无额外动作）');
}

function dbgProfileRefresh(btn){
  var box = dbgEl('dbg-profile');
  if (!box) return Promise.resolve();
  var dir = dbgDirValue();
  if (!dir) {
    box.textContent = '先选项目目录';
    box.title = '';
    return Promise.resolve();
  }
  // 用 GET 而不走 dbgOp：那个会把返回当成会话状态刷到整页。
  return fetch('/api/debug/op?op=runProfile&dir=' + encodeURIComponent(dir))
    .then(function(r){ return r.json(); }).then(function(d){
      if (!d || d.ok === false) {
        box.textContent = '读取失败' + (d && d.error ? '：' + d.error : '');
        return;
      }
      box.innerHTML = dbgProfileText(d);
      box.title = d.path ? (d.path + (d.exists ? '' : '（文件还没创建）')) : '';
    }).catch(function(){ box.textContent = '读取失败'; });
}

function dbgProfileOpen(){ fetch('/api/openconfig?file=run', {method: 'POST'}); }

function dbgLoadSaved(){
  dbgSavedAllMode = false;
  var dir = dbgDirValue();
  var num = dbgEl('dbg-saved-n');
  if (!dir) {
    dbgSavedList = [];
    dbgRenderSaved();
    if (num) num.textContent = '先选项目目录';
    return Promise.resolve();
  }
  return fetch('/api/debug/op?op=saved&dir=' + encodeURIComponent(dir))
    .then(function(r){ return r.json(); }).then(function(d){
      dbgSavedList = (d && d.saved) || [];
      dbgRenderSaved();
    }).catch(function(){});
}

// 「已记住」行的启停按钮：停用态显示「启用」，反之显示「停用」。
function dbgSavedBpToggleHtml(dir, abs, b){
  var off = b.enabled === false;
  return '<span class="x" title="' + (off
      ? '恢复命中（当前会话有同位置断点也一起启用）'
      : '先别命中（下次接入按这个状态恢复）') + '"'
    + ' data-dir="' + escAttr(dir) + '" data-file="' + escAttr(abs) + '"'
    + ' data-line="' + (b.line || 0) + '" data-enable="' + (off ? '1' : '0') + '"'
    + ' onclick="dbgSavedBpToggle(this)">' + (off ? '启用' : '停用') + '</span>';
}

// 点一下切一下：没连会话也能改（下次接入按新状态恢复）；
// 当前会话有同位置的断点时后端会一并切 VM 的启停，不然会觉得「点了没用」。
function dbgSavedBpToggle(el){
  var file = el.getAttribute('data-file') || '';
  var line = parseInt(el.getAttribute('data-line'), 10) || 0;
  var enabled = el.getAttribute('data-enable') === '1';
  if (!file || !line) return;
  var old = el.textContent;
  el.textContent = enabled ? '启用中…' : '停用中…';
  dbgOp('enableSavedBreakpoint', {
    dir: el.getAttribute('data-dir') || '',
    path: file,
    line: line,
    enabled: enabled,
  }).then(function(d){
    if (!d || d.ok === false) { el.textContent = old; return; } // 错误已由 dbgOp 提示
    // 后端会报「已停用 …（当前会话已同步）」，把是否动了 VM 一并告诉用户。
    if (d.message) dbgToast(d.message);
    // 清单整份重拉：当前项目 / 「全部项目」两种视图各拉各的。
    if (dbgSavedAllMode) dbgShowAllSaved(null); else dbgLoadSaved();
  });
}

function dbgRenderSaved(){
  var box = dbgEl('dbg-saved');
  if (!box) return;
  var num = dbgEl('dbg-saved-n');
  if (num) {
    num.textContent = dbgSavedList.length
      ? '共 ' + dbgSavedList.length + ' 个（重连同一项目自动恢复）'
      : '还没有记住的断点（加断点后自动记住）';
  }
  var dir = dbgDirValue(); // 启停按钮要带上项目根（没连会话时也能改）
  box.innerHTML = dbgSavedList.map(function(b){
    var p = b.path || '';
    var name = p.split('/').pop();
    var abs = b.absPath || p; // 落盘清单存的是相对项目根的 path，IDE 要绝对路径
    return '<div class="dbg-bp' + (b.enabled === false ? ' off' : '') + '">'
      + '<span class="dot" title="已记住（点「忘记」可清空）"></span>'
      + '<span class="p" title="' + esc(abs) + '">' + esc(name) + ':' + (b.line || 0) + '</span>'
      + (b.condition ? '<span class="cond" title="' + esc(b.condition) + '">if ' + esc(b.condition) + '</span>' : '')
      + (b.logMessage ? '<span class="cond" title="' + esc(b.logMessage) + '">log ' + esc(b.logMessage) + '</span>' : '')
      + dbgSavedBpToggleHtml(dir, abs, b)
      + '<span class="x" title="用配置的 IDE 打开 ' + escAttr(abs) + ':' + (b.line || 0) + '"'
      + ' data-file="' + escAttr(abs) + '" data-line="' + (b.line || 0) + '" onclick="dbgIdeJumpEl(this)">跳转</span>'
      + '</div>';
  }).join('');
}

// 已记住总览：按项目根分组列出所有项目的清单（换项目后也能看见/清理）。
function dbgShowAllSaved(btn){
  var done = dbgBusy(btn, '读取中…');
  return fetch('/api/debug/op?op=savedAll').then(function(r){ return r.json(); }).then(function(d){
    done();
    if (!d || d.ok === false) { dbgToast((d && d.error) || '读取失败'); return; }
    dbgSavedAllMode = true;
    dbgSavedAllProjects = (d && d.projects) || [];
    dbgRenderSavedAll();
  }).catch(function(e){ done(); dbgToast('请求失败：' + e); });
}

function dbgRenderSavedAll(){
  var box = dbgEl('dbg-saved');
  if (!box) return;
  var projects = dbgSavedAllProjects;
  var total = 0;
  projects.forEach(function(p){ total += (p.items || []).length; });
  var num = dbgEl('dbg-saved-n');
  if (num) num.textContent = total ? '全部项目共 ' + total + ' 个（点「刷新」回到当前项目）' : '';
  if (!total) { box.innerHTML = '<div class="muted" style="padding:6px">所有项目都还没有记住的断点</div>'; return; }
  box.innerHTML = projects.map(function(p, pi){
    var dir = p.dir || '';
    var name = dir.split('/').pop() || dir;
    var head = '<div class="row" style="gap:6px;margin-top:6px;padding:2px 4px;border-top:1px solid var(--line)">'
      + '<b style="font-size:12px;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' + esc(dir) + '">'
      + esc(name) + (p.current ? '（当前）' : '') + '</b>'
      + '<span class="muted" style="font-size:12px">' + (p.items || []).length + ' 个</span>'
      + '<span class="x" title="清空该项目的记住断点" onclick="dbgForgetDirAt(' + pi + ')">✕</span>'
      + '</div>';
    var items = (p.items || []).map(function(b){
      var bp = b.path || '';
      var bname = bp.split('/').pop();
      var babs = b.absPath || bp; // 总览也是同一份落盘清单，同样补绝对路径
      return '<div class="dbg-bp' + (b.enabled === false ? ' off' : '') + '" style="padding-left:18px">'
        + '<span class="dot" title="已记住"></span>'
        + '<span class="p" title="' + esc(babs) + '">' + esc(bname) + ':' + (b.line || 0) + '</span>'
        + (b.condition ? '<span class="cond" title="' + esc(b.condition) + '">if ' + esc(b.condition) + '</span>' : '')
        + (b.logMessage ? '<span class="cond" title="' + esc(b.logMessage) + '">log ' + esc(b.logMessage) + '</span>' : '')
        + dbgSavedBpToggleHtml(dir, babs, b)
        + '<span class="x" title="用配置的 IDE 打开 ' + escAttr(babs) + ':' + (b.line || 0) + '"'
        + ' data-file="' + escAttr(babs) + '" data-line="' + (b.line || 0) + '" onclick="dbgIdeJumpEl(this)">跳转</span>'
        + '</div>';
    }).join('');
    return head + items;
  }).join('');
}

function dbgForgetDirAt(i){
  var p = dbgSavedAllProjects[i];
  if (p && p.dir) dbgForgetDir(p.dir);
}

function dbgForgetDir(dir){
  if (!confirm('清空「' + dir + '」记住的断点？\n下次连接不再自动恢复（不影响当前会话里已下的断点）。')) return;
  fetch('/api/debug/op', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({op: 'forgetSaved', dir: dir})
  }).then(function(r){ return r.json(); }).then(function(d){
    if (d && d.ok === false) { dbgToast(d.error || '清理失败'); return; }
    dbgToast('已忘记 ' + ((d && d.cleared) || 0) + ' 个断点');
    dbgShowAllSaved();
  }).catch(function(e){ dbgToast('请求失败：' + e); });
}

function dbgForgetSaved(btn){
  var dir = dbgDirValue();
  if (!dir) { dbgToast('先选项目目录（记住的断点按项目根归属）'); return; }
  if (!confirm('清空「' + dir + '」记住的断点？\n下次连接不再自动恢复（不影响当前会话里已下的断点）。')) return;
  var done = dbgBusy(btn, '清理中…');
  fetch('/api/debug/op', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({op: 'forgetSaved', dir: dir})
  }).then(function(r){ return r.json(); }).then(function(d){
    done();
    if (d && d.ok === false) { dbgToast(d.error || '清理失败'); return; }
    dbgToast('已忘记 ' + ((d && d.cleared) || 0) + ' 个断点');
    dbgLoadSaved();
  }).catch(function(e){ done(); dbgToast('请求失败：' + e); });
}

function dbgStatus(){
  return fetch('/api/debug/op?op=status').then(function(r){ return r.json(); })
    .then(function(d){ dbgApply(d); return d; }).catch(function(){});
}

// 发一个调试动作；失败不抛，统一 toast 提示。
function dbgOp(op, extra){
  var body = {op: op};
  if (extra) for (var k in extra) if (Object.prototype.hasOwnProperty.call(extra, k)) body[k] = extra[k];
  return fetch('/api/debug/op', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(body)
  }).then(function(r){ return r.json(); }).then(function(d){
    dbgApply(d);
    if (d && d.ok === false && d.error) dbgToast(d.error);
    return d;
  }).catch(function(e){ dbgToast('请求失败：' + e); return null; });
}

function dbgBusy(btn, label){
  if (!btn) return function(){};
  var old = btn.textContent;
  btn.disabled = true;
  btn.textContent = label;
  return function(){ btn.disabled = false; btn.textContent = old; };
}

function dbgToast(text){
  var el = dbgEl('dbg-toast');
  if (!el) { clog('[debug] ' + text); return; }
  el.textContent = text;
  el.style.display = 'block';
  clearTimeout(dbgToastTimer);
  dbgToastTimer = setTimeout(function(){ el.style.display = 'none'; }, 5000);
}

// 统一渲染入口：HTTP 响应与 WS 推送都是「状态快照」，走同一套渲染。
function dbgApply(d){
  if (!d || typeof d !== 'object') return;
  // 失败的 op 只带 error、没有状态快照：直接覆盖会把断点列表 / 暂停现场清空，
  // 看着像「断点全没了」。错误提示由 dbgOp 弹，这里保留上一份状态。
  if (d.ok === false && !d.breakpoints) return;
  dbgSt = d;
  if (d.output) dbgOutSet(d.output, d.outSeq);
  dbgRenderHead();
  dbgRenderBps();
  dbgRenderBar();
  var key = d.paused ? dbgPauseKey(d.pause) : '';
  if (key) {
    if (key !== dbgPauseKeyShown) {
      dbgPauseKeyShown = key;
      dbgStackLoaded = false;
      dbgFrames = [];
      dbgFrameIdx = 0;
      var eo = dbgEl('dbg-eval-out');
      if (eo) { eo.className = 'muted'; eo.textContent = ''; }
      dbgFetchStack();
    }
    dbgRenderPause(d.pause);
    dbgSrcFollowPause();
  } else {
    dbgPauseKeyShown = '';
    dbgRenderIdle();
  }
  if (d.frames) { dbgFrames = d.frames; dbgRenderStack(); }
}

function dbgPauseKey(p){
  if (!p) return '';
  var f = p.topFrame || {};
  return [p.reason || '', f.path || f.scriptUri || '', f.line == null ? '' : f.line,
    (p.breakpointIds || []).join(',')].join('|');
}

function dbgRenderHead(){
  var s = dbgSt;
  var el = dbgEl('dbg-stat');
  var txt = '未连接', cls = 'muted';
  if (s.busy) txt = '正在启动…';
  else if (s.attached && s.paused) { txt = '已暂停'; cls = 'bad'; }
  else if (s.attached) { txt = s.running ? '运行中（已连调试）' : '已连调试'; cls = 'ok'; }
  else if (s.running) txt = '运行中（未连调试）';
  var extra = [];
  if (s.pid) extra.push('pid ' + s.pid);
  if (s.device) extra.push(s.device);
  if (s.reused) extra.push('复用');
  if (s.adopted) extra.push('已认领');
  if (s.wsUri) {
    var m = /:(\d+)\//.exec(s.wsUri);
    if (m) extra.push('VM 端口 ' + m[1]);
  }
  if (el) {
    el.className = cls;
    el.textContent = txt + (extra.length ? ' · ' + extra.join(' · ') : '');
    el.title = s.wsUri || '';
  }
  var msg = dbgEl('dbg-msg');
  if (msg) { msg.textContent = s.message || ''; msg.title = s.message || ''; }
}

function dbgRenderBar(){
  var s = dbgSt, bar = dbgEl('dbg-bar');
  if (!bar) return;
  var on = !!(s.attached || s.running);
  bar.classList.toggle('on', on);
  if (!on) return;
  bar.classList.toggle('paused', !!s.paused);
  var why = dbgEl('dbg-bar-why');
  var f = (s.pause && s.pause.topFrame) || {};
  if (why) {
    if (s.busy) why.textContent = '启动中…';
    else if (s.paused) {
      var fp = f.path || f.scriptUri || '';
      var name = fp ? fp.split('/').pop() : '';
      why.textContent = (f.function || '已暂停') + (name ? ' · ' + name + (f.line ? ':' + f.line : '') : '');
      why.title = fp + (f.line ? ':' + f.line : '');
    } else why.textContent = s.attached ? '运行中' : '未连调试';
  }
  var pauseBtn = dbgEl('dbg-b-pause');
  if (pauseBtn) pauseBtn.disabled = !s.attached || !!s.paused || !!s.busy;
  ['dbg-b-resume', 'dbg-b-over', 'dbg-b-into', 'dbg-b-out'].forEach(function(id){
    var b = dbgEl(id);
    if (b) b.disabled = !s.paused || !!s.busy;
  });
  var hot = dbgEl('dbg-b-hot'), rst = dbgEl('dbg-b-restart');
  if (hot) hot.disabled = !s.pid || !!s.busy;
  if (rst) rst.disabled = !s.pid || !!s.busy;
}

function dbgRenderBps(){
  var el = dbgEl('dbg-bps');
  if (!el) return;
  dbgSrcMark(); // 源码面板开着时，断点增删 / 启停 / 换会话要同步行标记
  var bps = (dbgSt.breakpoints || []).slice();
  if (dbgEditBpId && !bps.some(function(b){ return b.id === dbgEditBpId; })) {
    dbgCancelBpEdit(); // 编辑中的断点被删 / 换了会话：别让「保存修改」打到不存在的 id
  }
  var n = dbgEl('dbg-bp-n');
  if (n) n.textContent = bps.length ? '（' + bps.length + ' 个）' : '';
  dbgSyncBpAllBtn(bps);
  if (!bps.length) { el.innerHTML = '<div class="muted" style="padding:6px">还没有断点</div>'; return; }
  bps.sort(function(a, b){
    var pa = a.path || a.scriptUri || '', pb = b.path || b.scriptUri || '';
    if (pa === pb) return (a.line || 0) - (b.line || 0);
    return pa < pb ? -1 : 1;
  });
  el.innerHTML = bps.map(function(b){
    var p = b.path || b.scriptUri || '?';
    var name = p.split('/').pop();
    var cls = 'dbg-bp' + (b.enabled === false ? ' off' : '') + (b.resolved === false ? ' unres' : '');
    var cond = b.condition
      ? '<span class="cond" title="' + esc(b.condition) + '">if ' + esc(b.condition) + '</span>'
      : '';
    var logm = b.logMessage
      ? '<span class="cond" title="' + esc(b.logMessage) + '">log ' + esc(b.logMessage) + '</span>'
      : '';
    var id = String(b.id == null ? '' : b.id).replace(/[^A-Za-z0-9_.\/-]/g, '');
    return '<div class="' + cls + '">'
      + '<span class="dot" title="' + (b.resolved ? '已解析' : '待解析（文件还没加载）') + '"></span>'
      + '<span class="p" title="' + esc(p) + '">' + esc(name) + ':' + esc(b.line == null ? '?' : b.line) + '</span>'
      + cond
      + logm
      + '<span class="x" title="用配置的 IDE 打开 ' + escAttr(p) + ':' + (b.line == null ? '?' : b.line) + '"'
      + ' data-file="' + escAttr(p) + '" data-line="' + (b.line || 0) + '" onclick="dbgIdeJumpEl(this)">跳转</span>'
      + '<span class="x" title="改条件 / 日志表达式（位置不变）" onclick="dbgEditBp(\'' + id + '\')">✎</span>'
      + '<span class="x" title="' + (b.enabled === false ? '启用' : '停用') + '" onclick="dbgToggleBp(\'' + id + '\')">'
      + (b.enabled === false ? '○' : '●') + '</span>'
      + '<span class="x" title="删除" onclick="dbgDelBp(\'' + id + '\')">✕</span>'
      + '</div>';
  }).join('');
}

function dbgRenderPause(p){
  var el = dbgEl('dbg-frame');
  if (!el) return;
  var f = (p && p.topFrame) || {};
  var bits = [];
  if (p && p.reason) bits.push(p.reason);
  if (f.function) bits.push(f.function);
  var loc = (f.path || f.scriptUri || '') + (f.line ? ':' + f.line : '');
  el.textContent = (bits.join(' · ') || '已暂停') + (loc ? '  ' + loc.split('/').pop() : '');
  el.title = loc;
}

function dbgRenderIdle(){
  var el = dbgEl('dbg-frame');
  if (el) { el.textContent = ''; el.title = ''; }
  dbgFrames = [];
  dbgRenderStack();
}

function dbgRenderStack(){
  var el = dbgEl('dbg-stack');
  if (!el) return;
  if (!dbgFrames.length) {
    el.innerHTML = '<div class="muted" style="padding:6px">'
      + (!dbgSt.paused ? '暂停后显示调用栈'
        : (dbgStackLoaded ? '这个暂停点没有 Dart 栈帧（app 在等事件）' : '读取中…')) + '</div>';
    dbgRenderVars();
    return;
  }
  el.innerHTML = dbgFrames.map(function(f, i){
    var p = f.path || f.scriptUri || '';
    var name = p ? p.split('/').pop() : '';
    var loc = name ? name + (f.line ? ':' + f.line : '') : '';
    return '<div class="dbg-fr' + (i === dbgFrameIdx ? ' cur' : '') + '" onclick="dbgPickFrame(' + i + ')">'
      + '<span class="fn" title="' + esc(f.function || '') + '">' + esc(f.function || '?') + '</span>'
      + '<span class="p" title="' + esc(p) + '">' + esc(loc || '框架代码') + '</span></div>';
  }).join('');
  dbgRenderVars();
}

function dbgPickFrame(i){
  dbgFrameIdx = i | 0;
  dbgRenderStack();
}

var dbgVarKids = {};   // path → {vars,total,truncated}：已拉过的子项（换帧即清）
var dbgVarOpen = {};   // path → true：展开态
var dbgVarObj = {};    // path → objectId：展开时要用的对象 id
var dbgVarFilter = ''; // 筛选关键字（已转小写，空 = 不筛）
var dbgVarMine = true; // 只看自己项目里声明的字段（框架 / 依赖字段收起计数）
var dbgVarFold = {};   // path → false：筛选结果里这一段收起了（默认展开）
var dbgVarGen = 0;     // 变量区生成号：换帧 / 刷栈 +1，异步回来发现变了就丢弃
// 全量筛选：输入停下 300ms 后按 BFS 把整棵树拉下来（getObject），边拉边重画。
// seq 一变（改词 / 清空 / 换帧）在跑的扫描就自行退出；对象数与深度都有上限。
var dbgVarScanSeq = 0;
var dbgVarScanTimer = 0;
var dbgVarScanSt = {run: false, objs: 0, done: false, capped: false};
var dbgVarScanObjCap = 300;
var dbgVarScanDepCap = 8;

// 变量行：有 objectId 的能点开看字段 / 元素（懒加载，点一次读一层）。
// path 是层级路径（"0" / "0-3" / "0-3-1"），只含数字和连字符，可直接进 id。
function dbgVarHtml(v, path, depth){
  var kid = !!v.objectId;
  if (kid) dbgVarObj[path] = v.objectId;
  var open = !!dbgVarOpen[path];
  return '<div class="dbg-var' + (kid ? ' kid' : '') + '" id="dbg-v-' + path + '"'
    + ' style="padding-left:' + (6 + depth * 14) + 'px"'
    + (kid ? ' onclick="dbgVarToggle(\'' + path + '\')" title="展开 / 收起字段、元素"' : '')
    + '>'
    + '<span class="arw">' + (kid ? (open ? '▼' : '▶') : '') + '</span>'
    + '<span class="fn" title="' + esc(v.name) + '">' + esc(v.name) + '</span>'
    + '<span class="p" title="' + esc(v.value) + '">' + esc(v.value) + '</span>'
    + (v.type ? '<span class="muted" style="font-size:11px">' + esc(v.type) + '</span>' : '')
    + '</div>'
    + '<div id="dbg-kids-' + path + '"></div>';
}

function dbgVarRowsHtml(r, parentPath, depth){
  if (!r.vars.length) {
    return '<div class="muted" style="padding:2px 6px 2px ' + (6 + depth * 14) + 'px;font-size:11px">'
      + '没有可见字段（对象可能已被回收，或只有 getter）</div>';
  }
  var html = r.vars.map(function(v, i){
    return dbgVarHtml(v, parentPath + '-' + i, depth);
  }).join('');
  if (r.truncated) {
    html += '<div class="muted" style="padding:2px 6px 2px ' + (6 + depth * 14) + 'px;font-size:11px">'
      + '只显示前 ' + r.vars.length + ' / ' + r.total + ' 条</div>';
  }
  return html;
}

function dbgVarToggle(path){
  var box = dbgEl('dbg-kids-' + path);
  if (!box) return;
  var open = !dbgVarOpen[path];
  dbgVarOpen[path] = open;
  var row = dbgEl('dbg-v-' + path);
  var arw = row ? row.querySelector('.arw') : null;
  if (arw) arw.textContent = open ? '▼' : '▶';
  if (!open) {
    box.innerHTML = '';
    // 收起时把子孙的展开态一起清掉，否则再展开时箭头是 ▼ 但内容空。
    Object.keys(dbgVarOpen).forEach(function(k){
      if (k.indexOf(path + '-') === 0) delete dbgVarOpen[k];
    });
    return;
  }
  var depth = path.split('-').length;
  var cached = dbgVarKids[path];
  if (cached) { box.innerHTML = dbgVarRowsHtml(cached, path, depth); return; }
  var objectId = dbgVarObj[path];
  if (!objectId) return;
  box.innerHTML = '<div class="muted" style="padding:2px 6px;font-size:11px">展开中…</div>';
  dbgOp('getObject', {objectId: objectId}).then(function(d){
    // 等待期间可能已收起 / 换帧重渲染：两个 id 都还在才落盘。
    var same = dbgEl('dbg-kids-' + path);
    if (!same || !dbgVarOpen[path]) return;
    if (!d || !d.ok) {
      same.innerHTML = '<div class="bad" style="padding:2px 6px;font-size:11px">展开失败：'
        + esc((d && d.error) || '请求失败') + '</div>';
      return;
    }
    var r = {vars: d.vars || [], total: d.total || 0, truncated: !!d.truncated};
    dbgVarKids[path] = r;
    same.innerHTML = dbgVarRowsHtml(r, path, depth);
  });
}

function dbgRenderVars(){
  // 换帧 / 刷新调用栈就重置展开态：objectId 属于上一次暂停，不能复用。
  dbgVarKids = {}; dbgVarOpen = {}; dbgVarObj = {}; dbgVarFold = {};
  dbgVarGen++;
  dbgVarScanAbort();
  dbgVarPaint();
}

// 按当前状态重画变量区。筛选输入只是重画（不重置缓存），否则每敲一个字
// 展开的层就会没。
function dbgVarPaint(){
  var el = dbgEl('dbg-vars');
  if (!el) return;
  var stat = dbgEl('dbg-var-fstat');
  var f = dbgFrames[dbgFrameIdx];
  var vars = (f && f.vars) || [];
  if (!vars.length) {
    if (stat) stat.textContent = '';
    el.innerHTML = '<div class="muted" style="padding:6px">'
      + (!dbgSt.paused ? '暂停后显示局部变量与 this'
        : (dbgStackLoaded ? '没有可见变量' : '读取中…')) + '</div>';
    return;
  }
  var q = dbgVarFilter;
  if (!q) {
    if (stat) stat.textContent = '';
    el.innerHTML = vars.map(function(v, i){ return dbgVarHtml(v, String(i), 0); }).join('');
    return;
  }
  var cnt = {n: 0, hid: 0};
  var html = vars.map(function(v, i){
    return dbgVarMatchHtml(v, String(i), 0, q, cnt);
  }).join('');
  var sc = dbgVarScanSt;
  if (stat) {
    stat.textContent = sc.run
      ? '筛选中… 已查 ' + sc.objs + ' 个对象'
      : (cnt.n + ' 条'
        + (cnt.hid ? ' · 隐藏 ' + cnt.hid + ' 个框架字段' : '')
        + (sc.capped ? '（已查 ' + sc.objs + ' 个对象，达到扫描上限）' : ''));
    stat.title = sc.run
      ? '正在把变量树整个拉下来按名字匹配，结果会边拉边补'
      : (cnt.hid ? '框架 / 依赖库里声明的字段被收起了，取消勾选「我的」可看'
        : (sc.capped
          ? '最多扫 ' + dbgVarScanObjCap + ' 个对象 / ' + dbgVarScanDepCap + ' 层，超出部分可能有遗漏'
          : ''));
  }
  if (html) { el.innerHTML = html; return; }
  var why;
  if (sc.run) {
    why = '正在把变量树拉下来…（已查 ' + sc.objs + ' 个对象）';
  } else {
    why = '没有名字含「' + esc(q) + '」的变量';
    if (cnt.hid) why += '（已隐藏 ' + cnt.hid + ' 个框架字段，取消勾选「我的」可看）';
    else if (sc.capped) why += '（已查 ' + sc.objs + ' 个对象，达到扫描上限；更深的层没扫到）';
    else if (sc.objs) why += '（已扫 ' + sc.objs + ' 个对象）';
  }
  el.innerHTML = '<div class="muted" style="padding:6px">' + why + '</div>';
}

// 筛选输入：先拿已有缓存重画，再把整棵树拉下来补齐（防抖 300ms，输入过程中不发请求）。
function dbgVarFilterOnInput(){
  var el = dbgEl('dbg-var-filter');
  dbgVarFilter = ((el && el.value) || '').trim().toLowerCase();
  dbgVarScanAbort();
  dbgVarPaint();
  if (!dbgVarFilter) return;
  dbgVarScanTimer = setTimeout(function(){
    dbgVarScanTimer = 0;
    dbgVarScanStart();
  }, 300);
}

function dbgVarFilterClear(){
  var el = dbgEl('dbg-var-filter');
  if (el) el.value = '';
  dbgVarFilter = '';
  dbgVarFold = {};
  dbgVarScanAbort();
  dbgVarPaint();
}

// 「我的」：只显示声明在自己项目里的字段；扫描也不往框架对象里钻。
function dbgVarMineToggle(){
  var el = dbgEl('dbg-var-mine');
  dbgVarMine = !el || el.checked;
  dbgVarPaint();
  // 从「只看我的」切到「全部」：之前被剪掉的框架层要补扫一轮（缓存里有的直接重用）。
  if (dbgVarFilter && !dbgVarScanSt.run) dbgVarScanStart();
}

// 作废正在跑的扫描：改筛选词、清空、换帧 / 刷栈都走这里。
function dbgVarScanAbort(){
  dbgVarScanSeq++;
  if (dbgVarScanTimer) { clearTimeout(dbgVarScanTimer); dbgVarScanTimer = 0; }
  dbgVarScanSt = {run: false, objs: 0, done: false, capped: false};
}

// 筛选模式：只留名字命中的节点，以及通往命中节点的祖先（祖先不计数，
// 箭头给 ▼ 表示下面是命中路径）。搜索范围是 `dbgVarKids` 缓存——
// 手动展开过的层 + dbgVarScanStart 自动拉下来的层（收起不丢缓存）。
// 命中的节点若子层还没拉过，给 ▶ 可手动补（扫描到它时也会自己拉）。
function dbgVarMatchHtml(v, path, depth, q, cnt){
  var r = dbgVarKids[path];
  var loaded = !!r;
  var kid = !!v.objectId;
  var kids = '';
  if (r && r.vars && r.vars.length) {
    kids = r.vars.map(function(c, i){
      return dbgVarMatchHtml(c, path + '-' + i, depth + 1, q, cnt);
    }).join('');
  }
  var self = String(v.name || '').toLowerCase().indexOf(q) >= 0;
  if (!self && !kids) return '';
  // 框架 / 依赖库里声明的字段：默认收起来只计数。
  // `ChangeNotifier._count`（监听器个数）这类和业务字段同名，不藏就是一片噪音。
  if (dbgVarMine && v.own === false) { cnt.hid++; return ''; }
  if (self) cnt.n++;
  if (kid) dbgVarObj[path] = v.objectId;
  var canLoad = kid && !loaded;
  var folded = dbgVarFold[path] === false;
  // 收起只是不渲染；cnt 上面已经递归算完，不然一条条收起会看到「3 条」变「1 条」。
  var shown = folded ? '' : kids;
  var attr;
  if (canLoad) {
    attr = ' onclick="dbgVarFilterLoad(\'' + path + '\')" title="点一下拉这一层，命中字段会补出来"';
  } else if (kids) {
    attr = ' onclick="dbgVarFoldToggle(\'' + path + '\')" title="'
      + (folded ? '点一下展开命中项' : '点一下收起这一段') + '"';
  } else {
    attr = ' title="筛选结果：清空筛选后可点开 / 收起字段"';
  }
  // 拉过但下面一条都不命中：说清楚，不然会以为筛选坏了。扫描中先不说，
  // 因为它自己马上会把子层拉下来。
  var note = (self && loaded && !kids && !dbgVarScanSt.run)
    ? '<div class="muted" style="padding:1px 6px 1px ' + (20 + depth * 14)
      + 'px;font-size:11px">下面没有名字含「' + esc(q) + '」的字段</div>'
    : '';
  var arrow = kids ? (folded ? '▶' : '▼') : (canLoad ? '▶' : '');
  return '<div class="dbg-var' + (canLoad || kids ? ' kid' : '') + '" id="dbg-v-' + path + '"'
    + ' style="padding-left:' + (6 + depth * 14) + 'px"' + attr + '>'
    + '<span class="arw">' + arrow + '</span>'
    + '<span class="fn" title="' + esc(v.name) + '">' + dbgVarMark(v.name, q) + '</span>'
    + '<span class="p" title="' + esc(v.value) + '">' + esc(v.value) + '</span>'
    + (v.type ? '<span class="muted" style="font-size:11px">' + esc(v.type) + '</span>' : '')
    + '</div>'
    + (shown ? '<div id="dbg-kids-' + path + '">' + shown + '</div>' : '')
    + note;
}

// 筛选结果里收起 / 展开一段：只改这份折叠表，不碰普通树的展开态。
function dbgVarFoldToggle(path){
  dbgVarFold[path] = dbgVarFold[path] === false;
  dbgVarPaint();
}

// 筛选态下点开一个还没拉过的命中节点：拉一层 → 记成展开 → 就地重画。
// 只有用户点才会走到这里，输入筛选词时一个请求都不发。
function dbgVarFilterLoad(path){
  var objectId = dbgVarObj[path] || '';
  if (!objectId || dbgVarKids[path]) return;
  var gen = dbgVarGen;
  dbgOp('getObject', {objectId: objectId}).then(function(d){
    // 等待期间可能换了帧 / 刷新了调用栈：缓存已重置，别把上一帧的对象塞进来。
    if (gen !== dbgVarGen) return;
    if (!d || !d.ok) return;
    dbgVarKids[path] = {vars: d.vars || [], total: d.total || 0, truncated: !!d.truncated};
    dbgVarOpen[path] = true;
    dbgVarPaint();
  });
}

// 按当前筛选词把整棵变量树拉下来：BFS + 每批 4 个 getObject，边拉边重画。
// 不拉的话「没展开过的层」永远搜不到；但整个 Element 树能大到没边，所以有上限
// （对象数 dbgVarScanObjCap / 深度 dbgVarScanDepCap），到顶就停并在状态栏说明。
// 同一个对象被多处引用时按 objectId 只拉一次，子项直接复用。
function dbgVarScanStart(){
  var f = dbgFrames[dbgFrameIdx];
  var vars = (f && f.vars) || [];
  if (!dbgVarFilter || !vars.length) return;
  var seq = ++dbgVarScanSeq;
  var st = dbgVarScanSt = {run: true, objs: 0, done: false, capped: false};
  var byObj = {};     // objectId → 已拉到的子项（同一对象多处引用只拉一次）
  var queue = [];
  function pushKids(path, depth, r){
    // 子项在 depth+1 层；再深就不会拉了，没必要塞进队列把队列撑大。
    // 但真有展开不下的子项时要记一笔，否则「0 条」会让人以为真没有。
    if (depth + 1 >= dbgVarScanDepCap) {
      (r.vars || []).forEach(function(c){ if (c && c.objectId) st.capped = true; });
      return;
    }
    (r.vars || []).forEach(function(c, i){
      if (!c || !c.objectId) return;
      // 框架 / 依赖对象（Element / RenderObject / Widget 子树）不扫：
      // 它能把 300 个对象的预算全烧光，还把一堆框架字段带进结果。
      if (dbgVarMine && c.fw) return;
      queue.push({path: path + '-' + i, depth: depth + 1, objectId: c.objectId});
    });
  }
  vars.forEach(function(v, i){
    if (v && v.objectId && !(dbgVarMine && v.fw)) {
      queue.push({path: String(i), depth: 0, objectId: v.objectId});
    }
  });
  dbgVarPaint();

  function step(){
    if (seq !== dbgVarScanSeq) return;    // 改词 / 清空 / 换帧：这轮作废
    if (!queue.length) { st.run = false; st.done = true; dbgVarPaint(); return; }
    if (st.objs >= dbgVarScanObjCap) { st.run = false; st.capped = true; dbgVarPaint(); return; }
    var batch = queue.splice(0, 4);
    var pending = batch.length;
    batch.forEach(function(it){
      function ok(){ if (--pending === 0) { if (seq !== dbgVarScanSeq) return; dbgVarPaint(); step(); } }
      var cached = dbgVarKids[it.path];
      if (cached) { pushKids(it.path, it.depth, cached); return ok(); }
      var same = byObj[it.objectId];
      if (same) { dbgVarKids[it.path] = same; pushKids(it.path, it.depth, same); return ok(); }
      // 深度到顶（理论上 pushKids 已经拦住了，这里再兜一层）
      if (it.depth >= dbgVarScanDepCap) { st.capped = true; return ok(); }
      st.objs++;
      dbgOp('getObject', {objectId: it.objectId}).then(function(d){
        if (seq !== dbgVarScanSeq) return;
        if (!d || !d.ok) return;
        var r = {vars: d.vars || [], total: d.total || 0, truncated: !!d.truncated};
        byObj[it.objectId] = r;
        dbgVarKids[it.path] = r;
        pushKids(it.path, it.depth, r);
      }).then(ok, ok);
    });
  }
  step();
}

// 名字里命中的那段包 <mark>（q 已经是小写）。
function dbgVarMark(name, q){
  var s = String(name || '');
  var i = q ? s.toLowerCase().indexOf(q) : -1;
  if (i < 0) return esc(s);
  return esc(s.slice(0, i)) + '<mark>' + esc(s.slice(i, i + q.length)) + '</mark>'
    + esc(s.slice(i + q.length));
}

function dbgFetchStack(){
  if (dbgStacking || !dbgSt.paused) return;
  dbgStacking = true;
  dbgOp('stack', {limit: 32}).then(function(d){
    dbgStacking = false;
    dbgStackLoaded = true;
    if (d && d.ok && d.frames) { dbgFrames = d.frames; dbgFrameIdx = 0; dbgRenderStack(); }
    else dbgRenderStack();
  }, function(){ dbgStacking = false; dbgStackLoaded = true; });
}

function dbgAddBp(btn){
  if (!dbgSt.attached) { dbgToast('还没连上调试会话：先「启动」或「接入」'); return; }
  var cond = (dbgEl('dbg-bp-cond').value || '').trim();
  var logMsg = (dbgEl('dbg-bp-log').value || '').trim();
  if (dbgEditBpId) {
    // 编辑态：位置不动，只提交条件 / 日志表达式（这两项 VM 不存，改的是客户端登记 + 落盘）。
    var saving = dbgBusy(btn, '保存中…');
    dbgOp('updateBreakpoint', {id: dbgEditBpId, condition: cond || null, logMessage: logMsg || null}).then(function(d){
      saving();
      if (d && d.ok) { dbgCancelBpEdit(); dbgLoadSaved(); }
    }, saving);
    return;
  }
  var path = (dbgEl('dbg-bp-path').value || '').trim();
  var line = parseInt(dbgEl('dbg-bp-line').value, 10);
  if (!path) { dbgToast('先填源码路径（可相对项目根，如 lib/main.dart）'); return; }
  if (!line || line < 1) { dbgToast('行号从 1 开始'); return; }
  var done = dbgBusy(btn, '添加中…');
  dbgOp('addBreakpoint', {path: path, line: line, condition: cond || null, logMessage: logMsg || null}).then(function(d){
    done();
    if (d && d.ok) {
      dbgEl('dbg-bp-line').value = '';
      dbgEl('dbg-bp-log').value = '';
      dbgLoadSaved();
    }
  }, done);
}

// 编辑断点的条件 / 日志表达式：回填到输入区，位置置只读（换位置请删了重加）。
function dbgEditBp(id){
  var b = null;
  (dbgSt.breakpoints || []).forEach(function(x){ if (x.id === id) b = x; });
  if (!b) { dbgToast('这条断点已不在清单里，先「刷新」'); return; }
  dbgEditBpId = id;
  dbgEl('dbg-bp-path').value = b.path || b.scriptUri || '';
  dbgEl('dbg-bp-line').value = b.line == null ? '' : b.line;
  dbgEl('dbg-bp-cond').value = b.condition || '';
  dbgEl('dbg-bp-log').value = b.logMessage || '';
  dbgEl('dbg-bp-path').readOnly = true;
  dbgEl('dbg-bp-line').readOnly = true;
  var add = dbgEl('dbg-bp-add');
  if (add) add.textContent = '保存修改';
  var cancel = dbgEl('dbg-bp-cancel');
  if (cancel) cancel.style.display = '';
  dbgToast('改完条件 / 日志表达式点「保存修改」；换位置请删除重加');
}

function dbgCancelBpEdit(){
  if (!dbgEditBpId) return;
  dbgEditBpId = '';
  dbgEl('dbg-bp-cond').value = '';
  dbgEl('dbg-bp-log').value = '';
  dbgEl('dbg-bp-line').value = '';
  dbgEl('dbg-bp-path').readOnly = false;
  dbgEl('dbg-bp-line').readOnly = false;
  var add = dbgEl('dbg-bp-add');
  if (add) add.textContent = '加断点';
  var cancel = dbgEl('dbg-bp-cancel');
  if (cancel) cancel.style.display = 'none';
}

function dbgToggleBp(id){ dbgOp('toggleBreakpoint', {id: id}).then(dbgLoadSaved); }
function dbgDelBp(id){ dbgOp('removeBreakpoint', {id: id}).then(dbgLoadSaved); }

var dbgBpAllBusy = false; // 「停用 / 启用全部」请求在途：别让连点发两次

// 断点区「停用全部 / 启用全部」的文案：还有启用的就显示「停用全部」，
// 全停了（或还没断点）才切到「启用全部」。
function dbgSyncBpAllBtn(bps){
  var el = dbgEl('dbg-bp-all');
  if (!el) return;
  bps = bps || dbgSt.breakpoints || [];
  var off = 0;
  for (var i = 0; i < bps.length; i++) if (bps[i].enabled === false) off++;
  var allOff = bps.length > 0 && off === bps.length;
  el.disabled = !bps.length || dbgBpAllBusy;
  el.textContent = allOff ? '启用全部' : '停用全部';
  el.title = !bps.length
    ? '当前会话还没有断点'
    : (allOff
      ? '一键启用当前会话的全部 ' + bps.length + ' 个断点'
      : '一键停用当前会话的全部断点（停用后仍保留，随时可以再启用）');
}

// 一键停用 / 启用全部断点（同 IDE 的「停用所有断点」）：断点不删，只切启停。
// 有停用中的就整批启用，否则整批停用（按钮文案由 dbgSyncBpAllBtn 按状态给）。
function dbgToggleAllBps(btn){
  if (dbgBpAllBusy) return;
  var bps = dbgSt.breakpoints || [];
  if (!bps.length) { dbgToast('当前会话还没有断点'); return; }
  var enable = true;
  for (var i = 0; i < bps.length; i++) {
    if (bps[i].enabled !== false) { enable = false; break; } // 还有启用的 → 全停用
  }
  dbgBpAllBusy = true;
  var done = dbgBusy(btn, enable ? '启用中…' : '停用中…');
  dbgOp('toggleAllBreakpoints', {enabled: enable}).then(function(d){
    dbgBpAllBusy = false;
    done();
    dbgSyncBpAllBtn();
    if (!d || d.ok === false) return; // 错误已由 dbgOp 提示
    if (d.message) dbgToast(d.message);
    dbgLoadSaved();
  });
}

// ── 源码面板：点行号下断点（不用手输 文件:行）─────────────────────────────
// 文件列表与内容都来自本机 GUI 后台（/api/fs/dartfiles、/api/fs/file），只读。
// 点行号 = 下断点 / 再点取消：已连会话走 addBreakpoint / removeBreakpoint，
// 没连会话走 rememberBreakpoint / forgetBreakpoint（下次启动 / 接入同一项目自动重下）。
var dbgSrcFiles = [];   // 项目内 .dart 相对路径
var dbgSrcRoot = '';    // 面板当前的项目根
var dbgSrcRel = '';     // 当前文件（相对项目根）
var dbgSrcAbs = '';     // 当前文件绝对路径（跟断点的 path 对齐）
var dbgSrcLoaded = 0;   // 已渲染行数（标记断点时不必遍历 DOM 行）
var dbgSrcKey = '';     // 当前文件标识：项目内相对路径 / 项目外 package: URI 或绝对路径
var dbgSrcOutside = false; // 当前文件在项目外（Flutter SDK / 依赖包）：只读跟随，不能下断点
var dbgSrcClosedAt = ''; // 用户主动收起面板时的「暂停键」：同一个暂停点不再自动弹回

function dbgSrcNormPath(p){
  return String(p == null ? '' : p).replace(/^file:\/\//, '').replace(/\\/g, '/').replace(/\/+$/, '');
}

// -- 路由栈（断点卡片内）：复用 /api/routestack + /api/routelocate ---------
// 目的：在断点区就能看到「当前调试会话」的路由与对应文件，点文件直接进源码
// 面板点行号，或直接点「断点」。只认 dbgSt.wsUri（不跟页头 VM 下拉），避免拿
// 到别的会话 / 旧端口的路由。
function dbgProjRoot(){
  var live = (dbgSt && dbgSt.attached && dbgSt.projectRoot) ? String(dbgSt.projectRoot) : '';
  return live || dbgDirValue() || (dbgSt && dbgSt.projectRoot) || '';
}
function dbgRtShort(file){
  var root = dbgSrcNormPath(dbgProjRoot());
  var abs = dbgSrcNormPath(file);
  if (root && abs.indexOf(root + '/') === 0) return abs.substring(root.length + 1);
  var parts = abs.split('/');
  return parts.length > 2 ? '…/' + parts.slice(-2).join('/') : abs;
}
function dbgRtLoad(btn){
  var box = dbgEl('dbg-routes');
  if (!box) return;
  var n = dbgEl('dbg-rt-n');
  var uri = (dbgSt && dbgSt.wsUri) ? String(dbgSt.wsUri) : '';
  if (!uri) {
    box.innerHTML = '<span class="muted">先连上调试会话（启动 / 接入），再点刷新</span>';
    if (n) n.textContent = '';
    return;
  }
  var done = dbgBusy(btn, '读取中…');
  box.innerHTML = '<span class="muted">读取路由栈…</span>';
  fetch('/api/routestack?uri=' + encodeURIComponent(uri))
    .then(function(r){ return r.json(); })
    .then(function(d){
      done();
      if (!d || d.error) {
        box.innerHTML = '<span class="bad">读取失败：' + esc((d && d.error) || '未知错误') + '</span>';
        return;
      }
      var flat = [];
      (d.navigators || []).forEach(function(nav){
        var rs = nav.routes || [];
        rs.forEach(function(r, i){ flat.push({nav: nav.index, idx: i, r: r}); });
      });
      if (!flat.length) {
        box.innerHTML = '<span class="muted">路由栈为空（app 可能还没建出首帧，或该会话不是 debug 模式）</span>';
        if (n) n.textContent = '';
        return;
      }
      if (n) n.textContent = flat.length + ' 条 · 来自当前调试会话';
      // 一条路由一块：首行序号 + 路由名（当前 / 类型）+ 跳转，次行文件，最后类名芯片。
      // 窄侧栏里分三行铺开，不再把「序号 / 名字 / 文件 / 跳转」硬挤在一行。
      box.innerHTML = flat.map(function(it, k){
        var name = it.r.name ? esc(it.r.name) : '<span class="muted">&lt;unnamed&gt;</span>';
        var cur = it.r.current ? ' <span class="dbg-rtcur">● 当前</span>' : '';
        var type = it.r.type ? ' <span class="dbg-rttype">' + esc(it.r.type) + '</span>' : '';
        return '<div class="dbg-rtitem">'
          + '<div class="dbg-rtrow">'
          + '<span class="dbg-rtidx">N' + (it.nav + 1) + '#' + (it.idx + 1) + '</span>'
          + '<span class="dbg-rtname">' + name + cur + type + '</span>'
          + '<a href="javascript:void(0)" id="dbg-rtj-' + k + '" class="dbg-rtjump" style="display:none">跳转</a>'
          + '</div>'
          + '<div class="dbg-rtfile">'
          + '<a href="javascript:void(0)" id="dbg-rtf-' + k + '" class="dbg-rtmiss">定位中…</a>'
          + '</div>'
          + '<div id="dbg-rtc-' + k + '" class="dbg-rtcls" style="display:none"></div>'
          + '</div>';
      }).join('');
      flat.forEach(function(it, k){ dbgRtLocate(uri, it, k); });
    })
    .catch(function(e){
      done();
      box.innerHTML = '<span class="bad">读取失败：' + esc(String(e)) + '</span>';
    });
}
function dbgRtLocate(uri, it, k){
  fetch('/api/routelocate?uri=' + encodeURIComponent(uri) + '&nav=' + it.nav + '&idx=' + it.idx + '&open=0')
    .then(function(r){ return r.json(); })
    .then(function(d){
      var a = dbgEl('dbg-rtf-' + k);
      if (!a) return;
      if (!d || d.error || !d.file) {
        a.className = 'dbg-rtmiss';
        a.textContent = '未定位到文件';
        a.title = rtLocErr((d && d.error) || '');
        return;
      }
      var file = String(d.file), line = d.line || 0;
      a.className = '';
      a.textContent = dbgRtShort(file) + (line ? ':' + line : '');
      a.title = file + (line ? ':' + line : '') + '（点击在下方源码面板打开，点行号即下断点）';
      a.onclick = function(){ dbgSrcOpenAt(file, line); };
      // 文件名仍开下方源码面板，「跳转」才是唤起 IDE（与路由栈 Tab 的「跳转」同一通道）。
      // 定位成功才知道路径，所以链接先占位隐藏，这里再填 data-file。
      var j = dbgEl('dbg-rtj-' + k);
      if (j) {
        j.style.display = '';
        j.setAttribute('data-file', file);
        j.setAttribute('data-line', String(line));
        j.title = '用配置的 IDE 打开 ' + file + (line ? ':' + line : '');
        j.onclick = function(){ dbgIdeJump(j, file, line); };
      }
      // Widget / State / VM / Notifier：单独一行，点名字在下方源码面板打开。
      if (d.className) dbgRtInfo(k, String(d.className), file);
    })
    .catch(function(e){
      var a = dbgEl('dbg-rtf-' + k);
      if (a) { a.className = 'dbg-rtmiss'; a.textContent = '定位失败'; a.title = String(e); }
    });
}

// Widget / State / VM / Notifier（与路由栈 Tab 同一套 /api/routeinfo 静态解析）。
// 每个类名点了就在下方源码面板打开并定到声明行（点行号即下断点）；名字后的
// 小 ◎ 跳「实例」Tab 查对象。位置来自 loc，找不到源码的降级为灰字不可点。
function dbgRtInfo(k, cls, file){
  fetch('/api/routeinfo?class=' + encodeURIComponent(cls) + '&file=' + encodeURIComponent(file))
    .then(function(r){ return r.json(); })
    .then(function(d){
      var box = dbgEl('dbg-rtc-' + k);
      if (!box || !d || !d.ok) return;
      var loc = d.loc || {};
      var names = [];
      if (d.widget) names.push(d.widget);
      if (d.state) names.push(d.state);
      (d.vm || []).forEach(function(n){ if (n) names.push(n); });
      (d.cn || []).forEach(function(n){ if (n) names.push(n); });
      // 一个类一个芯片：名字（可点开源码面板）在左，小 ◎（跳实例 Tab）在右。
      // 芯片之间靠 flex gap 留白，不用「/」串成一条，换行后也不会黏在一起。
      var parts = names.map(function(nm){
        var safe = escAttr(nm);
        var inst = '<a href="javascript:void(0)" class="dbg-rtchip-i"'
          + ' title="在「实例」Tab 查找 ' + safe + ' 的对象"'
          + ' onclick="rtToInstances(\'' + safe + '\')">◎</a>';
        var at = loc[nm];
        var label;
        if (at && at.file) {
          var pos = at.file + (at.line ? ':' + at.line : '');
          label = '<a href="javascript:void(0)"'
            + ' title="' + escAttr(pos + '（点开下方源码面板，点行号即下断点）') + '"'
            + ' data-file="' + escAttr(at.file) + '" data-line="' + (at.line || 0) + '"'
            + ' onclick="dbgSrcOpenAtEl(this)">' + esc(nm) + '</a>';
        } else {
          label = '<span class="muted" title="本机项目里没找到 ' + safe + ' 的源码（可能在依赖包 / SDK）">'
            + esc(nm) + '</span>';
        }
        return '<span class="dbg-rtchip">' + label + inst + '</span>';
      });
      if (!parts.length) return;
      box.style.display = '';
      box.innerHTML = parts.join('');
    })
    .catch(function(){});
}

// 绝对路径 → 项目内相对路径；前缀对不上时按后缀在候选里兑一个（防符号链接差异）。
function dbgSrcRelOf(p){
  var root = dbgSrcNormPath(dbgSrcRoot);
  var abs = dbgSrcNormPath(p);
  if (!abs) return '';
  if (root && abs.indexOf(root + '/') === 0) return abs.substring(root.length + 1);
  for (var i = 0; i < dbgSrcFiles.length; i++) {
    var rel = dbgSrcFiles[i];
    if (abs.length > rel.length && abs.slice(-(rel.length + 1)) === '/' + rel) return rel;
  }
  return '';
}

// 暂停帧要跳到哪：项目内用相对路径，项目外用 package: URI / 绝对路径。
// 单步进入 Flutter SDK / 依赖包时 IDE 也会把编辑器切过去，这里做同样的事。
function dbgSrcPauseTarget(){
  var f = (dbgSt.pause && dbgSt.pause.topFrame) || {};
  var p = dbgSrcNormPath(f.path || f.scriptUri || '');
  var line = f.line || 0;
  if (!p) return null;
  var rel = dbgSrcRelOf(p);
  if (rel) return {key: rel, mode: 'rel', line: line};
  if (/^package:/.test(p)) return {key: p, mode: 'pkg', line: line, outside: true};
  if (/(^\/|[A-Za-z]:\/)/.test(p) && /\.dart$/i.test(p)) {
    return {key: p, mode: 'abs', line: line, outside: true};
  }
  return null;
}

function dbgSrcOpen(){
  var card = dbgEl('dbg-src-card');
  if (!card) return;
  if (card.style.display !== 'none') { dbgSrcClose(); return; }
  // 断点下的是「当前会话」里的，所以面板优先跟会话的项目根；
  // 没连会话才用目录框（落盘清单按它分组）。两边不一致就把目录框同步过来，
  // 否则会拿 A 项目的源码列去给 B 项目下断点，点了没反应。
  var dir = dbgDirValue();
  var live = (dbgSt && dbgSt.attached && dbgSt.projectRoot) ? String(dbgSt.projectRoot) : '';
  var root = live || dir || (dbgSt && dbgSt.projectRoot) || '';
  if (!root) { dbgToast('先选项目目录（源码按项目根读）'); return; }
  dbgSrcRoot = root;
  if (live && dbgSrcNormPath(live) !== dbgSrcNormPath(dir)) {
    var box = dbgEl('dbg-dir');
    if (box) box.value = live;
    dbgLoadSaved();
    dbgToast('源码按当前调试会话打开：' + live);
  }
  card.style.display = '';
  dbgSrcLoadFiles();
}

// 从外部（如断点卡片的「路由栈」）给的「文件:行」直接打开源码面板并定位：
// 先按当前会话的项目根归一，再等文件列表到位（dbgSrcLoadFiles 会先渲染暂停
// 目标 / 默认文件），最后读目标文件——保证屏上留的是点的那一个。
function dbgSrcOpenAt(file, line){
  var card = dbgEl('dbg-src-card');
  if (!card) return;
  var root = dbgProjRoot();
  if (!root) { dbgToast('先选项目目录（源码按项目根读）'); return; }
  var changed = dbgSrcNormPath(dbgSrcRoot) !== dbgSrcNormPath(root);
  dbgSrcRoot = root;
  if (card.style.display === 'none') { card.style.display = ''; changed = true; }
  var rel = dbgSrcRelOf(file);
  var inp = dbgEl('dbg-src-file');
  if (inp) inp.value = rel || file;
  var load = function(){
    if (rel) dbgSrcLoad(rel, line || 0, 'rel');
    else dbgSrcLoad(file, line || 0, 'abs');
  };
  if (changed || !dbgSrcFiles.length) {
    var p = dbgSrcLoadFiles();
    if (p && p.then) p.then(load, load); else load();
  } else {
    load();
  }
}

// 行内链接统一入口：参数走 data-file / data-line（与 dbgIdeJumpEl 同一套）。
function dbgSrcOpenAtEl(el){
  if (!el) return;
  dbgSrcOpenAt(el.getAttribute('data-file') || '',
    parseInt(el.getAttribute('data-line'), 10) || 0);
}

function dbgSrcClose(){
  var card = dbgEl('dbg-src-card');
  if (card) card.style.display = 'none';
  // 记住是在哪个暂停点上收起的：同一个暂停点不要再被自动跟随弹回来
  dbgSrcClosedAt = dbgSt.paused ? dbgPauseKey(dbgSt.pause) : '';
  dbgSrcAbs = '';
  dbgSrcRel = '';
  dbgSrcKey = '';
  dbgSrcOutside = false;
  dbgSrcLoaded = 0;
}

function dbgSrcLoadFiles(){
  var dl = dbgEl('dbg-src-files');
  return fetch('/api/fs/dartfiles?root=' + encodeURIComponent(dbgSrcRoot))
    .then(function(r){ return r.json(); }).then(function(d){
      if (!d || d.ok === false) { dbgToast((d && d.message) || '列文件失败'); return; }
      dbgSrcFiles = d.files || [];
      if (dl) {
        dl.innerHTML = dbgSrcFiles.map(function(p){
          return '<option value="' + esc(p) + '"></option>';
        }).join('');
      }
      var inp = dbgEl('dbg-src-file');
      var t = dbgSrcPauseTarget();
      if (t) { if (inp) inp.value = t.key; return dbgSrcLoad(t.key, t.line, t.mode); }
      var cur = inp ? dbgSrcNormPath(inp.value) : '';
      var rel = dbgSrcFiles.indexOf(cur) >= 0 ? cur
        : (dbgSrcFiles.indexOf('lib/main.dart') >= 0 ? 'lib/main.dart' : (dbgSrcFiles[0] || ''));
      if (!rel) {
        var box = dbgEl('dbg-src-code');
        if (box) box.innerHTML = '<div class="muted" style="padding:8px">这个目录下没有 .dart 文件（先确认项目目录）</div>';
        return;
      }
      if (inp) inp.value = rel;
      return dbgSrcLoad(rel, 0);
    }).catch(function(e){ dbgToast('请求失败：' + e); });
}

// 输入框 → 项目内相对路径：全路径、部分路径、只给文件名都认，重名时让用户从下拉选。
function dbgSrcResolve(){
  var inp = dbgEl('dbg-src-file');
  var v = inp ? String(inp.value || '').trim() : '';
  if (!v) return '';
  var rel = dbgSrcRelOf(v) || dbgSrcNormPath(v);
  if (dbgSrcFiles.indexOf(rel) >= 0) return rel;
  var q = dbgSrcNormPath(rel);
  var hits = dbgSrcFiles.filter(function(p){
    return p === q
      || (q.length < p.length && p.slice(-(q.length + 1)) === '/' + q)
      || p.split('/').pop() === q;
  });
  if (hits.length === 1) return hits[0];
  if (hits.length > 1) {
    var lib = hits.filter(function(p){ return p.indexOf('lib/') === 0; });
    if (lib.length === 1) return lib[0];
    dbgToast('匹配到 ' + hits.length + ' 个文件，请从下拉里选：' + hits.slice(0, 3).join(' 、 '));
    return '';
  }
  return '';
}

function dbgSrcPick(){
  var rel = dbgSrcResolve();
  var inp = dbgEl('dbg-src-file');
  if (!rel) {
    if (inp && String(inp.value || '').trim()) dbgToast('没找到这个文件：先确认项目目录，或输入相对路径（如 lib/pages/a.dart）');
    return;
  }
  if (inp) inp.value = rel;
  dbgSrcLoad(rel, 0);
}

// mode: 'rel' 项目内相对路径 / 'pkg' package: URI / 'abs' 绝对路径
function dbgSrcLoad(key, line, mode){
  if (!dbgSrcRoot || !key) return;
  mode = mode || 'rel';
  var box = dbgEl('dbg-src-code');
  if (box) box.innerHTML = '<div class="muted" style="padding:8px">读取中…</div>';
  var url = '/api/fs/file?root=' + encodeURIComponent(dbgSrcRoot)
    + (mode === 'abs' ? '&abs=' : '&path=') + encodeURIComponent(key);
  return fetch(url)
    .then(function(r){ return r.json(); }).then(function(d){
      if (!d || d.ok === false) {
        dbgSrcAbs = ''; dbgSrcRel = ''; dbgSrcKey = ''; dbgSrcOutside = false;
        dbgSrcLoaded = 0;
        if (box) box.innerHTML = '<div class="muted" style="padding:8px">' + esc((d && d.message) || '读文件失败') + '</div>';
        return;
      }
      dbgSrcOutside = !!d.outside;
      dbgSrcRel = d.outside ? '' : (d.rel || key);
      dbgSrcAbs = d.abs || '';
      dbgSrcKey = d.outside ? key : dbgSrcRel;
      dbgSrcRender(d);
      if (line) dbgSrcReveal(line);
    }).catch(function(e){
      if (box) box.innerHTML = '<div class="muted" style="padding:8px">请求失败：' + esc('' + e) + '</div>';
    });
}

// 项目外文件只留 lib/ 之后那段（Flutter SDK 的绝对路径太长）。
function dbgSrcShortPath(p){
  var s = dbgSrcNormPath(p);
  var i = s.indexOf('/lib/');
  if (i >= 0) return s.substring(i + 5);
  var parts = s.split('/');
  return parts.slice(-2).join('/');
}

function dbgSrcRender(d){
  var box = dbgEl('dbg-src-code');
  if (!box) return;
  var lines = d.lines || [];
  dbgSrcLoaded = lines.length;
  var html = '';
  for (var i = 0; i < lines.length; i++) {
    var n = i + 1;
    html += '<div class="dbg-cl" data-line="' + n + '">'
      + '<span class="no" title="点行号下断点 / 再点取消">' + n + '</span>'
      + '<span class="tx">' + (lines[i] === '' ? ' ' : esc(lines[i])) + '</span>'
      + '<span class="mk"></span></div>';
  }
  box.innerHTML = html || '<div class="muted" style="padding:8px">文件是空的</div>';
  var info = dbgEl('dbg-src-info');
  if (info) {
    var name = d.outside
      ? '项目外（Flutter SDK / 依赖包）· ' + dbgSrcShortPath(d.abs || '')
      : (d.rel || '');
    info.textContent = name + ' · ' + (d.total || lines.length) + ' 行'
      + (d.truncated ? '（只显示前 ' + lines.length + ' 行）' : '')
      + (d.outside ? ' · 只读跟随当前帧，不能下断点'
                   : ' · 点行号下断点 / 再点取消（顶部填了条件 / 日志就按下对应类型）');
    info.title = d.abs || '';
  }
  dbgSrcMark();
}

function dbgSrcReveal(line){
  var box = dbgEl('dbg-src-code');
  if (!box || !line) return;
  var row = box.querySelector('.dbg-cl[data-line="' + line + '"]');
  if (row && row.scrollIntoView) row.scrollIntoView({block:'center'});
}

// 这一行是当前文件的断点吗（会话断点与已记住清单共用一套匹配）。
function dbgSrcHit(b, line){
  if (!b || b.line !== line) return false;
  var p = dbgSrcNormPath(b.path || b.scriptUri || '');
  if (!p) return false;
  if (p === dbgSrcNormPath(dbgSrcAbs)) return true;
  if (!dbgSrcRel) return false;
  return p.length > dbgSrcRel.length && p.slice(-(dbgSrcRel.length + 1)) === '/' + dbgSrcRel;
}

function dbgSrcMark(){
  var box = dbgEl('dbg-src-code');
  if (!box || !dbgSrcAbs || !dbgSrcLoaded) return;
  var live = {}, saved = {};
  for (var n = 1; n <= dbgSrcLoaded; n++) {
    for (var i = 0; i < (dbgSt.breakpoints || []).length; i++) {
      if (dbgSrcHit(dbgSt.breakpoints[i], n)) { live[n] = dbgSt.breakpoints[i]; break; }
    }
    for (var j = 0; j < (dbgSavedList || []).length; j++) {
      if (dbgSrcHit(dbgSavedList[j], n)) { saved[n] = dbgSavedList[j]; break; }
    }
  }
  var curLine = 0;
  if (dbgSt.paused) {
    // 统一用暂停帧的「文件标识」比：项目外是 package: URI / 绝对路径，
    // 而面板里的 dbgSrcAbs 已经被后端解析成真实路径，直接比会永远不相等。
    var t = dbgSrcPauseTarget();
    if (t && t.key === dbgSrcKey && t.line) curLine = t.line;
  }
  var rows = box.querySelectorAll('.dbg-cl');
  for (var k = 0; k < rows.length; k++) {
    var ln = parseInt(rows[k].getAttribute('data-line'), 10) || 0;
    var b = live[ln];
    rows[k].classList.toggle('bp', !!b);
    rows[k].classList.toggle('saved', !b && !!saved[ln]);
    rows[k].classList.toggle('cur', ln === curLine);
    var mk = rows[k].querySelector('.mk');
    if (mk) mk.textContent = b ? (b.enabled === false ? '○' : '●') : (saved[ln] ? '·' : '');
  }
}

// 点行号：下 / 取消。没连会话时只动「已记住」清单。
function dbgSrcToggle(line){
  if (!dbgSrcAbs) return;
  if (!dbgSrcRel || dbgSrcOutside) {
    dbgToast('项目外文件（Flutter SDK / 依赖包）只读跟随当前帧，不能下断点');
    return;
  }
  var hit = null;
  (dbgSt.breakpoints || []).forEach(function(b){ if (dbgSrcHit(b, line)) hit = b; });
  if (hit) {
    if (!dbgSt.attached) { dbgToast('这条断点属于当前会话：先「接入」再删'); return; }
    dbgOp('removeBreakpoint', {id: hit.id}).then(function(d){ if (d && d.ok) dbgLoadSaved(); });
    return;
  }
  var saved = null;
  (dbgSavedList || []).forEach(function(b){ if (dbgSrcHit(b, line)) saved = b; });
  if (!dbgSt.attached) {
    if (saved) {
      dbgOp('forgetBreakpoint', {dir: dbgSrcRoot, path: dbgSrcAbs, line: line})
        .then(function(d){ if (d && d.ok) dbgLoadSaved(); });
      return;
    }
    var c0 = (dbgEl('dbg-src-cond').value || '').trim();
    var l0 = (dbgEl('dbg-src-log').value || '').trim();
    dbgOp('rememberBreakpoint', {dir: dbgSrcRoot, path: dbgSrcAbs, line: line, condition: c0 || null, logMessage: l0 || null})
      .then(function(d){ if (d && d.ok) dbgLoadSaved(); });
    return;
  }
  var cond = (dbgEl('dbg-src-cond').value || '').trim();
  var logm = (dbgEl('dbg-src-log').value || '').trim();
  dbgOp('addBreakpoint', {path: dbgSrcAbs, line: line, condition: cond || null, logMessage: logm || null})
    .then(function(d){ if (d && d.ok) dbgLoadSaved(); });
}

// 暂停 / 命中断点时跟着跳到对应文件的行（IDE 的「跟随当前帧」）。
// 步进（跳过 / 进入 / 跳出）后也会走到这里：同文件只挪黄色当前行，
// 换文件（包括单步进入 Flutter SDK / 依赖包）就自动切过去。
function dbgSrcFollowPause(){
  var card = dbgEl('dbg-src-card');
  if (!card) return;
  if (card.style.display === 'none') {
    // 面板默认是关的（重启 GUI 后就是关的）：命中断点 / 单步暂停不自动打开，
    // 就完全看不到断点在哪（断点卡片里只有一个「文件:行」）。这里跟 IDE 一样
    // 自动打开并定位；但用户在**这个暂停点**上主动收起的就不再弹回来，
    // 换个断点 / 下次暂停照常自动开。
    var pk = dbgSt.paused ? dbgPauseKey(dbgSt.pause) : '';
    if (!pk || pk === dbgSrcClosedAt) return;
    // 面板没开过时 dbgSrcRoot 还是空（或上一个项目），先对齐当前会话的项目根，
    // 否则暂停帧会被当成项目外文件、定位不到行。
    var root = dbgProjRoot();
    if (!root) return;
    dbgSrcRoot = root;
    card.style.display = '';
    dbgSrcLoadFiles();
    return;
  }
  var t = dbgSrcPauseTarget();
  if (!t) { dbgSrcMark(); return; }
  if (t.key === dbgSrcKey) { dbgSrcMark(); dbgSrcReveal(t.line); return; }
  var inp = dbgEl('dbg-src-file');
  if (inp) inp.value = t.key;
  dbgSrcLoad(t.key, t.line, t.mode);
}

(function(){
  var box = dbgEl('dbg-src-code');
  if (!box) return;
  box.addEventListener('click', function(ev){
    var el = ev.target;
    while (el && el !== box && !(el.classList && el.classList.contains('no'))) el = el.parentElement;
    if (!el || el === box) return;
    var row = el.parentElement;
    var n = row ? parseInt(row.getAttribute('data-line'), 10) : 0;
    if (n) dbgSrcToggle(n);
  });
})();


function dbgListBp(btn){
  var done = dbgBusy(btn, '刷新中…');
  dbgOp('listBreakpoints', {}).then(done, done);
}

function dbgEval(){
  var out = dbgEl('dbg-eval-out');
  var expr = (dbgEl('dbg-eval').value || '').trim();
  if (!expr) return;
  if (!dbgSt.paused) { dbgToast('先暂停（命中断点）再求值'); return; }
  out.className = 'muted';
  out.textContent = '求值中…';
  out.title = '';
  dbgOp('eval', {expression: expr, frameIndex: dbgFrameIdx}).then(function(d){
    if (!d) return;
    if (d.ok) {
      out.className = '';
      out.textContent = expr + ' = ' + d.value;
    } else {
      out.className = 'bad';
      // VM 的编译错误很长（synthetic_debug_expression + 来源包 + 标准建议），
      // 压成一句「类 X 没有成员 Y」，原文收进悬停。
      var h = dbgEvalErrHint(d, expr);
      out.textContent = h.text;
      out.title = h.raw;
    }
  });
}

// 求值失败 → 一行可读的原因 + 最可能的正确写法。
// 三种错误很常见，各给一份提示：
//   ① 拼写错（runTimeType）—— 后端按本机源码算的 suggest；
//   ② 写错对象（controller.controlFinishLoad，而它在 refreshController 上）
//      —— 在已展开的变量树里找同名字段，直接给完整表达式；
//   ③ 私有成员（this.controller._count）—— 不是写错，是读不到：Dart 的私有名
//      按库区分，求值表达式编译在合成库里，别的库的 `_x` 根本解析不到。
function dbgEvalErrHint(d, expr){
  var raw = String((d && d.error) || '求值失败');
  var m = /'([A-Za-z_$][\w$]*)' isn't defined for the class '([A-Za-z_$][\w$]*)'/.exec(raw);
  if (!m) return { text: raw, raw: raw };
  var member = m[1], cls = m[2];
  if (member.charAt(0) === '_') {
    // 反查出来的同名路径正是用户刚试过的写法，「试试 xxx」只会自指。
    return {
      text: cls + ' 的私有成员 ' + member + ' 在表达式里读不到（Dart 私有名按库区分）；'
        + '它的值在变量树 / 「实例」Tab 里能直接看',
      raw: raw,
    };
  }
  var typed = dbgNormExpr(expr);
  var tips = [];
  var alt = dbgVarFindMember(member);
  if (alt && dbgNormExpr(alt) !== typed) tips.push(alt);
  var sug = (d && d.suggest) || [];
  for (var i = 0; i < sug.length && i < 2; i++) {
    if (!sug[i] || sug[i].charAt(0) === '_') continue;
    // 后端给的是成员名（runtimeType），要拼回用户那一行才是能直接粘的表达式
    // （controller.runTimeType → controller.runtimeType）。
    var fixed = dbgFixTail(expr, member, sug[i]);
    // 等于用户输入的也别给（同一个表达式再试一次还是同样报错）。
    if (dbgNormExpr(fixed) === typed || tips.indexOf(fixed) >= 0) continue;
    tips.push(fixed);
  }
  return {
    text: cls + ' 没有成员 ' + member + (tips.length ? '；试试 ' + tips.join(' / ') : ''),
    raw: raw,
  };
}

// 把表达式最后一段（= 报错的成员名）换成建议的成员名：
// controller.runTimeType → controller.runtimeType；对不上就只返回名字。
function dbgFixTail(expr, member, sug){
  var e = String(expr || '').trim();
  if (e.length > member.length && e.slice(e.length - member.length) === member) {
    var head = e.slice(0, e.length - member.length);
    if (/[.\w$]\s*$/.test(head)) return head + sug;
  }
  return sug;
}

// 比「建议」与「用户输入」是否同一个表达式：忽略空白与 this. 前缀
// （this.controller._count ≡ controller._count）。
function dbgNormExpr(s){
  return String(s || '').replace(/\s+/g, '').replace(/^this\./, '');
}

// 在「已展开」的变量树里找谁的字段叫这个名字，返回可复制进输入框的表达式。
// 只看已加载过的层：没展开的要再打一次 getObject，求值报错时不该再发请求。
function dbgVarFindMember(member){
  var f = dbgFrames[dbgFrameIdx];
  var roots = (f && f.vars) || [];
  for (var i = 0; i < roots.length; i++){
    if (roots[i] && roots[i].name === member) return member;
  }
  var paths = Object.keys(dbgVarKids);
  for (var k = 0; k < paths.length; k++){
    var r = dbgVarKids[paths[k]];
    if (!r || !r.vars) continue;
    for (var j = 0; j < r.vars.length; j++){
      if (!r.vars[j] || r.vars[j].name !== member) continue;
      var base = dbgVarPathExpr(paths[k]);
      if (base) return base + '.' + member;
    }
  }
  return '';
}

// 变量树 path（"2" / "2-1"）→ 可求值的表达式（refreshController.controlFinishLoad）。
function dbgVarPathExpr(path){
  var segs = String(path).split('-');
  var f = dbgFrames[dbgFrameIdx];
  var out = [];
  for (var i = 0; i < segs.length; i++){
    var r = i === 0
      ? { vars: (f && f.vars) || [] }
      : dbgVarKids[segs.slice(0, i).join('-')];
    if (!r || !r.vars) return '';
    var v = r.vars[parseInt(segs[i], 10)];
    if (!v) return '';
    out.push(v.name);
  }
  return out.join('.');
}

function dbgStart(btn){
  var dir = (dbgEl('dbg-dir').value || '').trim();
  var dev = (dbgEl('dbg-device').value || '').trim() || dbgDesktop();
  var target = (dbgEl('dbg-target').value || '').trim();
  if (!dir) { dbgToast('先填项目目录（含 pubspec.yaml）'); return; }
  var done = dbgBusy(btn, '启动中…');
  var msg = dbgEl('dbg-msg');
  if (msg) msg.textContent = '正在启动 flutter run -d ' + dev + '（首次编译较慢，输出区有进度）…';
  dbgOp('start', {cwd: dir, device: dev, target: target || null, platform: dbgPlatformOf(dev) || null}).then(done, done);
}

function dbgStop(btn){
  var done = dbgBusy(btn, '停止中…');
  dbgOp('stop', {}).then(done, done);
}

function dbgAttach(btn){
  var sel = dbgEl('dbg-attach');
  var i = sel ? parseInt(sel.value, 10) : NaN;
  var s = isNaN(i) ? null : dbgAttachList[i];
  if (!s) { dbgToast('先选一条已接入的调试会话（没有就点右上「刷新」）'); return; }
  var done = dbgBusy(btn, '接入中…');
  dbgOp('attach', {wsUri: s.uri, projectRoot: s.projectRoot || ''}).then(done, done);
}

function dbgDetach(btn){
  var done = dbgBusy(btn, '断开中…');
  dbgOp('detach', {}).then(done, done);
}

function dbgPause(){ dbgOp('pause', {}); }
function dbgResume(step){ dbgOp('resume', step ? {step: step} : {}); }
function dbgHot(restart){ dbgOp('hot', {restart: !!restart}); }

// 输出区：status 回全量（带 outSeq），WS 增量 push；旧快照不回退。
function dbgOutSet(lines, seq){
  if (seq != null && seq < dbgOutSeq) return;
  if (seq != null) dbgOutSeq = seq;
  dbgOutLines = (lines || []).slice(-2000);
  dbgOutRender();
}

function dbgOutAppend(lines, seq){
  if (seq != null) dbgOutSeq = seq;
  (lines || []).forEach(function(l){ dbgOutLines.push(l); });
  if (dbgOutLines.length > 2000) dbgOutLines = dbgOutLines.slice(-2000);
  dbgOutRender();
}

// 运行输出查找 / 筛选（同「文件查看」页）：查找只高亮不过滤，筛选只留匹配行，
// 两个都填时同时命中的片段显示橙色。关键词变了 120ms 防抖再重绘，不逐字扫 2000 行。
var dbgOutQ = { s: '', f: '' }, dbgOutQTimer = null;
function dbgOutQuery(kind, val){
  if (kind === 'f') dbgOutQ.f = val || ''; else dbgOutQ.s = val || '';
  if (dbgOutQTimer) clearTimeout(dbgOutQTimer);
  dbgOutQTimer = setTimeout(function(){ dbgOutQTimer = null; dbgOutRender(); }, 120);
}
// 输出区专用转义（正则版）：DOM 版 esc 每行都 createElement，两千行重绘太贵。
function dbgOutEsc(s){
  return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
// 一行的高亮片段：查找（1）=黄、筛选（2）=绿、同时命中（3）=橙；交叉区间先合并再着色。
function dbgOutHlLine(line, s, f){
  var l = line.toLowerCase(), marks = [];
  function collect(kw, tag){
    if (!kw) return;
    var j = 0;
    while (true) { var k = l.indexOf(kw, j); if (k < 0) break; marks.push([k, k + kw.length, tag]); j = k + kw.length; }
  }
  collect(s, 1); collect(f, 2);
  if (!marks.length) return dbgOutEsc(line);
  marks.sort(function(a, b){ return a[0] - b[0] || a[1] - b[1]; });
  var merged = [];
  for (var i = 0; i < marks.length; i++) {
    var m = merged[merged.length - 1];
    if (m && marks[i][0] < m[1]) { if (marks[i][1] > m[1]) m[1] = marks[i][1]; m[2] |= marks[i][2]; }
    else merged.push([marks[i][0], marks[i][1], marks[i][2]]);
  }
  var out = '', at = 0;
  for (var j = 0; j < merged.length; j++) {
    var cls = merged[j][2] === 2 ? ' class="mf"' : (merged[j][2] === 3 ? ' class="mb"' : '');
    out += dbgOutEsc(line.substring(at, merged[j][0])) + '<mark' + cls + '>' + dbgOutEsc(line.substring(merged[j][0], merged[j][1])) + '</mark>';
    at = merged[j][1];
  }
  return out + dbgOutEsc(line.substring(at));
}

// 当前筛选下要显示的行（没筛选就是全部）；渲染与复制共用，避免两处判定漂移。
function dbgOutShown(){
  var f = dbgOutQ.f.toLowerCase();
  if (!f) return dbgOutLines;
  var out = [];
  for (var i = 0; i < dbgOutLines.length; i++) {
    if (dbgOutLines[i].toLowerCase().indexOf(f) >= 0) out.push(dbgOutLines[i]);
  }
  return out;
}

function dbgOutRender(){
  var el = dbgEl('dbg-out');
  if (!el) return;
  var s = dbgOutQ.s.toLowerCase(), f = dbgOutQ.f.toLowerCase();
  // 粘底（同「文件查看」）：本来就在底部才跟到新行，手动翻上去看历史时不被新行拽回去。
  var follow = dbgEl('dbg-follow');
  var stick = (!follow || follow.checked) && (el.scrollTop + el.clientHeight >= el.scrollHeight - 24);
  var n = dbgEl('dbg-out-n');
  if (!s && !f) {
    // 没查找 / 筛选：走原来的纯文本路径（两千行也不必逐行转义）
    el.textContent = dbgOutLines.join('\n');
    if (stick) el.scrollTop = el.scrollHeight;
    if (n) n.textContent = dbgOutLines.length ? '（' + dbgOutLines.length + ' 行）' : '';
    return;
  }
  var rows = dbgOutShown(), hits = 0, parts = [];
  for (var i = 0; i < rows.length; i++) {
    var line = rows[i];
    if (s) {
      var l = line.toLowerCase(), j = 0;
      while (true) { var k = l.indexOf(s, j); if (k < 0) break; hits++; j = k + s.length; }
    }
    parts.push(dbgOutHlLine(line, s, f));
  }
  el.innerHTML = parts.length ? parts.join('\n') : '<span class="muted">（' + (dbgOutLines.length ? '无匹配行' : '暂无内容') + '）</span>';
  if (stick) el.scrollTop = el.scrollHeight;
  if (n) {
    if (!dbgOutLines.length) n.textContent = '';
    else n.textContent = '（' + (f ? rows.length + ' / ' + dbgOutLines.length + ' 行' : dbgOutLines.length + ' 行') + (s ? ' · 命中 ' + hits + ' 处' : '') + '）';
  }
}

function dbgClearOut(){ dbgOutLines = []; dbgOutRender(); }

// 复制当前框里显示的内容：有筛选就只复制筛选后的行（同日志 Tab 的「复制」）。
// clipboard API 不可用 / 被拒时走 copyLogsFallback（隐藏 textarea + execCommand）。
function dbgOutCopy(btn){
  var lines = dbgOutShown();
  if (!lines.length) {
    btn.textContent = '无输出';
    setTimeout(function(){ btn.textContent = '复制'; }, 1200);
    return;
  }
  var text = lines.join('\n');
  var done = function(){ btn.textContent = '已复制 ' + lines.length + ' 行'; setTimeout(function(){ btn.textContent = '复制'; }, 1500); };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(done, function(){ copyLogsFallback(text); done(); });
  } else { copyLogsFallback(text); done(); }
}

// 运行输出面板高度：拖卡片上沿调整（同 VS Code 终端），双击手柄复位，值记到 localStorage。
// 高度写在 #page-debug 的 --dbg-out-h 上，.dbg-outcard 用它（没设过就回 clamp 默认）。
var dbgOutHKey = 'xbume_dbg_out_h';
function dbgOutHSaved(){ try { var v = parseInt(localStorage.getItem(dbgOutHKey) || '', 10); return v > 0 ? v : 0; } catch (e) { return 0; } }
function dbgOutHClamp(h){
  var page = document.getElementById('page-debug');
  if (!page) return h;
  // 上限：至少给工具条 + 三栏留 300px，否则变量树 / 断点区会被压成一条缝。
  // 基数取「页面高度」与「外层滚动容器（main）高度」的较小值：窗口矮 / 窄时页面
  // 退回整页滚、高度是内容高度，只用它算会越拖越大（拖一下就吃掉整屏）。
  var box = page.parentElement;
  var avail = Math.min(page.clientHeight || 0, (box && box.clientHeight) || 0) || window.innerHeight;
  var tools = page.querySelector('.dbg-tools');
  var max = Math.max(180, avail - ((tools ? tools.offsetHeight : 190) + 330));
  return Math.max(96, Math.min(Math.round(h), max));
}
function dbgOutHApply(h){
  var page = document.getElementById('page-debug');
  if (!page) return;
  if (h > 0) page.style.setProperty('--dbg-out-h', h + 'px');
  else page.style.removeProperty('--dbg-out-h');
}
function dbgOutHSave(h){ try { h > 0 ? localStorage.setItem(dbgOutHKey, String(h)) : localStorage.removeItem(dbgOutHKey); } catch (e) {} }
function dbgOutHReset(){ dbgOutHApply(0); dbgOutHSave(0); }
function dbgOutHDrag(e){
  var card = document.querySelector('.dbg-outcard');
  if (!card || e.button !== 0) return;
  e.preventDefault();
  var grip = e.currentTarget;
  var y0 = e.clientY, h0 = card.getBoundingClientRect().height;
  if (grip && grip.classList) grip.classList.add('on');
  var mv = function(ev){ dbgOutHApply(dbgOutHClamp(h0 + (y0 - ev.clientY))); };
  var up = function(){
    window.removeEventListener('pointermove', mv);
    window.removeEventListener('pointerup', up);
    if (grip && grip.classList) grip.classList.remove('on');
    document.body.style.userSelect = '';
    dbgOutHSave(Math.round(card.getBoundingClientRect().height));
    var el = document.getElementById('dbg-out'), f = document.getElementById('dbg-follow');
    if (el && (!f || f.checked)) el.scrollTop = el.scrollHeight;
  };
  document.body.style.userSelect = 'none';
  window.addEventListener('pointermove', mv);
  window.addEventListener('pointerup', up);
}
(function(){
  var h = dbgOutHSaved();
  if (h > 0) dbgOutHApply(dbgOutHClamp(h));
  // 窗口变矮后旧高度可能超过上限，拉回来（不动存储值，窗口回去了下次拖动再定）
  window.addEventListener('resize', function(){
    if (!dbgOutHSaved()) return;
    var card = document.querySelector('.dbg-outcard');
    if (!card) return;
    var cur = card.getBoundingClientRect().height;
    var want = dbgOutHClamp(cur);
    if (Math.abs(want - cur) > 1) dbgOutHApply(want);
  });
})();
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
