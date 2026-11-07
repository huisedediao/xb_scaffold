// 直连 Agent 客户端（IDE 侧）。
//
// 纯直连会话的 uri 就是 agent baseUrl（`http://127.0.0.1:<port>`）：对 VM 会话
// 来说是 ws://，两者用一个前缀就能分开，GUI/MCP 里不必再传 transport。
//
// 只做只读数据面（P1）。执行类能力（点击/截图/求值）没有对应端点——release
// 包本来也不该对外暴露这些。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 会话 uri 是否指向 app 内直连服务（VM 会话是 `ws://`）。
bool isAgentBaseUrl(String uri) {
  final u = uri.trim().toLowerCase();
  return u.startsWith('http://') || u.startsWith('https://');
}

/// 直连服务地址归一（去尾斜杠，缺 scheme 时补 http://）。
String normalizeAgentBaseUrl(String raw) {
  var u = raw.trim();
  if (u.isEmpty) return u;
  if (!u.contains('://')) u = 'http://$u';
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  return u;
}

/// 直连服务 HTTP 客户端。每次调用新建连接（回环、量小），避免长连接在 app
/// 重启/掉线后卡住下一轮。
class AgentClient {
  AgentClient(
    String baseUrl, {
    this.token = '',
    this.timeout = const Duration(seconds: 3),
  }) : baseUrl = normalizeAgentBaseUrl(baseUrl);

  final String baseUrl;
  final String token;
  final Duration timeout;

  String get displayName => baseUrl;

  Future<Map<String, Object?>> getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(
      queryParameters: <String, String>{
        ...?query,
        if (token.isNotEmpty) 'token': token,
      },
    );
    final client = HttpClient()..connectionTimeout = timeout;
    // 回环请求必须绕过系统代理（本机常开着代理，走代理会 502/超时）。
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set('x-xbume-client', 'xbume-ide');
      if (token.isNotEmpty) request.headers.set('x-xbume-token', token);
      final response = await request.close().timeout(timeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode != 200) {
        throw AgentHttpError(response.statusCode, _errorOf(body));
      }
      final parsed = jsonDecode(body);
      if (parsed is! Map) throw const AgentHttpError(0, '返回不是 JSON 对象');
      return <String, Object?>{
        for (final e in parsed.entries) e.key.toString(): e.value,
      };
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> postJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(
      queryParameters: <String, String>{
        ...?query,
        if (token.isNotEmpty) 'token': token,
      },
    );
    final client = HttpClient()..connectionTimeout = timeout;
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client.postUrl(uri).timeout(timeout);
      request.headers.set('x-xbume-client', 'xbume-ide');
      if (token.isNotEmpty) request.headers.set('x-xbume-token', token);
      request.headers.contentLength = 0;
      final response = await request.close().timeout(timeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode != 200) {
        throw AgentHttpError(response.statusCode, _errorOf(body));
      }
      final parsed = jsonDecode(body);
      if (parsed is! Map) throw const AgentHttpError(0, '返回不是 JSON 对象');
      return <String, Object?>{
        for (final e in parsed.entries) e.key.toString(): e.value,
      };
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> hello() => getJson('/v1/hello');

  Future<Map<String, Object?>> state() => getJson('/v1/state');

  Future<List<Map<String, Object?>>> logs({
    int limit = 200,
    String level = '',
    String tag = '',
    String keyword = '',
    int sinceMs = 0,
  }) {
    return items('/v1/logs', <String, String>{
      'limit': '$limit',
      if (level.isNotEmpty) 'level': level,
      if (tag.isNotEmpty) 'tag': tag,
      if (keyword.isNotEmpty) 'keyword': keyword,
      if (sinceMs > 0) 'sinceMs': '$sinceMs',
    });
  }

  Future<List<Map<String, Object?>>> exceptions({int limit = 200}) =>
      items('/v1/exceptions', <String, String>{'limit': '$limit'});

  Future<List<Map<String, Object?>>> network({int limit = 300}) =>
      items('/v1/network', <String, String>{'limit': '$limit'});

  Future<Map<String, Object?>> networkDetail(String id) =>
      getJson('/v1/network/detail', query: <String, String>{'id': id});

  Future<void> clearNetwork() async {
    await postJson('/v1/network/clear');
  }

  Future<List<Map<String, Object?>>> routes({int limit = 300}) =>
      items('/v1/routes', <String, String>{'limit': '$limit'});

  Future<List<Map<String, Object?>>> frames({int limit = 600}) =>
      items('/v1/frames', <String, String>{'limit': '$limit'});

  /// 时间轴事件（条目字段与 GUI `_tlItems` 一致）。
  Future<List<Map<String, Object?>>> timeline({
    int sinceMs = 0,
    int limit = 500,
  }) {
    return items('/v1/timeline', <String, String>{
      'limit': '$limit',
      if (sinceMs > 0) 'sinceMs': '$sinceMs',
    });
  }

  /// 读 `{items:[...]}` 列表。
  Future<List<Map<String, Object?>>> items(
    String path, [
    Map<String, String>? query,
  ]) async {
    final json = await getJson(path, query: query);
    final raw = json['items'];
    if (raw is! List) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final e in raw)
        if (e is Map)
          <String, Object?>{for (final kv in e.entries) kv.key.toString(): kv.value},
    ];
  }

  String _errorOf(String body) {
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map && parsed['error'] != null) {
        return '${parsed['error']}';
      }
    } catch (_) {
      // 非 JSON 错误体：原样返回截断文本。
    }
    return body.length > 200 ? body.substring(0, 200) : body;
  }
}

class AgentHttpError implements Exception {
  const AgentHttpError(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => '直连服务返回 $statusCode：$message';
}