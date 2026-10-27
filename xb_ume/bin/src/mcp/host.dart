// MCP HTTP 服务的探测 / 启动 / 停止。
//
// 供 `xb_ume:ai` 命令使用：它要在「一条命令」里把服务准备到「带 eval」的状态，
// 并且只在 pid 是自己记录的情况下才重启——绝不按进程名匹配。
//
// GUI 里的同名能力（probeMcpStatus / startMcp / stopMcp）保持独立实现：
// GUI 是单文件部署，不 import bin/src；两边靠同一份 mcp.pid 与 mcp.token 协作，
// 所以谁启动的服务另一边都能停。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import '../paths.dart';

/// MCP HTTP 默认端口与扫描范围（与 README / MCP_GUIDE 一致）。
const int kDefaultMcpPort = 46140;
const int kMcpPortSpan = 10;

class McpHost {
  McpHost({String? home}) : home = home ?? xbUmeHome();

  final String home;

  File get _pidFile => File('$home/mcp.pid');
  File get _logFile => File('$home/logs/mcp.log');

  /// 读或生成 token（规则与 bin/mcp.dart 的 ensureToken 一致）。
  String get token {
    final f = File('$home/mcp.token');
    try {
      if (f.existsSync()) {
        final s = f.readAsStringSync().trim();
        if (s.length >= 16) return s;
      }
      final rnd = List<int>.generate(16, (_) => Random.secure().nextInt(256));
      final tk = rnd.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(tk);
      // Windows 无 POSIX 权限，跳过 chmod（用户目录 ACL 由系统兜底）。
      if (!Platform.isWindows) {
        try {
          Process.runSync('chmod', <String>['600', f.path]);
        } catch (_) {
          // 权限收不紧不影响功能。
        }
      }
      return tk;
    } catch (_) {
      return '';
    }
  }

  /// 扫 [from, from+span) 找 MCP：握手成功即返回该端口的状态。
  Future<Map<String, Object?>> probe({int from = kDefaultMcpPort}) async {
    final tk = token;
    for (var p = from; p < from + kMcpPortSpan; p++) {
      final hit = await _handshake(p, tk);
      if (hit != null) return hit;
    }
    return <String, Object?>{'running': false, 'defaultPort': from};
  }

  /// 保证有一个 eval 状态符合 [allowEval] 的服务在跑。
  ///
  /// - 已在跑且状态一致：直接复用；
  /// - 已在跑但状态不一致：只有 pid 记录在案才重启（否则报错，不猜进程）；
  /// - 没在跑：挑空闲端口启动。
  Future<Map<String, Object?>> ensure({required bool allowEval}) async {
    final st = await probe();
    if (st['running'] == true) {
      if (st['hasEval'] == allowEval) {
        return <String, Object?>{...st, 'reused': true};
      }
      final rec = _readPidRecord();
      final pid = int.tryParse('${rec['pid'] ?? ''}');
      if (pid == null) {
        throw StateError('端口 ${st['port']} 上的 MCP 服务不是本工具启动的'
            '（没有 pid 记录），当前 eval=${st['hasEval']}；'
            '请先手动停止它，或直接用这个服务');
      }
      await stop();
    }
    return _start(allowEval: allowEval);
  }

