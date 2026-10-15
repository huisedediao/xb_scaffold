import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? args[0] : '51680';
  final ws = await WebSocket.connect('ws://127.0.0.1:$port/ws');
  var id = 0;
  final pending = <String, Completer<dynamic>>{};
  ws.listen((m) {
    if (m is! String) return;
    final j = jsonDecode(m) as Map<String, dynamic>;
    final i = j['id'];
    if (i != null && pending.containsKey(i)) pending.remove(i)!.complete(j);
  });
  Future<dynamic> call(String method, [Map<String, dynamic>? p]) {
    final i = '${++id}';
    final c = Completer<dynamic>();
    pending[i] = c;
    ws.add(jsonEncode({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': p ?? {}}));
    return c.future;
  }
  final iso = ((await call('getVM'))['result']['isolates'] as List).first['id'] as String;
  final re = await call('getIsolate', {'isolateId': iso});
  final libs = ((re['result'] as Map)['libraries'] as List).cast<Map>();
  final uris = libs.map((l) => (l['uri'] ?? '').toString()).where((u) => u.contains('text_input') || u.contains('editable')).toList();
  print(uris.join('\n'));
  await ws.close();
}
