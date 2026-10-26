// 探针：直接调用 VM service 的 _flutter.screenshot，看是否返回图像与错误原因。
// 用法: dart run tmp_test/vm_shot_probe.dart <wsUrl>
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
  final r = await _rpc(ws, '_flutter.screenshot', {'isolateId': isoId});
  if (r.containsKey('__error__')) {
    print('ERROR: ${jsonEncode(r['__error__'])}');
  } else {
    final keys = r.keys.toList();
    final data = r['data']?.toString() ?? r['screenshot']?.toString() ?? '';
    print('keys=$keys dataLen=${data.length}');
    print('head=${data.isEmpty ? "(empty)" : data.substring(0, 40)}');
  }
  await ws.close();
}
