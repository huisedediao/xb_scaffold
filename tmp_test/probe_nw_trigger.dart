// 探针：经 VM service evaluate 在 xb_network_test_page.dart 库上下文触发
// init + GET + POST（绕过 UI 点击需要前台泵帧的问题），为 GUI Network
// 验证制造请求记录。
// 用法: dart run tmp_test/probe_nw_trigger.dart <wsUrl>
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
  return c.future.timeout(const Duration(seconds: 15));
}

Future<void> main(List<String> args) async {
  final ws = await WebSocket.connect(args.first);
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
    (l) => (l as Map)['uri'].toString().contains('xb_network_test_page.dart'),
    orElse: () => throw StateError('xb_network_test_page 库未找到'),
  ) as Map;
  final expr = "() { "
      "XBDioConfig.init(baseUrl: 'https://postman-echo.com', connectTimeout: 10, receiveTimeout: 10, sendTimeout: 10, force: true); "
      "XBDioConfig.dio.interceptors.removeWhere((e) => e is XBUmeDioInterceptor); "
      "XBDioConfig.dio.interceptors.add(XBUmeDioInterceptor()); "
      "XBHttp.get<Map<String,dynamic>>('/get', queryParams: {'source': 'probe', 'ts': 1}); "
      "return XBHttp.post<Map<String,dynamic>>('/post', bodyParams: {'action': 'probe_post', 'k': 'v'}); "
      "}";
  final r = await _rpc(ws, 'evaluate', {
    'isolateId': isoId,
    'targetId': lib['id'],
    'expression': expr,
  });
  print('evaluate 结果: ${jsonEncode(r).substring(0, 500 < jsonEncode(r).length ? 500 : jsonEncode(r).length)}');
  await ws.close();
  exit(0);
}
