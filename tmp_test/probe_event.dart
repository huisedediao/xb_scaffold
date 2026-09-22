// 临时探针：连接 VM service，订阅 Extension 流，
// 并通过 evaluate 在 App 内触发一次 XBUmeIdeJump 事件（模拟点击箭头）。
// 用法: dart probe_event.dart <vm_service_port>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final port = args[0];
  final ws = await WebSocket.connect('ws://127.0.0.1:$port/ws');
  var id = 0;
  final pending = <String, Completer<dynamic>>{};
  ws.listen((data) {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    if (msg['event'] != null) {
      print('EVENT_RAW: ${jsonEncode(msg['event'])}');
      return;
    }
    pending.remove(msg['id'])?.complete(msg);
  });
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?>? params,
  ]) {
    final cid = '${++id}';
    final c = Completer<Map<String, dynamic>>();
    pending[cid] = c;
    ws.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': cid,
      'method': method,
      if (params != null) 'params': params,
    }));
    return c.future;
  }

  final sub = await call('streamListen', {'streamId': 'Extension'});
  print('subscribe: ${sub['error'] ?? 'ok'}');
  final vm = await call('getVM');
  final isolateId = (vm['result']['isolates'] as List).first['id'];
  print('isolate: $isolateId');
  final iso = await call('getIsolate', {'isolateId': isolateId});
  final result = iso['result'] as Map<String, dynamic>;
  print('getIsolate keys: ${result.keys.toList()}');
  final libs = (result['libraries'] as List?) ?? const [];
  Map<String, dynamic>? lib;
  for (final l in libs) {
    if ('${l['uri']}'.contains('xb_ume_ide_jump')) {
      lib = l as Map<String, dynamic>;
    }
  }
  if (lib == null) {
    print('未找到 xb_ume_ide_jump 库，libraries: '
        '${libs.map((l) => l['uri']).take(30).toList()}');
    exit(1);
  }
  print('library: ${lib['id']} ${lib['uri']}');
  final eval = await call('evaluate', {
    'targetId': lib['id'],
    'expression':
        "developer.postEvent('xb_ume:openSource', "
        "{'file': 'package:xb_ume/lib/src/core/xb_ume_ide_jump.dart', "
        "'line': 42, 'column': 3})",
  });
  print('evaluate: ${jsonEncode(eval)}');
  await Future<void>.delayed(const Duration(seconds: 3));
  exit(0);
}
