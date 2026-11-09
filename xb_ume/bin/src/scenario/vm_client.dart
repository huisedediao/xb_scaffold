// CLI 场景执行用的精简 VM service 客户端。
//
// 只保留 evaluate / screenshot / 堆实例查询需要的 JSON-RPC 能力，行为与
// GUI（bin/ide_gui.dart 的 _SandboxRpc）对齐，但不依赖 GUI 服务进程，
// 供 `dart run xb_ume:run` 在纯命令行/CI 环境执行场景。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 把 CLI 传入的 `--uri` 归一化为 VM service WebSocket 地址。
///
/// 支持纯端口（65296）、host:port、http(s) URL 与完整 ws(s) URL；
/// 后三者补 `/ws` 路径。
String normalizeVmUri(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  if (RegExp(r'^\d+$').hasMatch(s)) return 'ws://127.0.0.1:$s/ws';
  if (s.startsWith('ws://') || s.startsWith('wss://')) {
    final u = Uri.parse(s);
    if (u.path.isEmpty || u.path == '/') {
      return s.endsWith('/') ? '${s}ws' : '$s/ws';
    }
    return s;
  }
  if (s.startsWith('http://') || s.startsWith('https://')) {
    final u = Uri.parse(s);
    final scheme = u.scheme == 'https' ? 'wss' : 'ws';
    final path = u.path.isEmpty || u.path == '/' ? '/ws' : u.path;
    return '$scheme://${u.authority}$path';
  }
  // host:port
  if (RegExp(r'^[\w.-]+:\d+$').hasMatch(s)) return 'ws://$s/ws';
  return s;
}

/// JSON-RPC error 转可读文案（透传 error.data.details，鸿蒙等引擎的细节在此）。
String vmErrorText(Object? error) {
  if (error == null) return '未知错误';
  if (error is String) return error;
  if (error is Map) {
    final msg = error['message']?.toString() ?? '';
    final data = error['data'];
    var details = '';
    if (data is Map) {
      details = data['details']?.toString() ?? '';
    } else if (data != null) {
      details = data.toString();
    }
    if (details.isEmpty) return msg.isEmpty ? jsonEncode(error) : msg;
    return msg.isEmpty ? details : '$msg: $details';
  }
  return error.toString();
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

class VmClient {
  VmClient(this.uri);

  final String uri;
  int _seq = 0;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  final Map<String, Completer<Object?>> _pending = {};
  String? _isolateId;
  final Map<String, String> _libIds = {};

  /// 建立连接（懒加载；同一连接复用多次 evaluate，避免每步反复握手）。
  Future<void> _ensureConnected() async {
    if (_socket != null) return;
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
          completer.completeError(vmErrorText(parsed['error']));
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

  /// 通用 VM service 调用。
  Future<Map<String, Object?>> rawRpc(
    String method, [
    Map<String, Object?>? params,
  ]) async {
    await _ensureConnected();
    await _resolveTarget();
    return _rpc(method, params);
  }

  /// 当前 isolate id。
  Future<String> isolateId() async {
    await _ensureConnected();
    await _resolveTarget();
    return _isolateId!;
  }

  /// 按库 uri 查找库 id（公开版本）。
  Future<String> libraryId(String uri) => _libraryId(uri);

  /// 热重启后 isolate 会更换，清掉缓存的 isolate / 库 id。
  void resetIsolateCache() {
    _isolateId = null;
    _libIds.clear();
  }

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

  /// 在 app 的 dart:io 库上下文执行表达式。
  Future<String> evalString(String expression) =>
      evalStringOn('dart:io', expression);

  /// 在 app 的指定库上下文执行表达式，返回完整字符串。
  /// 注意：表达式须为单行 IIFE——VM eval 对多行 IIFE 会返回未调用的 Closure。
  Future<String> evalStringOn(String libraryUri, String expression) async {
    await _ensureConnected();
    final libId = await _libraryId(libraryUri);
    final result = await _rpc('evaluate', {
      'isolateId': _isolateId,
      'targetId': libId,
      'expression': expression,
    });
    final resultType = result['type']?.toString();
    if (resultType != 'Instance' && resultType != '@Instance') {
      final message =
          result['message']?.toString() ?? result['valueAsString']?.toString();
      throw message == null || message.isEmpty
          ? '执行失败：${jsonEncode(result)}'
          : message;
    }
    var value = result['valueAsString']?.toString() ?? '';
    if (result['valueAsStringIsTruncated'] != true) return value;
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

  /// 截图（PNG base64）。
  ///
  /// 优先 `_flutter.screenshot`（macOS/Android 等）；不可用时（iOS 报
  /// Could not capture image screenshot）退回 inspector 根渲染对象 toImage。
  ///
  /// [maxPixelRatio] 非空时跳过 `_flutter.screenshot`（它只能出原图），
  /// 直接走 inspector 并按比例缩放：输出物理像素 = 逻辑尺寸 × 该比例。
  Future<String> screenshotBase64({double? maxPixelRatio}) async {
    if (maxPixelRatio == null) {
      try {
        final r = await rawRpc('_flutter.screenshot');
        final b64 = (r['data'] ?? r['screenshot'])?.toString() ?? '';
        if (b64.isNotEmpty) return b64;
      } catch (_) {}
    }
    final isoId = await isolateId();
    const group = 'xb_cli_shot';
    try {
      final tree = await rawRpc(
          'ext.flutter.inspector.getRootWidgetSummaryTree',
          <String, Object?>{'isolateId': isoId, 'objectGroup': group});
      final shot = await rawRpc(
          'ext.flutter.inspector.screenshot',
          <String, Object?>{
            'isolateId': isoId,
            // 根渲染对象即 RenderView；width/height 给 10000 表示不额外限制，
            // 由 maxPixelRatio 决定输出尺寸（1.0 即逻辑尺寸，与原 DPR 无关）。
            'id': inspectorRootId('${tree['result'] ?? ''}'),
            'width': '10000',
            'height': '10000',
            'maxPixelRatio': (maxPixelRatio ?? 1.0).toString(),
            'debugPaint': 'false',
          });
      return (shot['result'] ?? '').toString();
    } finally {
      try {
        await rawRpc('ext.flutter.inspector.disposeGroup',
            <String, Object?>{'isolateId': isoId, 'objectGroup': group});
      } catch (_) {}
    }
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await _socket?.close();
    _socket = null;
  }
}
