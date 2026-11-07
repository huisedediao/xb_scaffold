// MCP 传输层：stdio（换行分隔 JSON-RPC）+ Streamable HTTP。
//
// stdio 模式：stdin 每行一条 JSON-RPC 消息，stdout 每行一条响应；日志一律
// 写 stderr，否则会破坏协议流。
//
// HTTP 模式：POST /mcp 返回 application/json（单条响应，不起 SSE），
// GET /mcp 405，DELETE /mcp 释放会话；仅绑定 127.0.0.1，校验 Host 与 token。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../paths.dart';
import '../session/capability.dart';
import 'client_scope.dart';
import 'protocol.dart';
import 'tools.dart';

class McpServer {
  McpServer({
    required this.ctx,
    required this.version,
    required this.tools,
    this.token = '',
  });

  final McpToolContext ctx;
  final String version;

  /// 已按 --tool-groups 过滤后的工具清单（core 恒在）。
  final List<McpTool> tools;

  /// HTTP 模式鉴权 token；空串表示不校验（stdio 模式）。
  final String token;

  final Map<String, McpTool> _byName = <String, McpTool>{};
  IOSink? _auditSink;

  void init() {
    for (final t in tools) {
      _byName[t.name] = t;
    }
  }

  List<McpTool> get enabledTools => tools;

  // ── stdio ──

