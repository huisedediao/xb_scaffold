// 崩溃取证脚本：一次性连接 VM，导出路由历史（含 phase + 非 idle 触发堆栈）。
// 用法: dart run tmp_test/probe_routes_dump.dart <wsUrl> [条数，默认最后12条]
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
      orElse: () => (vm['isolates'] as List).cast<Map>().first);
  final isoId = iso['id'] as String;
  final isor = await _rpc(ws, 'getIsolate', {'isolateId': isoId});
  final lib = (isor['libraries'] as List).firstWhere(
    (l) => (l as Map)['uri'].toString().contains('core/xb_ume.dart'),
  ) as Map;
  final targetId = lib['id'];

  Future<String> eval(String expr) async {
    final r = await _rpc(ws, 'evaluate',
        {'isolateId': isoId, 'targetId': targetId, 'expression': expr});
    return (r['value'] as String?) ?? jsonEncode(r);
  }

  final items = <Map<String, Object?>>[];
  // 1) 崩溃取证：拉最后 N 条路由事件（每条 ≤120 字符，避开 VM 128 截断）
  final count = args.length > 1 ? int.parse(args[1]) : 12;
  final nStr = await eval('XBUme.controller.routes.length.toString()');
  final total = int.tryParse(nStr) ?? 0;
  final start = total > count ? total - count : 0;
  for (var i = start; i < total; i++) {
    final s = await eval('(() { final r = XBUme.controller.routes[$i]; '
        "return r.time.toIso8601String() + '|' + r.action.name + '|' + r.routeName + '|' + (r.previousRouteName ?? '') + '|' + r.phase; })()");
    final p = s.split('|');
    items.add({
      'time': p.isNotEmpty ? p[0] : '',
      'action': p.length > 1 ? p[1] : '',
      'routeName': p.length > 2 ? p[2] : '',
      'prev': p.length > 3 ? p[3] : '',
      'phase': p.length > 4 ? p[4] : '',
    });
  }
  // 2) 全部非 idle 事件的堆栈（分块拉取）
  final stackIdxStr = await eval(
      '(() { final out = <int>[]; for (var i = 0; i < XBUme.controller.routes.length; i++) { final r = XBUme.controller.routes[i]; if (r.phase != \'idle\' && r.stack != null) out.add(i); } return out.join(\',\'); })()');
  final stackIdxs = stackIdxStr.split(',').where((e) => e.isNotEmpty).map(int.parse).toList();
  final stacks = <int, String>{};
  for (final i in stackIdxs) {
    final lenStr = await eval(
        'XBUme.controller.routes[$i].stack!.length.toString()');
    final len = int.parse(lenStr);
    final buf = StringBuffer();
    for (var st = 0; st < len; st += 100) {
      buf.write(await eval(
          'XBUme.controller.routes[$i].stack!.substring($st, ${st + 100 > len ? len : st + 100})'));
    }
    stacks[i] = buf.toString();
  }
  final out = {
    'dumpedAt': DateTime.now().toIso8601String(),
    'total': total,
    'items': items,
    'stacks': stacks.map((k, v) => MapEntry(k.toString(), v)),
  };
  final path = 'tmp_test/routes_dump_${DateTime.now().millisecondsSinceEpoch}.json';
  File(path).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
  stdout.writeln('已导出 $total 条中最后 ${items.length} 条（含 ${stacks.length} 个堆栈）→ $path');
  await ws.close();
  exit(0);
}
