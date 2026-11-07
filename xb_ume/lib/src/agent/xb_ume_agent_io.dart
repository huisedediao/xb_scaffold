// 直连 Agent 服务的 dart:io 实现（Android / iOS / 桌面 / 命令行）。
//
// 只读数据面，端点与返回形状刻意与 GUI 现有 `/api/*` 保持一致：
//   GET  /v1/hello            服务标识 + 包名/版本/能力（发现用，不校验 token）
//   GET  /v1/state            各缓冲区条数、落盘路径、运行时长
//   GET  /v1/logs             应用日志（level / tag / keyword / sinceMs 过滤）
//   GET  /v1/exceptions       结构化异常
//   GET  /v1/network          网络请求摘要（与 /api/network 同形）
//   GET  /v1/network/detail   单条请求全字段（与 /api/network/detail 同形）
//   GET  /v1/routes           路由事件
//   GET  /v1/frames           帧耗时
//   GET  /v1/timeline         路由+网络合并事件（已是 GUI 时间轴条目形状）
//   POST /v1/clear?what=...   清空某个缓冲区（logs/exceptions/network/routes/frames）
//
// 安全：默认只绑 127.0.0.1，且只接受回环来源；token 非空时数据端点必须带
// `x-xbume-token`。没有任何执行/eval/文件写入端点——release 包也不该有。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/xb_ume_controller.dart';
import '../models/xb_ume_network_item.dart';
import 'xb_ume_agent_types.dart';

/// 起服务；`options.enabled == false` 时直接返回 null（默认关闭）。
///
/// 启动失败（端口被占、权限受限）不影响 app：只打日志并返回 null。
Future<XBUmeAgentServer?> startXBUmeAgentServer({
  required XBUmeController controller,
  XBUmeAgentOptions options = const XBUmeAgentOptions(),
}) async {
  if (!options.enabled) return null;
  // 包名是 release 下唯一可靠的应用标识，能自采就自采（Android 读进程名），
  // 采不到再留空由 `--dart-define=XBUME_AGENT_APP` 补。
  final resolved = options.packageName.isNotEmpty
      ? options
      : options.copyWith(packageName: _detectPackageName());
  final server = _XBUmeAgentServer(controller, resolved);
  try {
    await server.start();
    return server;
  } catch (e) {
    debugPrint('[xb_ume] 直连 Agent 启动失败（不影响 app）：$e');
    await server.close();
    return null;
  }
}

/// 读进程名当包名：Android 的 `/proc/self/cmdline` 首段通常就是包名（
/// `com.foo.bar` 或 `com.foo.bar:push`）。其他平台读不到，返回空串。
String _detectPackageName() {
  if (!Platform.isAndroid) return '';
  try {
    final raw = File('/proc/self/cmdline').readAsStringSync();
    final first = raw.split('\u0000').first.trim();
    if (first.isEmpty) return '';
    // 子进程名带 `:xxx` 后缀，归一化到主包名。
    final i = first.indexOf(':');
    return i > 0 ? first.substring(0, i) : first;
  } catch (_) {
    return '';
  }
}

class _XBUmeAgentServer implements XBUmeAgentServer {
  _XBUmeAgentServer(this._controller, this._options);

  final XBUmeController _controller;
  final XBUmeAgentOptions _options;

  HttpServer? _http;
  final DateTime _startedAt = DateTime.now();

  /// 进程启动随机串：同一包重启后指纹会变，IDE 侧据此识别「同一实例」。
  final String _bootId = _randomHex(8);

  String get appLabel => _options.packageName.isNotEmpty
      ? _options.packageName
      : (_options.appId.isNotEmpty ? _options.appId : 'flutter_app');

  Future<void> start() async {
    final address = _options.bindAllInterfaces
        ? InternetAddress.anyIPv4
        : InternetAddress.loopbackIPv4;
    final http = await HttpServer.bind(address, _options.port, shared: false);
    _http = http;
    http.listen(
      (req) => unawaited(_handle(req)),
      onError: (Object e) => debugPrint('[xb_ume] 直连 Agent 监听异常：$e'),
      cancelOnError: false,
    );
    debugPrint('[xb_ume] 直连 Agent 已启动：http://127.0.0.1:${http.port} '
        '($appLabel, caps=${_options.caps.join(',')})');
  }