  Future<void> serveStdio() async {
    final lines = stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      final text = line.trim();
      if (text.isEmpty) continue;
      Object? raw;
      try {
        raw = jsonDecode(text);
      } catch (e) {
        _write(mcpError(null, kMcpParseError, 'JSON 解析失败：$e'));
        continue;
      }
      final response = await handleMessage(raw, client: 'stdio');
      if (response != null) _write(response);
    }
  }

  void _write(Map<String, Object?> msg) {
    stdout.writeln(jsonEncode(msg));
  }

  // ── Streamable HTTP ──

  /// 启动 HTTP 服务；端口占用时抛 SocketException（由入口给出可读提示）。
  Future<HttpServer> serveHttp(int port) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    unawaited(_acceptLoop(server));
    return server;
  }

  Future<void> _acceptLoop(HttpServer server) async {
    await for (final req in server) {
      unawaited(_handleHttp(req));
    }
  }

  Future<void> _handleHttp(HttpRequest req) async {
    try {
      if (req.uri.path != '/mcp') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      // Host 校验：只服务本机回环（防 DNS rebinding）。
      final host = (req.headers.value(HttpHeaders.hostHeader) ?? '').toLowerCase();
      final hostOk = host.isEmpty ||
          host.startsWith('127.0.0.1') ||
          host.startsWith('localhost') ||
          host.startsWith('[::1]');
      if (!hostOk) {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      if (!_tokenOk(req)) {
        req.response.statusCode = HttpStatus.unauthorized;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(<String, Object?>{
          'error': '无效 token',
          'hint': '从 ${tokenFile().path} 读取，放到 X-XBUME-Token 或 Authorization: Bearer',
        }));
        await req.response.close();
        return;
      }
      switch (req.method) {
        case 'POST':
          final body = await utf8.decoder.bind(req).join();
          Object? raw;
          try {
            raw = jsonDecode(body);
          } catch (e) {
            _json(req.response, mcpError(null, kMcpParseError, 'JSON 解析失败：$e'),
                status: HttpStatus.badRequest);
            return;
          }
          final sessionId = _ensureSessionId(req);
          // 「当前会话」按连接隔离：HTTP 用客户端回传的 Mcp-Session-Id。
          // 不回的客户端拿空串（退回共享当前会话，与旧版一致）。
          final client = req.headers.value('Mcp-Session-Id') ?? '';
          final response = await handleMessage(raw, client: client);
          req.response.headers.set('Mcp-Session-Id', sessionId);
          if (response == null) {
            req.response.statusCode = HttpStatus.accepted;
            await req.response.close();
            return;
          }
          _json(req.response, response);
          return;
        case 'GET':
          // 不提供 SSE 流：明确 405，避免客户端长连接挂死。
          req.response.statusCode = HttpStatus.methodNotAllowed;
          req.response.headers.set(HttpHeaders.allowHeader, 'POST, DELETE');
          await req.response.close();
          return;
        case 'DELETE':
          req.response.headers.set('Mcp-Session-Id', _ensureSessionId(req));
          req.response.statusCode = HttpStatus.ok;
          await req.response.close();
          return;
        default:
          req.response.statusCode = HttpStatus.methodNotAllowed;
          await req.response.close();
          return;
      }
    } catch (e) {
      try {
        _json(req.response,
            mcpError(null, kMcpInternalError, '服务端异常：$e'),
            status: HttpStatus.internalServerError);
      } catch (_) {
        // 响应已关闭，忽略。
      }
    }
  }

  void _json(HttpResponse res, Map<String, Object?> body,
      {int status = HttpStatus.ok}) {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    unawaited(res.close());
  }

  bool _tokenOk(HttpRequest req) {
    if (token.isEmpty) return true;
    final direct = req.headers.value('X-XBUME-Token');
    if (direct == token) return true;
    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (auth.toLowerCase().startsWith('bearer ')) {
      return auth.substring(7).trim() == token;
    }
    return false;
  }

  String _ensureSessionId(HttpRequest req) {
    final existing = req.headers.value('Mcp-Session-Id');
    if (existing != null && existing.isNotEmpty) return existing;
    return 'xb-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
  }

  // ── 消息分发 ──

  /// 处理一条消息；返回 null 表示 notification（无需响应）。
  ///
  /// [client] 是传输层的客户端连接标识：同一个 MCP 进程里多个 AI 会话靠它各记各的
  /// 「当前会话」（见 client_scope.dart），工具 handler 签名不变。
  Future<Map<String, Object?>?> handleMessage(Object? raw, {String client = ''}) =>
      runAsMcpClient(client, () => _handleMessage(raw));

  Future<Map<String, Object?>?> _handleMessage(Object? raw) async {
    if (raw is List) {
      // 2025-06-18 移除了 JSON-RPC batch；显式拒绝比静默丢弃更易排查。
      return mcpError(null, kMcpInvalidRequest, '不支持批量请求（MCP 2025-06-18 已移除）');
    }
    McpRequest req;
    try {
      req = McpRequest.parse(raw);
    } on McpToolException catch (e) {
      return mcpError(null, kMcpInvalidRequest, e.message);
    }
    switch (req.method) {
      case 'initialize':
        return mcpResult(
          req.id,
          mcpInitializeResult(
            requestedVersion: (req.params['protocolVersion'] ?? '').toString(),
            serverVersion: version,
          ),
        );
      case 'notifications/initialized':
      case 'notifications/cancelled':
      case 'notifications/roots/list_changed':
        return null;
      case 'ping':
        return mcpResult(req.id, const <String, Object?>{});
      case 'tools/list':
        return mcpResult(req.id, <String, Object?>{
          'tools': tools.map((t) => t.listing()).toList(growable: false),
        });
      case 'tools/call':
        return _callTool(req);
      case 'resources/list':
        return mcpResult(req.id, const <String, Object?>{'resources': <Object?>[]});
      case 'prompts/list':
        return mcpResult(req.id, const <String, Object?>{'prompts': <Object?>[]});
      default:
        if (req.isNotification) return null;
        return mcpError(req.id, kMcpMethodNotFound, '未知方法 ${req.method}');
    }
  }

  Future<Map<String, Object?>> _callTool(McpRequest req) async {
    final name = (req.params['name'] ?? '').toString();
    final tool = _byName[name];
    if (tool == null) {
      final available = _byName.keys.join(', ');
      return mcpError(req.id, kMcpInvalidParams, '未知工具 $name',
          <String, Object?>{'available': available});
    }
    final rawArgs = req.params['arguments'];
    final args = rawArgs is Map
        ? Map<String, Object?>.from(rawArgs)
        : <String, Object?>{};
    final sw = Stopwatch()..start();
    final session = (args['sessionId'] ?? ctx.sessions.currentId ?? '').toString();
    // 能力闸门：工具声明了硬性能力需求时先按会话能力判断，缺能力直接给人话
    // 报错（工具 handler 里不写 transport 分支）。会话还没选/还没扫到时不拦，
    // 交给 handler 报「未选择会话」。
    final gateId = session.isEmpty ? ctx.sessions.currentId : session;
    final gateTarget = gateId == null ? null : ctx.sessions.byId(gateId);
    Map<String, Object?>? capGap(List<String> want) {
      if (gateTarget == null || !gateTarget.hasChannel || want.isEmpty) {
        return null;
      }
      final missing = missingCaps(gateTarget.caps, want);
      if (missing.isEmpty) return null;
      _audit(name, session, sw.elapsedMilliseconds, false, 'cap');
      return mcpResult(
        req.id,
        McpToolResult.text(
          capGapMessage(missing,
              transport: gateTarget.transport,
              vmDegraded: gateTarget.vmDegraded),
          isError: true,
        ).toJson(),
      );
    }

    final need = kToolNeeds[name];
    if (need != null && need.isNotEmpty) {
      final gap = capGap(need);
      if (gap != null) return gap;
    }
    // 子操作闸门：整工具能用、个别 action 要多更多能力时也提前拦（沙盒的
    // upload / delete、实例的 find / set、性能的 leak / gc / reassemble）。
    final actionNeed =
        kToolActionNeeds[name]?[(args['action'] ?? '').toString()];
    if (actionNeed != null && actionNeed.isNotEmpty) {
      final gap = capGap(actionNeed);
      if (gap != null) return gap;
    }
    var ok = true;
    try {
      final result = await tool.handler(ctx, args);
      ok = !result.isError;
      _audit(name, session, sw.elapsedMilliseconds, ok, '');
      return mcpResult(req.id, result.toJson());
    } on McpToolException catch (e) {
      _audit(name, session, sw.elapsedMilliseconds, false, 'tool');
      return mcpResult(
        req.id,
        McpToolResult.text(e.text, isError: true).toJson(),
      );
    } catch (e) {
      _audit(name, session, sw.elapsedMilliseconds, false, 'exception');
      return mcpResult(
        req.id,
        McpToolResult.text('工具执行异常：$e', isError: true).toJson(),
      );
    }
  }

  // ── 审计日志 ──

  /// 每次 tools/call 记一行：时间 / 工具 / 会话 / 耗时 / 结果。不记参数与 token。
  void _audit(String tool, String session, int ms, bool ok, String code) {
    try {
      _auditSink ??= _openAuditSink();
      _auditSink!.writeln([
        DateTime.now().toIso8601String(),
        tool,
        session.isEmpty ? '-' : session,
        '${ms}ms',
        ok ? 'ok' : 'fail:$code',
      ].join('\t'));
    } catch (_) {
      // 审计失败不影响主流程。
    }
  }

  Future<void> close() async {
    try {
      await _auditSink?.flush();
      await _auditSink?.close();
    } catch (_) {}
    _auditSink = null;
    await ctx.sessions.closeAll();
    await ctx.devices.disposeAll();
  }
}

