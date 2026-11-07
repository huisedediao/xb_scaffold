// 直连 Agent 通道的 [SessionApi] 实现（IDE 侧）。
//
// 职责只有两件事：
//   1. 把语义方法翻成 app 内固定端点（`/v1/*`）；
//   2. 把 JSON 结果整形回**与 VM 版原始串完全相同的格式**，让工具/场景引擎里的
//      解析代码一份到底（`\u0001` 分字段、`\u0003` 分行）。
//
// 做不到的语义（路由栈依赖 NavigatorState 私有 `_history`、帧统计、
// 任意 eval）直接抛 [SessionApiUnsupported]，不返回假数据。
library;

import 'dart:convert';

import '../scenario/vm_client.dart';
import 'agent_client.dart';
import 'session_api.dart';

class AgentSessionApi implements SessionApi {
  AgentSessionApi(this._http, {String? uri}) : uri = uri ?? _http.baseUrl;

  final AgentClient _http;

  @override
  final String uri;

  @override
  bool get isAgent => true;

  @override
  VmClient? get vmClient => null;

  static const String _sep = '\u0001';
  static const String _row = '\u0003';

  String _clean(Object? v, {int max = 0}) {
    var t = (v ?? '')
        .toString()
        .replaceAll(_sep, ' ')
        .replaceAll('\u0002', ' ')
        .replaceAll(_row, ' ');
    if (max > 0 && t.length > max) t = '${t.substring(0, max)}...<clipped>';
    return t;
  }

  String _cut(Object? v, int max) {
    final t = _clean(v);
    return t.length > max ? '${t.substring(0, max)}...<clipped>' : t;
  }

  // -- 只读数据面 ---------------------------------------------------------

  @override
  Future<String> networkRaw({int? sinceMs, int limit = 50}) async {
    final items = await _http.items('/v1/network', <String, String>{
      'limit': '$limit',
      if (sinceMs != null && sinceMs > 0) 'sinceMs': '$sinceMs',
    });
    // 与 VM 版同一列序：method,url,statusCode,status,durationMs,time,error。
    final sb = StringBuffer();
    for (final e in items) {
      sb
        ..write(_clean(e['method']))
        ..write(_sep)
        ..write(_clean(e['url']))
        ..write(_sep)
        ..write(_clean(e['statusCode']))
        ..write(_sep)
        ..write(_clean(e['status']))
        ..write(_sep)
        ..write(_clean(e['durationMs']))
        ..write(_sep)
        ..write(_clean(e['time']))
        ..write(_sep)
        ..write(_clean(e['error']))
        ..write(_row);
    }
    return sb.toString();
  }

  /// 解析详情端点的 headers（app 侧是 [{k,v}]）。
  String _kvOf(Object? raw) {
    if (raw is List) {
      final sb = StringBuffer();
      for (final e in raw) {
        if (e is! Map) continue;
        if (sb.isNotEmpty) sb.write('; ');
        sb
          ..write(_clean(e['k']))
          ..write(': ')
          ..write(_clean(e['v']));
      }
      return sb.toString();
    }
    return _clean(raw);
  }

  String _detailRow(Map<String, Object?> d, {required int maxChars}) {
    final reqBody = _clean(d['requestBody']);
    final respBody = _clean(d['responseBody']);
    final clipped = reqBody.length > maxChars || respBody.length > maxChars;
    return <String>[
      _clean(d['id']),
      _clean(d['time']),
      _clean(d['method']),
      _clean(d['url']),
      _clean(d['statusCode']),
      _clean(d['status']),
      _clean(d['durationMs']),
      _clean(d['error']),
      _kvOf(d['requestHeaders']),
      _cut(d['requestBody'], maxChars),
      _kvOf(d['responseHeaders']),
      _cut(d['responseBody'], maxChars),
      _clean(d['initiator']),
      _cut(d['initiatorStack'], maxChars),
      '${reqBody.length}',
      '${respBody.length}',
      clipped ? '1' : '0',
    ].join(_sep) +
        _row;
  }

