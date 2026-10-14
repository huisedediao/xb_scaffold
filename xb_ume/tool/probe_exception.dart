import 'dart:async';
import 'dart:convert';
import 'dart:io';

// P3 探针：验证 VM service 未捕获异常事件在真机会话的真实字段格式。
// 用法: dart run tool/probe_exception.dart ws://127.0.0.1:PORT/ws
// 流程: 连 ws → getVM → streamListen('Isolate') → 在 dart:io 库上下文
// eval 一个 microtask 内 throw 的表达式 → 监听 5s 打印事件全字段。
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/probe_exception.dart ws://127.0.0.1:PORT/ws');
    exit(2);
  }
  final addr = args[0]
      .replaceFirst('ws://', '')
      .replaceFirst(RegExp(r'/ws/?$'), '');
  final ws = await WebSocket.connect('ws://$addr/ws');
  var seq = 0;
  final pending = <String, Completer<Map<String, Object?>>>{};

  ws.listen((dynamic d) {
    if (d is! String) return;
    final m = jsonDecode(d) as Map<String, Object?>;
    if (m['method'] == 'streamNotify') {
      final params = (m['params'] ?? <String, Object?>{}) as Map<String, Object?>;
      print('NOTIFY stream=${params['streamId']}');
      final ev = (params['event'] ?? <String, Object?>{}) as Map<String, Object?>;
      print('  kind=${ev['kind']}');
      for (final k in ev.keys) {
        final s = jsonEncode(ev[k]);
        print('  $k=${s.length > 500 ? s.substring(0, 500) : s}');
      }
      return;
    }
    final id = m['id'];
    if (id != null && pending[id.toString()] != null) {
      pending[id.toString()]!.complete(m);
    }
  });

  Future<Map<String, Object?>> rpc(
    String method, [
    Map<String, Object?>? params,
  ]) {
    final id = 'p${seq++}';
    final c = Completer<Map<String, Object?>>();
    pending[id] = c;
    ws.add(jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }));
    return c.future.timeout(const Duration(seconds: 15));
  }

  final vm = await rpc('getVM');
  final isolates = ((vm['result'] as Map)['isolates'] as List).cast<Map>();
  final iso = isolates.first['id'].toString();
  print('isolate=$iso');

  final sl = await rpc('streamListen', <String, Object?>{'streamId': 'Isolate'});
  print('streamListen(Isolate): ${sl.containsKey('error') ? 'ERR ${jsonEncode(sl['error'])}' : 'OK'}');

  // 在 dart:io 库上下文 eval：microtask 内 throw → isolate 未捕获异常。
  final isoInfo = await rpc('getIsolate', <String, Object?>{'isolateId': iso});
  final libs =
      (((isoInfo['result'] as Map)['libraries'] ?? <Object?>[]) as List)
          .cast<Map>();
  final asyncLib = libs
      .firstWhere((l) => (l['uri'] ?? '').toString() == 'dart:async')['id']
      .toString();
  print('asyncLib=$asyncLib');
  final ev = await rpc('evaluate', <String, Object?>{
    'isolateId': iso,
    'targetId': asyncLib,
    'expression':
        "scheduleMicrotask(() { throw StateError('xbume-probe-uncaught'); }); 'scheduled'",
  });
  print('evaluate: ${jsonEncode(ev).length > 800 ? jsonEncode(ev).substring(0, 800) : jsonEncode(ev)}');

  await Future<void>.delayed(const Duration(seconds: 5));
  await ws.close();
  exit(0);
}