/// HTTP 模式 token 文件（首次启动自动生成）。
File tokenFile() => File('${xbUmeHome()}/mcp.token');

/// 审计日志文件。
File auditLogFile() => File('${xbUmeHome()}/logs/mcp.log');

/// 打开审计日志：先建父目录，并把写盘错误接住。
///
/// `openWrite` 的失败是**异步**抛的（sink 的 stream 里），外层 try/catch 接不到——
/// 全新 `XB_UME_HOME`（没有 `logs/`）时第一次写就把整个 MCP 进程带走。
IOSink _openAuditSink() {
  final f = auditLogFile();
  f.parent.createSync(recursive: true);
  final sink = f.openWrite(mode: FileMode.append);
  unawaited(sink.done.catchError((Object _) {}));
  return sink;
}

/// 读取或生成 token（32 字符随机 hex）。
String ensureToken() {
  final f = tokenFile();
  try {
    if (f.existsSync()) {
      final s = f.readAsStringSync().trim();
      if (s.length >= 16) return s;
    }
    final rnd = List<int>.generate(
      16,
      (_) => math.Random.secure().nextInt(256),
    );
    final token =
        rnd.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(token);
    // token 是本地共享密钥，收紧到仅当前用户可读（Windows 无 POSIX 权限，跳过）。
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', <String>['600', f.path]);
      } catch (_) {}
    }
    return token;
  } catch (_) {
    return '';
  }
}

/// 生成 mcp.json 配置片段（README / GUI 复制按钮共用）。
String mcpConfigSnippet({
  String command = 'xb_ume_mcp',
  List<String> args = const <String>[],
  String? httpUrl,
}) {
  final config = <String, Object?>{
    'mcpServers': <String, Object?>{
      'xb_ume': <String, Object?>{
        if (httpUrl != null) 'type': 'http',
        if (httpUrl != null) 'url': httpUrl else 'command': command,
        if (httpUrl == null && args.isNotEmpty) 'args': args,
      },
    },
  };
  return const JsonEncoder.withIndent('  ').convert(config);
}
