// 探针：尝试用 ext.flutter.inspector.screenshot 在 iOS 上截整屏。
// 用法: dart run tmp_test/vm_inspector_shot_probe.dart <wsUrl>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

int _id = 0;
final Map<String, Completer<Map<String, Object?>>> _pending = {};

Future<Map<String, Object?>> _rpc(
    WebSocket ws, String method, Map<String, Object?> params) {
  final id = 'r${++_id}';
  final c = Completer<Map<String, Object?>>();
  _pending[id] = c;
  ws.add(jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': params,
  }));
  return c.future.timeout(const Duration(seconds: 20));
}

Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args[0]);
  ws.listen((m) {
    final j = jsonDecode(m as String);
    if (j is Map && j['id'] != null && _pending.containsKey(j['id'].toString())) {
      final c = _pending.remove(j['id'].toString())!;
      if (j['error'] != null) {
        c.complete({'__error__': j['error']});
      } else {
        c.complete(Map<String, Object?>.from(j['result'] as Map));
      }
    }
  });
  final vm = await _rpc(ws, 'getVM', {});
  final isoId = ((vm['isolates'] as List).cast<Map>().firstWhere(
        (i) => i['isSystemIsolate'] == false,
        orElse: () => (vm['isolates'] as List).cast<Map>().first,
      ))['id'] as String;

  final tree = await _rpc(ws, 'ext.flutter.inspector.getRootWidgetSummaryTree',
      {'isolateId': isoId, 'objectGroup': 'probe'});
  if (tree.containsKey('__error__')) {
    print('TREE ERROR: ${jsonEncode(tree['__error__'])}');
    await ws.close();
    return;
  }
  final raw = tree['result']?.toString() ?? '';
  print('TREE keys=${tree.keys.toList()} len=${raw.length} head=${raw.substring(0, raw.length > 160 ? 160 : raw.length)}');
  String rootId = 'root';
  try {
    final node = jsonDecode(raw) as Map;
    rootId = (node['valueId'] ?? node['objectId'] ?? 'root').toString();
  } catch (_) {
    // result 是 Dart Map 的 toString（非 JSON），用正则取第一个 valueId。
    final m = RegExp(r'valueId:\s*([A-Za-z0-9_-]+)').firstMatch(raw);
    if (m != null) rootId = m.group(1)!;
  }
  print('rootId=$rootId');

  final shot = await _rpc(ws, 'ext.flutter.inspector.screenshot', {
    'isolateId': isoId,
    'id': rootId,
    'width': '10000',
    'height': '10000',
    'maxPixelRatio': '1.0',
    'debugPaint': 'false',
  });
  if (shot.containsKey('__error__')) {
    print('SHOT ERROR: ${jsonEncode(shot['__error__'])}');
  } else {
    final b64 = shot['result']?.toString() ?? '';
    print('SHOT keys=${shot.keys.toList()} b64Len=${b64.length} head=${b64.isEmpty ? "(empty)" : b64.substring(0, 30)}');
    if (b64.isNotEmpty) {
      File('/tmp/ios_shot.png').writeAsBytesSync(base64Decode(b64));
      print('saved /tmp/ios_shot.png');
    }
  }
  await ws.close();
}