  @override
  Future<String> networkDetailRaw({
    String? id,
    String? urlContains,
    String? method,
    int maxChars = 2000,
    int limit = 1,
  }) async {
    final m = (method ?? '').toUpperCase();
    final sb = StringBuffer();
    var hits = 0;
    if (id != null && id.isNotEmpty) {
      try {
        final d = await _http.getJson('/v1/network/detail',
            query: <String, String>{'id': id});
        return _detailRow(d, maxChars: maxChars);
      } on AgentHttpError catch (e) {
        if (e.statusCode == 404) return 'NOT_FOUND';
        rethrow;
      }
    }
    // 没有 id 时按 urlContains（可叠加 method）从新到旧找。
    final items = await _http.items('/v1/network', const <String, String>{'limit': '500'});
    for (final e in items.reversed) {
      final url = (e['url'] ?? '').toString();
      if (urlContains != null && urlContains.isNotEmpty && !url.contains(urlContains)) {
        continue;
      }
      if (m.isNotEmpty && (e['method'] ?? '').toString().toUpperCase() != m) {
        continue;
      }
      final rid = (e['id'] ?? '').toString();
      if (rid.isEmpty) continue;
      try {
        final d = await _http.getJson('/v1/network/detail',
            query: <String, String>{'id': rid});
        sb.write(_detailRow(d, maxChars: maxChars));
        hits++;
      } on AgentHttpError {
        // 详情被清了：跳过这条。
        continue;
      }
      if (hits >= limit) break;
    }
    return hits == 0 ? 'NOT_FOUND' : sb.toString();
  }

  @override
  Future<String> consoleRaw({
    String? level,
    String? keyword,
    int? sinceMs,
    int limit = 50,
    int offset = 0,
    bool tail = true,
    int maxChars = 500,
    bool withPath = false,
  }) async {
    final items = await _http.items('/v1/logs', <String, String>{
      // 服务端先粗筛；tail=false 时多取 offset 条，再按窗口切。
      'limit': '${tail ? limit : (offset + limit).clamp(1, 2000)}',
      if (level != null && level.isNotEmpty) 'level': level,
      if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
      if (sinceMs != null && sinceMs > 0) 'sinceMs': '$sinceMs',
    });
    final sb = StringBuffer();
    if (withPath) {
      try {
        final st = await _http.state();
        final p = (st['logFilePath'] ?? '').toString();
        if (p.isNotEmpty) sb.write('#path$_sep$p$_row');
      } catch (_) {
        // 旧版 app 没有 logFilePath：不插这一行。
      }
    }
    final List<Map<String, Object?>> window;
    if (tail) {
      window = items;
    } else {
      final start = offset < 0 ? 0 : offset;
      window = start >= items.length
          ? const <Map<String, Object?>>[]
          : items.sublist(start, (start + limit).clamp(0, items.length));
    }
    for (final e in window) {
      sb
        ..write(_clean(e['level']))
        ..write(_sep)
        ..write(_clean(e['tag']))
        ..write(_sep)
        ..write(_cut(e['message'], maxChars))
        ..write(_sep)
        ..write(_clean(e['time']))
        ..write(_row);
    }
    return sb.toString();
  }

  @override
  Future<String> exceptionsRaw({
    String? kind,
    String? typeContains,
    String? keyword,
    int? sinceMs,
    int limit = 20,
  }) async {
    final items = await _http.exceptions(limit: 500);
    final filtered = <Map<String, Object?>>[];
    final k = (kind ?? '').toLowerCase();
    for (final e in items) {
      if (k.isNotEmpty && k != 'all' && (e['kind'] ?? '').toString() != k) {
        continue;
      }
      final type = (e['type'] ?? '').toString();
      if (typeContains != null && typeContains.isNotEmpty && !type.contains(typeContains)) {
        continue;
      }
      if (keyword != null && keyword.isNotEmpty) {
        final hay = '${e['message'] ?? ''}\n${e['context'] ?? ''}\n${e['stack'] ?? ''}';
        if (!hay.contains(keyword)) continue;
      }
      if (sinceMs != null) {
        final t = DateTime.tryParse('${e['time'] ?? ''}');
        if (t == null || t.millisecondsSinceEpoch < sinceMs) continue;
      }
      filtered.add(e);
    }
    final start = filtered.length > limit ? filtered.length - limit : 0;
    final sb = StringBuffer();
    for (final e in filtered.skip(start)) {
      final time = DateTime.tryParse('${e['time'] ?? ''}');
      sb
        ..write(_clean(e['time']))
        ..write(_sep)
        ..write('${time?.millisecondsSinceEpoch ?? 0}')
        ..write(_sep)
        ..write(_clean(e['kind']))
        ..write(_sep)
        ..write(_clean(e['type']))
        ..write(_sep)
        ..write(_clean(e['count']))
        ..write(_sep)
        ..write(_cut(e['message'], 1200))
        ..write(_sep)
        ..write(_clean(e['library']))
        ..write(_sep)
        ..write(_cut(e['context'], 300))
        ..write(_sep)
        ..write(_cut(e['stack'], 4000))
        ..write(_sep)
        ..write(_clean(e['widget']))
        ..write(_sep)
        ..write(_clean(e['widgetFile']))
        ..write(_sep)
        ..write(_clean(e['widgetLine']))
        ..write(_sep)
        ..write(_clean(e['widgetColumn']))
        ..write(_row);
    }
    return sb.toString();
  }

