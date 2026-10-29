// GUI 工具箱 HTTP 桥。
//
// MCP 是独立进程，但有一部分能力天生长在工具箱进程里：SQLite 查询要调本机
// sqlite3、沙盒下载要落本机缓存、文件监听靠工具箱的轮询定时器、性能采样与
// 场景对比是工具箱的状态机、IDE 唤起与守护进程管理用的是工具箱的配置。
// 在 MCP 里重写一遍只会得到两套慢慢跑偏的行为，所以这里统一转发 `/api/*`：
//   - 端口：--gui-port 指定，或按 46129..46138 探测（工具箱启动时选的端口）；
//   - 请求：GET 走 query，POST 默认 query + JSON body 双写（GUI 侧有的读
//     query、有的读 body），SQL / XML 这类长文本用 bodyOnly 只放 body；
//   - 结果：JSON 原样返回，二进制走 raw()。
//
// 工具箱没开时给一条能照着做的提示，而不是让模型对着一堆连接错误猜。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../paths.dart';

/// 桥接失败：工具箱没开、端口探测不到、或 GUI 回了错误码。
class GuiBridgeError implements Exception {
  GuiBridgeError(this.message, {this.hint});

  final String message;
  final String? hint;

  @override
  String toString() => hint == null ? message : '$message（$hint）';
}

class GuiBridge {
  GuiBridge({int? port, Duration? timeout})
      : _fixedPort = port,
        timeout = timeout ?? const Duration(seconds: 30);

  /// `--gui-port` 显式指定；为空时按 [kPortBase] 起 10 个端口探测。
  final int? _fixedPort;
  final Duration timeout;
  int? _port;

