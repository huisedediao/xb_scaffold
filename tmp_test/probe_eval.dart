// 通用 eval 探针：在指定库上下文执行表达式。
// 用法: dart run tmp_test/probe_eval.dart <wsUrl> <库uri关键字> <表达式>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

int _id = 0;
final Map<String, Completer<Map<String, Object?>>> _pending = {};

Future<Map<String, Object?>> _rpc(WebSocket ws, String method, Map<String, Object?> params) {
  final id = 'r${++_id}';
  final c = Completer<Map<String, Object?>>();
  _pending[id] = c;
  ws.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
  return c.future.timeout(const Duration(seconds: 30));
}

Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args[0]);
  ws.listen((m) {
    final j = jsonDecode(m as String);
    if (j is Map && j['id'] != null && _pending.containsKey(j['id'].toString())) {
      final c = _pending.remove(j['id'].toString())!;
      if (j['error'] != null) {
        c.completeError(j['error']);
      } else {
        c.complete(Map<String, Object?>.from(j['result'] as Map));
      }
    }
  });
  final vm = await _rpc(ws, 'getVM', {});
  final iso = (vm['isolates'] as List).cast<Map>().firstWhere(
      (i) => i['isSystemIsolate'] == false && i['name'] == 'main',
      orElse: () => (vm['isolates'] as List).cast<Map>().first,
    );
    final isoId = iso['id'] as String;
  final isor = await _rpc(ws, 'getIsolate', {'isolateId': isoId});
  final lib = (isor['libraries'] as List).firstWhere(
    (l) => (l as Map)['uri'].toString().contains(args[1]),
    orElse: () => throw StateError('库未找到: ${args[1]}，现有: ${(isor['libraries'] as List).where((l) => (l as Map)['uri'].toString().contains('xb_ume')).map((l) => (l as Map)['uri']).take(10)}'),
  ) as Map;
  final r = await _rpc(ws, 'evaluate', {
    'isolateId': isoId,
    'targetId': lib['id'],
    'expression': args[2],
  });
  final v = r['value'] ?? jsonEncode(r);
  print('结果: $v');
  await ws.close();
  exit(0);
}