  /// 按 pid 记录停止服务（SIGTERM，等端口释放）。
  Future<Map<String, Object?>> stop() async {
    final rec = _readPidRecord();
    final pid = int.tryParse('${rec['pid'] ?? ''}');
    final port = int.tryParse('${rec['port'] ?? ''}') ?? kDefaultMcpPort;
    if (pid == null) return <String, Object?>{'ok': true, 'message': '没有运行中的服务'};
    var killed = false;
    try {
      killed = Process.killPid(pid, ProcessSignal.sigterm);
    } catch (_) {
      // 进程可能已退出。
    }
    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (await _portFree(port)) break;
    }
    try {
      if (_pidFile.existsSync()) _pidFile.deleteSync();
    } catch (_) {}
    return <String, Object?>{
      'ok': true,
      'pid': pid,
      'killed': killed,
      'message': '已停止 MCP 服务（pid $pid）',
    };
  }

  // ── 内部 ──

  Map<String, Object?> _readPidRecord() {
    try {
      if (!_pidFile.existsSync()) return const <String, Object?>{};
      final j = jsonDecode(_pidFile.readAsStringSync());
      if (j is Map) return j.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      // 记录损坏就当成没有。
    }
    return const <String, Object?>{};
  }

  Future<Map<String, Object?>> _start({required bool allowEval}) async {
    final script = await _findScript();
    if (script == null) {
      throw StateError('找不到 mcp.dart：请先执行 dart run xb_ume:ide --install，'
          '或在 xb_ume 包目录里运行');
    }
    int? port;
    for (var p = kDefaultMcpPort; p < kDefaultMcpPort + kMcpPortSpan; p++) {
      if (await _portFree(p)) {
        port = p;
        break;
      }
    }
    if (port == null) {
      throw StateError('端口 $kDefaultMcpPort-${kDefaultMcpPort + kMcpPortSpan - 1} 都被占用');
    }
    _logFile.parent.createSync(recursive: true);
    final proc = await Process.start(
      Platform.resolvedExecutable,
      <String>[
        script,
        '--http',
        '$port',
        '--tool-groups',
        'all',
        '--log-file',
        _logFile.path,
        if (allowEval) '--allow-eval',
      ],
      workingDirectory: home,
      mode: ProcessStartMode.detached,
    );
    try {
      _pidFile.writeAsStringSync(jsonEncode(<String, Object?>{
        'pid': proc.pid,
        'port': port,
        'at': DateTime.now().toIso8601String(),
      }));
    } catch (_) {
      // pid 写不了只影响后续 stop。
    }
    final tk = token;
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final hit = await _handshake(port, tk);
      if (hit != null) {
        return <String, Object?>{...hit, 'started': true, 'pid': proc.pid};
      }
    }
    throw StateError('已拉起进程 ${proc.pid}，但 20 秒内没握手成功；'
        '详见 ${_logFile.path}');
  }

  /// 找要跑的 mcp.dart：部署副本优先，其次包内 bin/mcp.dart。
  Future<String?> _findScript() async {
    final deployed = File('$home/mcp.dart');
    if (deployed.existsSync()) return deployed.path;
    try {
      final u = await Isolate.resolvePackageUri(
          Uri.parse('package:xb_ume/src/paths.dart'));
      if (u != null) {
        // .../xb_ume/lib/src/paths.dart → .../xb_ume
        final root = File(u.toFilePath()).parent.parent.parent.path;
        final mcp = File('$root/bin/mcp.dart');
        if (mcp.existsSync()) return mcp.path;
      }
    } catch (_) {
      // 解析不到就当成没有。
    }
    return null;
  }

  Future<bool> _portFree(int port) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// initialize + tools/list：成功才认作 MCP，并读出是否带 xbume_eval。
  Future<Map<String, Object?>?> _handshake(int port, String token) async {
    final hc = HttpClient()..connectionTimeout = const Duration(milliseconds: 400);
    try {
      final init = await _post(hc, port, token, <String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, Object?>{
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{'tools': <String, Object?>{}},
          'clientInfo': <String, Object?>{'name': 'xbume-ai', 'version': '1'},
        },
      });
      final result = init?['result'];
      if (result is! Map) return null;
      final list = await _post(hc, port, token, <String, Object?>{
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
        'params': <String, Object?>{},
      });
      final tools = (list?['result'] as Map?)?['tools'];
      final names = <String>[];
      if (tools is List) {
        for (final t in tools) {
          if (t is Map && t['name'] != null) names.add('${t['name']}');
        }
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
        'toolCount': names.length,
        'hasEval': names.contains('xbume_eval'),
      };
    } finally {
      hc.close(force: true);
    }
  }

  Future<Map<String, Object?>?> _post(
    HttpClient hc,
    int port,
    String token,
    Map<String, Object?> body,
  ) async {
    try {
      final req = await hc.postUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers
          .set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
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
}