  /// 工具箱访问令牌（GUI 把全部 /api/* 都挂了鉴权）。首次用到时从
  /// gui.token 或环境变量读；GUI 重启后令牌会换，收到 403 时重读一次。
  String? _token;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 5);

  static const int kPortBase = 46129;
  static const int kPortCount = 10;

  /// 当前连着的工具箱端口（探测过才会知道）。
  int? get knownPort => _port;

  /// 探测并缓存工具箱端口；连不上时抛 [GuiBridgeError]。
  Future<int> port({bool refresh = false}) async {
    if (!refresh) {
      final p = _port;
      if (p != null && await _alive(p)) return p;
    }
    final fixed = _fixedPort;
    if (fixed != null) {
      if (await _alive(fixed)) return _port = fixed;
      throw GuiBridgeError(
        '连不上工具箱 127.0.0.1:$fixed',
        hint: '确认工具箱已启动且端口是 $fixed；或去掉 --gui-port 让它自动探测',
      );
    }
    for (var p = kPortBase; p < kPortBase + kPortCount; p++) {
      if (await _alive(p)) return _port = p;
    }
    throw GuiBridgeError(
      '没有发现正在运行的工具箱（探测 $kPortBase..${kPortBase + kPortCount - 1}）',
      hint: '这个工具要借工具箱的本机能力（sqlite3 / 沙盒缓存 / 监听 / 对比）。'
          '先执行 dart run xb_ume:gui 打开工具箱，或让用户点开已经装好的工具箱',
    );
  }

  Future<bool> _alive(int p) async {
    try {
      final r = await _send(
        'GET',
        p,
        '/api/version',
        const <String, Object?>{},
        null,
        const Duration(seconds: 2),
      );
      return r.status == HttpStatus.ok && r.json != null;
    } catch (_) {
      return false;
    }
  }

  /// 调一个返回 JSON 的接口。失败（非 2xx）时把 GUI 的 error 字段抛出来。
  Future<Map<String, Object?>> json(
    String path, {
    Map<String, Object?> params = const <String, Object?>{},
    String method = 'GET',
    bool bodyOnly = false,
    String? rawBody,
    String? contentType,
    Duration? timeout,
  }) async {
    final p = await port();
    final r = await _send(
      method,
      p,
      path,
      params,
      rawBody,
      timeout ?? this.timeout,
      bodyOnly: bodyOnly,
      contentType: contentType,
    );
    if (r.status < 200 || r.status >= 300) {
      final err = r.json?['error'] ?? r.json?['message'];
      final body = r.text.trim();
      throw GuiBridgeError(
        '${method == 'GET' ? '读取' : '操作'}失败（HTTP ${r.status}）：'
        '${err ?? (body.isEmpty ? _statusText(r.status) : _clip(body))}',
        hint: r.status == HttpStatus.notFound
            ? '这个工具箱版本可能还没有该接口，更新后重试'
            : (r.status == HttpStatus.badRequest && err == null && body.isEmpty
                ? '必填参数缺失或取值不合法（GUI 未返回原因）'
                : null),
      );
    }
    final j = r.json;
    if (j == null) {
      throw GuiBridgeError('工具箱返回的不是 JSON：${_clip(r.text)}');
    }
    return j;
  }

  /// 取纯文本（CSV 导出、安装日志这类不是 JSON 的接口）。
  Future<String> text(
    String path, {
    Map<String, Object?> params = const <String, Object?>{},
    String method = 'GET',
    bool bodyOnly = false,
    Duration? timeout,
  }) async {
    final p = await port();
    final r = await _send(
      method,
      p,
      path,
      params,
      null,
      timeout ?? this.timeout,
      bodyOnly: bodyOnly,
    );
    if (r.status < 200 || r.status >= 300) {
      throw GuiBridgeError(
        '拉取失败（HTTP ${r.status}）：${r.json?['error'] ?? _clip(r.text)}',
      );
    }
    return r.text;
  }

  /// 取二进制（沙盒下载）。GUI 对超大文件会先回一个 token 再流式下发，
  /// 这里跟着再请求一次。
  Future<Uint8List> bytes(
    String path, {
    Map<String, Object?> params = const <String, Object?>{},
    Duration? timeout,
  }) async {
    final p = await port();
    final r = await _send(
      'GET',
      p,
      path,
      params,
      null,
      timeout ?? const Duration(seconds: 120),
    );
    if (r.status < 200 || r.status >= 300) {
      throw GuiBridgeError(
        '下载失败（HTTP ${r.status}）：${r.json?['error'] ?? _clip(r.text)}',
      );
    }
    final token = r.json?['token'];
    if (token != null) {
      final second = await _send(
        'GET',
        p,
        path,
        <String, Object?>{'token': '$token'},
        null,
        timeout ?? const Duration(seconds: 120),
      );
      if (second.status < 200 || second.status >= 300) {
        throw GuiBridgeError('下载失败（HTTP ${second.status}）');
      }
      return second.bytes;
    }
    return r.bytes;
  }

  Future<_Resp> _send(
    String method,
    int port,
    String path,
    Map<String, Object?> params,
    String? rawBody,
    Duration timeout, {
    bool bodyOnly = false,
    String? contentType,
  }) async {
    final r = await _sendOnce(method, port, path, params, rawBody, timeout,
        bodyOnly: bodyOnly, contentType: contentType);
    if (r.status != HttpStatus.forbidden) return r;
    // 令牌可能刚随 GUI 重启换了一批：重读后重试一次。
    final before = _token;
    _token = _readToken();
    if (_token == null || _token == before) {
      throw GuiBridgeError(
        '工具箱拒绝了访问（HTTP 403）',
        hint: 'GUI 的访问令牌变了或读不到：确认已打开工具箱页面，'
            '或设置环境变量 XB_UME_GUI_TOKEN',
      );
    }
    return _sendOnce(method, port, path, params, rawBody, timeout,
        bodyOnly: bodyOnly, contentType: contentType);
  }

  /// 读本地访问令牌：env > $HOME/.xb_ume_ide/gui.token > $XB_UME_HOME/gui.token。
  static String? _readToken() {
    final env =
        Platform.environment['XB_UME_GUI_TOKEN']?.trim() ?? '';
    if (env.isNotEmpty) return env;
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final dirs = <String>[
      if (home != null && home.isNotEmpty) '$home/.xb_ume_ide',
      xbUmeHome(),
    ];
    for (final d in dirs) {
      try {
        final f = File('$d/gui.token');
        if (!f.existsSync()) continue;
        final t = f.readAsStringSync().trim();
        if (t.isNotEmpty) return t;
      } catch (_) {
        // 读不到就试下一个路径。
      }
    }
    return null;
  }

  Future<_Resp> _sendOnce(
    String method,
    int port,
    String path,
    Map<String, Object?> params,
    String? rawBody,
    Duration timeout, {
    bool bodyOnly = false,
    String? contentType,
  }) async {
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: path,
      queryParameters: bodyOnly && rawBody != null
          ? const <String, String>{}
          : params.map((k, v) => MapEntry(k, _paramText(v))),
    );
    HttpClientRequest req;
    try {
      req = await _http.openUrl(method, uri).timeout(timeout);
    } on SocketException {
      _port = null;
      throw GuiBridgeError(
        '工具箱连接断开（$port）',
        hint: '工具箱可能刚被关掉，重新打开后再试',
      );
    }
    req.headers.set(HttpHeaders.connectionHeader, 'close');
    final token = _token ??= _readToken();
    if (token != null) req.headers.set('x-xbume-token', token);
    if (method == 'POST' || method == 'PUT') {
      final body = rawBody ??
          (params.isEmpty ? '' : jsonEncode(params.map((k, v) => MapEntry(k, v))));
      final bytes = utf8.encode(body);
      req.headers.contentType =
          ContentType.parse(contentType ?? 'application/json; charset=utf-8');
      req.headers.contentLength = bytes.length;
      if (bytes.isNotEmpty) req.add(bytes);
    }
    final res = await req.close().timeout(timeout);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(timeout)) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    final text = _decodeText(bytes, res.headers.contentType);
    Map<String, Object?>? jsonMap;
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{')) {
      try {
        final v = jsonDecode(text);
        if (v is Map) jsonMap = v.cast<String, Object?>();
      } catch (_) {
        // 不是 JSON 就当文本处理（CSV / CSV 导出等）。
      }
    }
    return _Resp(res.statusCode, bytes, text, jsonMap);
  }

  static String _paramText(Object? v) {
    if (v == null) return '';
    if (v is bool) return v ? 'true' : 'false';
    return '$v';
  }

  static String _decodeText(Uint8List bytes, ContentType? type) {
    if (bytes.isEmpty) return '';
    final charset = type?.charset?.toLowerCase();
    if (charset == 'gbk' || charset == 'gb2312') {
      // 工具箱只用 UTF-8；这里留着是为了不把二进制误当 UTF-8 解坏。
      return latin1.decode(bytes, allowInvalid: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _statusText(int status) => status == HttpStatus.badRequest
      ? '请求参数不完整或无效（GUI 未返回原因）'
      : 'GUI 未返回原因';

  static String _clip(String s, [int max = 300]) {
    final t = s.trim();
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }

  void dispose() => _http.close(force: true);
}

class _Resp {
  _Resp(this.status, this.bytes, this.text, this.json);

  final int status;
  final Uint8List bytes;
  final String text;
  final Map<String, Object?>? json;
}
