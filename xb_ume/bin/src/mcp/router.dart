// 池入口（router）：客户端只连这一个端口，按连接把请求分给池里的实例。
//
// 为什么需要入口：AI 改不了自己的 MCP 配置（换个端口就连不上了）。所以「这个实例
// 被别人绑了，我自己开一个」只能由入口代劳——它听同一个端口，按 Mcp-Session-Id
// 认出「这是哪条连接」，给这条连接分配一个后端实例（复用空闲 / 拉起新的 / 池满排队），
// 之后把这条连接的每个 JSON-RPC 原样转发过去，AI 完全无感。
//
// 不吃槽的方法在入口本地答：initialize / tools/list / ping / xbume_pool。
// GUI 的健康检查、AI 刚开窗看一眼工具列表，都不该占掉一个实例。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../device/live_store.dart' show pidAlive;
import '../paths.dart';
import 'client_scope.dart' show shortMcpClient;
import 'host.dart' show kDefaultMcpPort;
import 'instances.dart';
import 'pool.dart';
import 'protocol.dart';
import 'tools.dart';

/// 池入口：一个端口 + 一份池 + 一张「连接 → 实例」的转发表。
class PoolEntry {
  PoolEntry({
    required this.port,
    required this.version,
    required this.token,
    required this.tools,
    required this.toolGroups,
    this.allowEval = false,
    this.guiPort,
    this.deviceBackend = 'auto',
    this.log,
    String? home,
    int? max,
  })  : home = home ?? xbUmeHome(),
        pool = PoolStore(home: home ?? xbUmeHome(), max: max);

  /// 入口端口（客户端配置里填的那个）。
  final int port;

  final String version;

  /// 与后端实例共用的 token（同一个 XB_UME_HOME → 同一份 mcp.token）。
  final String token;
  final List<McpTool> tools;

  /// 拉起后端时要带下去的 --tool-groups。
  final String toolGroups;
  final bool allowEval;
  final int? guiPort;
  final String deviceBackend;

  /// 日志出口（mcp.dart 的 `_log`）：订阅式启动后 stdout 没人看，回收记录
  /// 写进同一份 --log-file 才查得到。
  final void Function(String)? log;

  final String home;
  final PoolStore pool;