  @override
  int get port => _http?.port ?? 0;

  @override
  String get baseUrl => 'http://127.0.0.1:$port';

  @override
  Future<void> close() async {
    final http = _http;
    _http = null;
    if (http == null) return;
    try {
      await http.close(force: true);
    } catch (_) {
      // 关闭失败无需处理（进程退出时系统会回收）。
    }
  }

  // -- 路由 ---------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    var sent = false;

    Future<void> send(int code, Object? body) async {
      if (sent) return;
      sent = true;
      req.response.statusCode = code;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(body));
    }

    try {
      // 即便绑定 0.0.0.0，也只让本机读写调试数据。
      final remote = req.connectionInfo?.remoteAddress;
      if (remote != null && !remote.isLoopback) {
        await send(HttpStatus.forbidden, <String, Object?>{'error': '仅允许本机访问'});
        return;
      }
      final path = req.uri.path;
      if (req.method != 'GET' && req.method != 'POST') {
        req.response.headers.set('Allow', 'GET, POST');
        await send(HttpStatus.methodNotAllowed,
            <String, Object?>{'error': '只支持 GET / POST'});
        return;
      }
      // 发现阶段还不知道 token，hello 只回非敏感元信息。
      if (path == '/v1/hello') {
        await send(HttpStatus.ok, _hello());
        return;
      }
      if (!_authorized(req)) {
        await send(HttpStatus.unauthorized,
            <String, Object?>{'error': '缺少或错误的 x-xbume-token'});
        return;
      }
      final query = req.uri.queryParameters;

      switch (path) {
        case '/v1/state':
          await send(HttpStatus.ok, _stateJson());
          return;
        case '/v1/logs':
          await send(HttpStatus.ok, _logsJson(query));
          return;
        case '/v1/exceptions':
          await send(HttpStatus.ok, _listJson(
            _controller.exceptions
                .map((e) => e.toJson())
                .toList(growable: false),
            query,
          ));
          return;
        case '/v1/network':
          await send(HttpStatus.ok, _networkListJson(query));
          return;
        case '/v1/network/detail':
          final id = query['id'] ?? '';
          XBUmeNetworkItem? hit;
          for (final e in _controller.network) {
            if (e.id == id) {
              hit = e;
              break;
            }
          }
          if (hit == null) {
            await send(HttpStatus.notFound,
                <String, Object?>{'error': '请求不存在（可能已被清除）'});
            return;
          }
          await send(HttpStatus.ok, _networkDetailJson(hit));
          return;
        case '/v1/network/clear':
          if (req.method != 'POST') {
            req.response.headers.set('Allow', 'POST');
            await send(HttpStatus.methodNotAllowed,
                <String, Object?>{'error': '该接口仅支持 POST'});
            return;
          }
          _controller.clearNetwork();
          await send(HttpStatus.ok, <String, Object?>{'ok': true});
          return;
        case '/v1/routes':
          await send(HttpStatus.ok, _listJson(
            _controller.routes.map((e) => e.toJson()).toList(growable: false),
            query,
          ));
          return;
        case '/v1/frames':
          await send(HttpStatus.ok, _listJson(
            _controller.frames.map((e) => e.toJson()).toList(growable: false),
            query,
          ));
          return;
        case '/v1/timeline':
          await send(HttpStatus.ok, _timelineJson(query));
          return;
        case '/v1/clear':
          if (req.method != 'POST') {
            req.response.headers.set('Allow', 'POST');
            await send(HttpStatus.methodNotAllowed,
                <String, Object?>{'error': '该接口仅支持 POST'});
            return;
          }
          final what = query['what'] ?? '';
          switch (what) {
            case 'logs':
              _controller.clearLogs();
            case 'exceptions':
              _controller.clearExceptions();
            case 'network':
              _controller.clearNetwork();
            case 'routes':
              _controller.clearRoutes();
            case 'frames':
              _controller.clearFrames();
            default:
              await send(HttpStatus.badRequest,
                  <String, Object?>{'error': 'what 只支持 logs/exceptions/network/routes/frames'});
              return;
          }
          await send(HttpStatus.ok, <String, Object?>{'ok': true, 'what': what});
          return;
        default:
          await send(HttpStatus.notFound,
              <String, Object?>{'error': '未知端点：$path'});
          return;
      }
    } catch (e) {
      await send(HttpStatus.internalServerError,
          <String, Object?>{'error': '$e'});
    } finally {
      try {
        await req.response.close();
      } catch (_) {
        // 客户端提前断开时 close 会抛，忽略。
      }
    }
  }

  bool _authorized(HttpRequest req) {
    final token = _options.token;
    if (token.isEmpty) return true;
    final given = req.headers.value('x-xbume-token') ??
        req.uri.queryParameters['token'] ??
        '';
    return _constantTimeEquals(given, token);
  }

  // -- 响应体 -------------------------------------------------------------

  Map<String, Object?> _hello() {
    return <String, Object?>{
      'service': kXBUmeAgentService,
      'protocol': kXBUmeAgentProtocol,
      'version': kXBUmeAgentVersion,
      'appId': _options.appId,
      'packageName': _options.packageName,
      'bootId': _bootId,
      'obfuscated': _options.obfuscated,
      'caps': _options.caps,
      if (_options.vmPort != null) 'vmPort': _options.vmPort,
      'pid': pid,
      'os': Platform.operatingSystem,
      'startedAt': _startedAt.toIso8601String(),
    };
  }

  Map<String, Object?> _stateJson() {
    return <String, Object?>{
      'ok': true,
      'app': appLabel,
      'bootId': _bootId,
      'obfuscated': _options.obfuscated,
      'caps': _options.caps,
      'logs': _controller.logs.length,
      'exceptions': _controller.exceptions.length,
      'network': _controller.network.length,
      'routes': _controller.routes.length,
      'frames': _controller.frames.length,
      'logFilePath': _controller.logFilePath ?? '',
      'uptimeSec': DateTime.now().difference(_startedAt).inSeconds,
    };
  }

  Map<String, Object?> _logsJson(Map<String, String> query) {
    final limit = _intParam(query['limit'], 200, 1, 2000);
    final level = (query['level'] ?? '').toLowerCase();
    final tag = (query['tag'] ?? '').toLowerCase();
    final keyword = (query['keyword'] ?? '').toLowerCase();
    final sinceMs = _intParam(query['sinceMs'], 0, 0, 1 << 62);
    final all = _controller.logs;
    final filtered = <Map<String, Object?>>[];
    for (final item in all) {
      if (level.isNotEmpty && item.level.name != level) continue;
      if (tag.isNotEmpty && !item.tag.toLowerCase().contains(tag)) continue;
      if (sinceMs > 0 && item.time.millisecondsSinceEpoch <= sinceMs) continue;
      if (keyword.isNotEmpty) {
        final hay = '${item.tag}\n${item.message}\n${item.stack ?? ''}'
            .toLowerCase();
        if (!hay.contains(keyword)) continue;
      }
      filtered.add(item.toJson());
    }
    final items = filtered.length > limit
        ? filtered.sublist(filtered.length - limit)
        : filtered;
    return <String, Object?>{
      'ok': true,
      'total': filtered.length,
      'count': items.length,
      'items': items,
    };
  }

  /// 网络摘要：字段与 GUI `/api/network` 完全一致（前端可直接渲染）。
  Map<String, Object?> _networkListJson(Map<String, String> query) {
    final limit = _intParam(query['limit'], 300, 1, 2000);
    final all = _controller.network;
    final start = all.length > limit ? all.length - limit : 0;
    final items = <Map<String, Object?>>[];
    for (final e in all.skip(start)) {
      items.add(<String, Object?>{
        'id': e.id,
        'time': e.time.toIso8601String(),
        'method': e.method,
        'url': e.url,
        'statusCode': (e.statusCode ?? '').toString(),
        'durationMs': (e.durationMs ?? '').toString(),
        'status': e.status.name,
        'error': e.error ?? '',
      });
    }
    return <String, Object?>{'ok': true, 'total': all.length, 'items': items};
  }

  /// 单条请求：与 GUI `/api/network/detail` 同形（header 拍成 [{k,v}]）。
  Map<String, Object?> _networkDetailJson(XBUmeNetworkItem e) {
    List<Map<String, String>> kv(Map<String, dynamic>? m) {
      if (m == null || m.isEmpty) return const <Map<String, String>>[];
      return <Map<String, String>>[
        for (final entry in m.entries)
          <String, String>{
            'k': entry.key,
            'v': entry.value?.toString() ?? '',
          },
      ];
    }

    Object? body(dynamic v) {
      if (v == null) return '';
      if (v is String) return v;
      try {
        return jsonEncode(v);
      } catch (_) {
        return v.toString();
      }
    }

    return <String, Object?>{
      'query': kv(e.queryParameters),
      'requestHeaders': kv(e.requestHeaders),
      'requestBody': body(e.requestBody),
      'responseHeaders': kv(e.responseHeaders),
      'responseBody': body(e.responseBody),
      'stack': e.stack ?? '',
      'initiator': e.initiator ?? '',
      'initiatorStack': e.initiatorStack ?? '',
      'method': e.method,
      'url': e.url,
      'statusCode': e.statusCode ?? 0,
    };
  }

  /// 列表通用分页：`limit` 取末尾 N 条（旧→新），`sinceMs` 过滤毫秒时间戳。
  Map<String, Object?> _listJson(
    List<Map<String, dynamic>> all,
    Map<String, String> query,
  ) {
    final limit = _intParam(query['limit'], 200, 1, 2000);
    final sinceMs = _intParam(query['sinceMs'], 0, 0, 1 << 62);
    final filtered = sinceMs <= 0
        ? all
        : all.where((e) {
            final t = DateTime.tryParse('${e['time'] ?? ''}');
            return t != null && t.millisecondsSinceEpoch > sinceMs;
          }).toList(growable: false);
    final items = filtered.length > limit
        ? filtered.sublist(filtered.length - limit)
        : filtered;
    return <String, Object?>{
      'ok': true,
      'total': filtered.length,
      'count': items.length,
      'items': items,
    };
  }

  /// 时间轴：路由事件 + 网络事件，字段与 GUI `_tlItems` 条目一致，
  /// 前端 upsert 逻辑可原样复用。
  Map<String, Object?> _timelineJson(Map<String, String> query) {
    final limit = _intParam(query['limit'], 500, 1, 2000);
    final sinceMs = _intParam(query['sinceMs'], 0, 0, 1 << 62);
    final items = <Map<String, Object?>>[];
    for (final e in _controller.routes) {
      final ms = e.time.millisecondsSinceEpoch;
      if (ms <= sinceMs) continue;
      items.add(<String, Object?>{
        't': 'route',
        'id': e.id,
        'ms': ms,
        'action': e.action.name,
        'name': e.routeName,
        'prev': e.previousRouteName ?? '',
        'phase': e.phase,
      });
    }
    for (final e in _controller.network) {
      final ms = e.time.millisecondsSinceEpoch;
      if (ms <= sinceMs) continue;
      items.add(<String, Object?>{
        't': 'net',
        'id': e.id,
        'ms': ms,
        'method': e.method,
        'url': e.url,
        'code': (e.statusCode ?? '').toString(),
        'dur': (e.durationMs ?? '').toString(),
        'status': e.status.name,
        'err': e.error ?? '',
      });
    }
    items.sort((a, b) => ((a['ms'] as int)).compareTo(b['ms'] as int));
    final out = items.length > limit
        ? items.sublist(items.length - limit)
        : items;
    return <String, Object?>{'ok': true, 'count': out.length, 'items': out};
  }
}

// -- 工具函数 -------------------------------------------------------------

/// 随包发布的版本号（发版时同步 pubspec 与本值）。
const String kXBUmeAgentVersion = '0.9.7';

int _intParam(String? raw, int fallback, int min, int max) {
  final v = int.tryParse(raw ?? '') ?? fallback;
  if (v < min) return min;
  if (v > max) return max;
  return v;
}

/// token 比较走定时安全实现：长度不同也逐字符比较，避免计时侧信道。
bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

String _randomHex(int bytes) {
  final rand = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buf.write(rand.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}