  @override
  Future<String> timelineRaw({int? sinceMs, int limit = 60}) async {
    final items = await _http.items('/v1/timeline', <String, String>{
      'limit': '$limit',
      'full': '1',
      if (sinceMs != null && sinceMs > 0) 'sinceMs': '$sinceMs',
    });
    final sb = StringBuffer();
    for (final e in items) {
      final t = (e['t'] ?? '').toString();
      final ms = (e['ms'] as num?)?.toInt() ?? 0;
      final iso = DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();
      switch (t) {
        case 'route':
          sb
            ..write('route')
            ..write(_sep)
            ..write('$ms')
            ..write(_sep)
            ..write(iso)
            ..write(_sep)
            ..write(_clean(e['action']))
            ..write(_sep)
            ..write(_cut(e['name'], 200))
            ..write(_sep)
            ..write(_cut(e['prev'], 200))
            ..write(_sep)
            ..write(_clean(e['phase']))
            ..write(_row);
        case 'net':
          sb
            ..write('net')
            ..write(_sep)
            ..write('$ms')
            ..write(_sep)
            ..write(iso)
            ..write(_sep)
            ..write(_clean(e['method']))
            ..write(_sep)
            ..write(_clean(e['code']))
            ..write(_sep)
            ..write(_clean(e['dur']))
            ..write(_sep)
            ..write(_clean(e['status']))
            ..write(_sep)
            ..write(_cut(e['url'], 300))
            ..write(_sep)
            ..write(_clean(e['err']))
            ..write(_row);
        case 'log':
          sb
            ..write('log')
            ..write(_sep)
            ..write('$ms')
            ..write(_sep)
            ..write(iso)
            ..write(_sep)
            ..write(_clean(e['level']))
            ..write(_sep)
            ..write(_clean(e['tag']))
            ..write(_sep)
            ..write(_cut(e['msg'], 300))
            ..write(_row);
        case 'exception':
          sb
            ..write('exception')
            ..write(_sep)
            ..write('$ms')
            ..write(_sep)
            ..write(iso)
            ..write(_sep)
            ..write(_clean(e['kind']))
            ..write(_sep)
            ..write(_clean(e['type']))
            ..write(_sep)
            ..write(_clean(e['count']))
            ..write(_sep)
            ..write(_cut(e['msg'], 300))
            ..write(_row);
      }
    }
    return sb.toString();
  }

  @override
  Future<String> routeStackRaw() => Future<String>.error(
        const SessionApiUnsupported('路由栈',
            cap: 'route:stack',
            hint: '直连通道读不到 NavigatorState 的私有路由历史；看时间轴里的路由事件流'),
      );

  @override
  Future<List<String>> routeNames() async {
    // 路由栈本身是 NavigatorState 的私有历史，直连读不到；但 app 一直在记
    // 路由事件（NavigatorObserver），按近 200 条事件重放一遍就能得到当前栈。
    // 注意 pop/remove 事件的 routeName 是**离开**的页面，不能拿来当栈顶。
    final events = await _http.items('/v1/routes', <String, String>{
      'limit': '200',
    });
    final stack = <String>[];
    void removeWhere(String name) {
      if (name.isEmpty) return;
      if (stack.isNotEmpty && stack.last == name) {
        stack.removeLast();
      } else {
        stack.removeWhere((n) => n == name);
      }
    }

    for (final e in events) {
      final action = (e['action'] ?? '').toString().toLowerCase();
      final name = (e['routeName'] ?? '').toString();
      if (name.isEmpty) continue;
      switch (action) {
        case 'push':
          if (stack.isEmpty || stack.last != name) stack.add(name);
        case 'pop':
        case 'remove':
          removeWhere(name);
        case 'replace':
          removeWhere((e['previousRouteName'] ?? '').toString());
          stack.add(name);
      }
    }
    // 事件窗口被截断（超过 200 条）时重放结果可能空着：用最新事件
    // 能看到的页面兜底（pop 后在上层的是 previousRouteName）。
    if (stack.isEmpty && events.isNotEmpty) {
      final last = events.last;
      final prev = (last['previousRouteName'] ?? '').toString();
      final name = (last['routeName'] ?? '').toString();
      final shown = prev.isNotEmpty ? prev : name;
      if (shown.isNotEmpty) stack.add(shown);
    }
    return stack;
  }

  @override
  Future<String?> topRoute() async {
    final names = await routeNames();
    return names.isEmpty ? null : names.last;
  }

  @override
  Future<String> framesRaw() => Future<String>.error(
        const SessionApiUnsupported('帧耗时统计',
            cap: 'perf', hint: '直连通道暂未提供帧统计端点'),
      );