  final HttpClient _hc = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);

  /// 连接 → initialize 里的 clientInfo.name（只用于给人看的 owner 标签）。
  final Map<String, String> _names = <String, String>{};

  // ── 生命周期 ──

  /// 回收扫描间隔：绑定过期 / 进程残留都由它清掉（严格模式：空闲槽不留进程）。
  static const Duration kPoolSweepEvery = Duration(seconds: 30);

  bool _disposed = false;

  Future<HttpServer> serve() async {
    final hs = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    unawaited(_sweepLoop());
    unawaited(_accept(hs));
    return hs;
  }

  /// 后台回收：过期绑定、残留进程、已死进程一律收掉；有场景在跑的槽跳过。
  Future<void> _sweepLoop() async {
    while (!_disposed) {
      try {
        // 启动先扫一遍：上一个入口留下的进程不该继续占着槽。
        final n = await pool.sweep();
        if (n > 0) {
          log?.call('[pool] 回收 $n 个槽（过期绑定 / 残留进程）');
        }
      } catch (_) {
        // 池目录读写失败不该把入口带下去。
      }
      await Future<void>.delayed(kPoolSweepEvery);
    }
  }

  void dispose() {
    _disposed = true;
    try {
      _hc.close(force: true);
    } catch (_) {
      // 关不掉就算了，进程退出会回收。
    }
  }

  /// 入口自己的实例登记（GUI / xbume_clients 里能看出「这是池入口」）。
  Map<String, Object?> register() {
    final rec = <String, Object?>{
      'name': 'pool-entry',
      'transport': 'http',
      'port': port,
      'pid': pid,
      'version': version,
      'hasEval': tools.any((t) => t.name == 'xbume_eval'),
      'toolCount': tools.length,
      // 从实际清单推导，和 worker 登记的口径一致（写死 ['core'] 会出现
      // 「59 个工具但 groups 只有 core」这种自相矛盾的登记）。
      'groups': tools.map((t) => t.group).toSet().toList()..sort(),
      'role': 'pool-entry',
      'poolMax': pool.max,
      'startedAt': DateTime.now().toIso8601String(),
    };
    writeInstance(rec, home: home);
    return rec;
  }

  void unregister() => removeInstance('pool-entry', home: home, onlyPid: pid);

  Future<void> _accept(HttpServer server) async {
    await for (final req in server) {
      unawaited(_handle(req));
    }
  }

  // ── HTTP ──

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.uri.path != '/mcp') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
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
          'hint': '从 $home/mcp.token 读取，放到 X-XBUME-Token 或 Authorization: Bearer',
        }));
        await req.response.close();
        return;
      }
      switch (req.method) {
        case 'POST':
          await _post(req);
          return;
        case 'DELETE':
          // 客户端主动关窗：立刻把槽退回池（不然要等 10 分钟 TTL）。
          final sid = _connKey(req);
          if (sid.isNotEmpty) await pool.releaseFor(sid);
          _names.remove(sid);
          req.response.statusCode = HttpStatus.ok;
          await req.response.close();
          return;
        case 'GET':
          req.response.statusCode = HttpStatus.methodNotAllowed;
          req.response.headers.set(HttpHeaders.allowHeader, 'POST, DELETE');
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
            mcpError(null, kMcpInternalError, '池入口异常：$e'),
            status: HttpStatus.internalServerError);
      } catch (_) {
        // 响应已关闭。
      }
    }
  }

  bool _tokenOk(HttpRequest req) {
    if (token.isEmpty) return true;
    if (req.headers.value('X-XBUME-Token') == token) return true;
    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    return auth.toLowerCase().startsWith('bearer ') &&
        auth.substring(7).trim() == token;
  }

  /// 这条请求属于哪条连接：有 Mcp-Session-Id 用它；没回传的（老客户端）
  /// 统一算 `legacy` 一条，避免每次请求都新占一个槽。
  String _connKey(HttpRequest req) {
    final raw = (req.headers.value('Mcp-Session-Id') ?? '').trim();
    return raw.isEmpty ? 'legacy' : raw;
  }

  Future<void> _post(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    Object? raw;
    try {
      raw = jsonDecode(body);
    } catch (e) {
      _json(req.response, mcpError(null, kMcpParseError, 'JSON 解析失败：$e'),
          status: HttpStatus.badRequest);
      return;
    }
    final sid = _connKey(req);
    final outSid = (req.headers.value('Mcp-Session-Id') ?? '').trim().isEmpty
        ? 'xb-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        : req.headers.value('Mcp-Session-Id')!;
    req.response.headers.set('Mcp-Session-Id', outSid);

    if (raw is! Map) {
      _json(req.response,
          mcpError(null, kMcpInvalidRequest, '不支持批量请求（MCP 2025-06-18 已移除）'));
      return;
    }
    final method = '${raw['method'] ?? ''}';
    final id = raw['id'];
    final params = raw['params'] is Map
        ? Map<String, Object?>.from(raw['params'] as Map)
        : <String, Object?>{};

    switch (method) {
      case 'initialize':
        final ci = params['clientInfo'];
        if (ci is Map) {
          // 客户端名字要记两遍：本条请求可能还没带 Mcp-Session-Id（首握手），
          // 后续请求才会带着我们签发的那条回来。
          final name = '${ci['name'] ?? ''}'.trim();
          if (name.isNotEmpty) {
            _names[sid] = name;
            _names[outSid] = name;
          }
        }
        _json(
          req.response,
          mcpResult(
            id,
            mcpInitializeResult(
              requestedVersion: '${params['protocolVersion'] ?? ''}',
              serverVersion: version,
            ),
          ),
        );
        return;
      case 'notifications/initialized':
      case 'notifications/cancelled':
      case 'notifications/roots/list_changed':
        req.response.statusCode = HttpStatus.accepted;
        await req.response.close();
        return;
      case 'ping':
        _json(req.response, mcpResult(id, const <String, Object?>{}));
        return;
      case 'tools/list':
        _json(req.response, mcpResult(id, <String, Object?>{
          'tools': tools.map((t) => t.listing()).toList(growable: false),
        }));
        return;
      case 'resources/list':
        _json(req.response,
            mcpResult(id, const <String, Object?>{'resources': <Object?>[]}));
        return;
      case 'prompts/list':
        _json(req.response,
            mcpResult(id, const <String, Object?>{'prompts': <Object?>[]}));
        return;
      case 'tools/call':
        await _callTool(req, body, id, sid, params);
        return;
      default:
        _json(req.response, mcpError(id, kMcpMethodNotFound, '未知方法 $method'));
        return;
    }
  }

  Future<void> _callTool(
    HttpRequest req,
    String body,
    Object? id,
    String sid,
    Map<String, Object?> params,
  ) async {
    final name = '${params['name'] ?? ''}';
    // 池本身的操作必须在入口答：池满时也要能问「为什么排队 / 怎么让位」。
    if (name == 'xbume_pool') {
      final args = params['arguments'] is Map
          ? Map<String, Object?>.from(params['arguments'] as Map)
          : <String, Object?>{};
      final text = await poolOpText(
        pool: pool,
        client: sid,
        owner: _ownerOf(sid),
        op: '${args['op'] ?? 'status'}',
        slot: int.tryParse('${args['slot'] ?? ''}'),
        entryPort: port,
      );
      _json(
        req.response,
        mcpResult(id, McpToolResult.text(text).toJson()),
      );
      return;
    }

    final slot = await _ensureSlot(sid, name);
    if (slot == null) {
      _json(
        req.response,
        mcpResult(
          id,
          McpToolResult.text(poolBusyText(pool, mineClient: sid), isError: true)
              .toJson(),
        ),
      );
      return;
    }
    if (slot.port <= 0) {
      _json(
        req.response,
        mcpResult(
          id,
          McpToolResult.text(
            '分配到槽 ${slot.slot}，但这个实例没起来：'
            '${slot.error.isEmpty ? '未知原因' : slot.error}\n'
            '日志：$home/logs/${poolSlotName(slot.slot)}.log',
            isError: true,
          ).toJson(),
        ),
      );
      return;
    }

    final text = await _forward(slot.port, body, sid);
    if (text == null) {
      // 后端没了（崩了 / 被停）：释放并收掉这个槽，下一次调用会拉起全新实例。
      await pool.releaseFor(sid);
      final left = pool.boundSlots().length;
      _json(
        req.response,
        mcpResult(
          id,
          McpToolResult.text(
            '槽 ${slot.slot}（${slot.name}:${slot.port}）没有响应，已停掉它并把槽退回池'
            '（现在 $left/${pool.max} 被绑）。重试一次会给你拉起一个全新实例，'
            '代价是当前会话要重新 xbume_sessions 选择。\n'
            '日志：$home/logs/${poolSlotName(slot.slot)}.log',
            isError: true,
          ).toJson(),
        ),
      );
      return;
    }
    req.response.statusCode = HttpStatus.ok;
    req.response.headers.contentType = ContentType.json;
    req.response.write(text);
    await req.response.close();
  }

  // ── 分配 ──

  /// 保证这条连接有一个能用的后端实例：已绑 → 续期；空闲 → 拉起全新实例；满 → null。
  ///
  /// 严格模式：除了「自己一直绑着的那个」，不会复用任何别的进程——空闲槽里
  /// 的残留进程由 [PoolStore.allocate] 杀掉，这里只负责拉起新的。
  Future<PoolSlot?> _ensureSlot(String sid, String tool) async {
    final mine = pool.mine(sid);
    if (mine != null && mine.bindingId.isNotEmpty) {
      final usable = mine.running || pool.isBound(mine);
      if (usable && mine.port > 0 && pidAlive(mine.pid)) {
        unawaited(pool.renewFor(sid, note: tool));
        return mine;
      }
      // 有场景在跑就别动它（端口/pid 异常也等它跑完，回收扫描会滚动续期）。
      if (usable && mine.running) return mine;
      // 过期或进程没了：释放（连带停实例），下面重新分配。
      await pool.releaseFor(sid);
    }
    final got = await pool.allocate(
      owner: _ownerOf(sid),
      client: sid,
      note: tool,
    );
    if (got == null) return null;
    if (got.port > 0 && got.pid > 0 && pidAlive(got.pid)) return got;
    return _spawn(got.slot);
  }

  /// 拉起槽 [slot] 的后端实例并等它握手成功。
  Future<PoolSlot?> _spawn(int slot) async {
    final name = poolSlotName(slot);
    final script = _scriptPath();
    if (script == null) {
      await pool.markError(slot, '找不到 mcp.dart（先 dart run xb_ume:ide --install）');
      return null;
    }
    final p = await _pickPort(slot);
    if (p == null) {
      await pool.markError(slot, '端口 ${kDefaultMcpPort + 1}-${kDefaultMcpPort + 9} 都被占');
      return null;
    }
    Process proc;
    try {
      proc = await Process.start(
        Platform.resolvedExecutable,
        <String>[
          script,
          '--http',
          '$p',
          '--name',
          name,
          '--slot',
          '$slot',
          '--tool-groups',
          toolGroups,
          if (allowEval) '--allow-eval',
          if (guiPort != null) ...<String>['--gui-port', '$guiPort'],
          if (deviceBackend != 'auto') ...<String>[
            '--device-backend',
            deviceBackend,
          ],
          '--log-file',
          '$home/logs/$name.log',
        ],
        workingDirectory: home,
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      await pool.markError(slot, '拉起失败：$e');
      return null;
    }
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (await _probe(p)) {
        await pool.attachWorker(slot, name: name, port: p, pid: proc.pid);
        return pool.list()[slot - 1];
      }
      if (!pidAlive(proc.pid)) break;
    }
    await pool.markError(slot, '20 秒内没握手成功（日志 $home/logs/$name.log）');
    return null;
  }

  /// 优先用 46140+槽号，被占就从 46141 往后找。
  Future<int?> _pickPort(int slot) async {
    final used = <int>{port};
    for (final s in pool.list()) {
      if (s.port > 0) used.add(s.port);
    }
    final prefer = kDefaultMcpPort + slot;
    if (!used.contains(prefer) && await _free(prefer)) return prefer;
    for (var p = kDefaultMcpPort + 1; p < kDefaultMcpPort + 10; p++) {
      if (used.contains(p)) continue;
      if (await _free(p)) return p;
    }
    return null;
  }

  Future<bool> _free(int p) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 部署副本优先（和 McpHost 一致）。
  String? _scriptPath() {
    final deployed = File('$home/mcp.dart');
    if (deployed.existsSync()) return deployed.path;
    try {
      final p = Platform.script.toFilePath();
      if (p.endsWith('.dart') && File(p).existsSync()) return p;
    } catch (_) {}
    return null;
  }

  Future<bool> _probe(int p) async {
    try {
      final req = await _hc.postUrl(Uri.parse('http://127.0.0.1:$p/mcp'));
      req.headers.contentType = ContentType.json;
      if (token.isNotEmpty) req.headers.set('X-XBUME-Token', token);
      req.write(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, Object?>{
          'protocolVersion': kMcpLatestVersion,
          'capabilities': <String, Object?>{'tools': <String, Object?>{}},
          'clientInfo': <String, Object?>{'name': 'xbume-pool', 'version': '1'},
        },
      }));
      final res = await req.close().timeout(const Duration(seconds: 3));
      final text = await res.transform(utf8.decoder).join();
      final j = jsonDecode(text);
      return j is Map && j['result'] is Map;
    } catch (_) {
      return false;
    }
  }

  /// 原样转发一条 JSON-RPC；后端回空体（202）时返回 null。
  Future<String?> _forward(int p, String body, String sid) async {
    try {
      final req = await _hc.postUrl(Uri.parse('http://127.0.0.1:$p/mcp'));
      req.headers.contentType = ContentType.json;
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token.isNotEmpty) req.headers.set('X-XBUME-Token', token);
      req.headers.set('Mcp-Session-Id', sid);
      req.write(body);
      final res = await req.close().timeout(const Duration(minutes: 10));
      final text = await res.transform(utf8.decoder).join();
      return text.trim().isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  String _ownerOf(String sid) {
    if (sid == 'legacy') return '未回传会话的客户端';
    final n = (_names[sid] ?? '').trim();
    final tag = '…${shortMcpClient(sid)}';
    return n.isEmpty ? tag : '$n（$tag）';
  }

  void _json(HttpResponse res, Map<String, Object?> body,
      {int status = HttpStatus.ok}) {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    unawaited(res.close());
  }
}