  @override
  Future<List<Map<String, String>>> networkRecords({
    DateTime? since,
    int limit = 100,
  }) async {
    final items = await _http.network(limit: limit);
    final out = <Map<String, String>>[];
    for (final e in items) {
      if (since != null) {
        final t = DateTime.tryParse('${e['time'] ?? ''}');
        if (t == null || !t.isAfter(since)) continue;
      }
      out.add(<String, String>{
        'method': '${e['method'] ?? ''}',
        'url': '${e['url'] ?? ''}',
        'statusCode': '${e['statusCode'] ?? ''}',
        'status': '${e['status'] ?? ''}',
      });
    }
    return out;
  }

  // -- 组件树 -------------------------------------------------------------

  @override
  Future<String> findWidgetRaw({
    required String by,
    required String value,
    bool exact = false,
    int limit = 20,
  }) async {
    final j = await _http.getJson('/v1/widgets', query: <String, String>{
      'by': by,
      'value': value,
      'exact': exact ? '1' : '0',
      'limit': '$limit',
    });
    // app 直接回 VM 同格式原始串，这里不做二次拼装。
    return (j['raw'] ?? 'NOT_FOUND').toString();
  }

  @override
  Future<String> elementCenterRaw(int ref) async {
    final j = await _http
        .getJson('/v1/center', query: <String, String>{'ref': '$ref'});
    return (j['result'] ?? 'NOT_FOUND').toString();
  }

  @override
  Future<String> assertVisibleRaw(String type) async {
    final j = await _http
        .getJson('/v1/assert', query: <String, String>{'type': type});
    return (j['result'] ?? 'NOT_FOUND').toString();
  }

  @override
  Future<Map<String, Object?>> widgetTreeJson() =>
      _http.getJson('/v1/wtree');

  @override
  Future<String> pageTextRaw({int limit = 200}) async {
    final j =
        await _http.getJson('/v1/pagetext', query: <String, String>{'limit': '$limit'});
    return (j['text'] ?? '').toString();
  }

  // -- 动作 ---------------------------------------------------------------

  Future<String> _postResult(
    String path,
    Map<String, Object?> body, {
    String key = 'result',
  }) async {
    final j = await _http.postJson(path, jsonBody: body);
    return (j[key] ?? '').toString();
  }

  @override
  Future<String> tapRef(int ref, {int pointer = 0}) =>
      _postResult('/v1/tap', <String, Object?>{'ref': ref});

  @override
  Future<String> tapAt(double x, double y, {bool phys = false, int pointer = 0}) =>
      _postResult('/v1/tap', <String, Object?>{
        'x': x,
        'y': y,
        if (phys) 'phys': true,
      });

  @override
  Future<String> inputText(String text) =>
      _postResult('/v1/input', <String, Object?>{'text': text});

  @override
  Future<String> routeOp(String op, {String name = ''}) =>
      _postResult('/v1/navigate', <String, Object?>{
        'op': op,
        'name': name,
      });

  @override
  Future<(String, String)> swipe({
    required double x1,
    required double y1,
    required double x2,
    required double y2,
    int durationMs = 300,
    bool phys = false,
  }) async {
    final j = await _http.postJson('/v1/swipe', jsonBody: <String, Object?>{
      'x1': x1,
      'y1': y1,
      'x2': x2,
      'y2': y2,
      'durationMs': durationMs,
      if (phys) 'phys': true,
    });
    return ((j['result'] ?? '').toString(), (j['error'] ?? '').toString());
  }

  @override
  Future<(double, double, double)?> screenInfo() async {
    try {
      final j = await _http.getJson('/v1/screen');
      final w = (j['width'] as num?)?.toDouble();
      final h = (j['height'] as num?)?.toDouble();
      final dpr = (j['dpr'] as num?)?.toDouble() ?? 1.0;
      if (w == null || h == null) return null;
      return (w, h, dpr);
    } catch (_) {
      return null;
    }
  }

  // -- 画面 ---------------------------------------------------------------

  @override
  Future<String> screenshotBase64() async {
    final j = await _http.getJson('/v1/screenshot');
    if (j['ok'] != true) {
      throw AgentHttpError(0, '${j['error'] ?? '截图失败'}');
    }
    return (j['data'] ?? '').toString();
  }

  @override
  Future<String> evalRaw(String lib, String expr) => Future<String>.error(
        const SessionApiUnsupported('任意求值（eval）',
            cap: 'debug', hint: 'AOT 没有 kernel，eval 物理不可用；用固定工具代替'),
      );

  @override
  Future<void> close() async {
    // HTTP 无长连接状态，nothing to do。
  }
}

/// 便捷：JSON 编码（测试里复用同一份转义规则）。
String debugJson(Object? v) => jsonEncode(v);