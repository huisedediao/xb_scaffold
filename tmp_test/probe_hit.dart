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
  final libs =
      (((await call('getIsolate', {'isolateId': iso}))['result'] as Map)['libraries'] as List).cast<Map>();
  String libId(String match) =>
      libs.firstWhere((l) => (l['uri'] ?? '').toString().contains(match))['id'] as String;
  final binding = libId('widgets/binding.dart');
  Future<String> evalOn(String expr) async {
    final re = await call('evaluate', {'isolateId': iso, 'targetId': binding, 'expression': expr});
    if (re['error'] != null) return 'ERR: ' + (re['error']['message'] ?? '').toString();
    return ((re['result'] as Map)['valueAsString'] ?? '').toString();
  }

  // 针对性探测：目标类型是否在树上 + overlay 层 XB 组件计数（避免长串截断）
  final target = args.length > 1 ? args[1] : 'XBDialogInput';
  final expr = "(() { final root = WidgetsBinding.instance.renderViewElement; "
      "if (root == null) return 'NO_ROOT'; "
      "var hit = 0; var xbCount = 0; var total = 0; "
      "final xbTypes = <String>{}; "
      "final se = <Element>[root]; "
      "while (se.isNotEmpty) { final e = se.removeLast(); total++; "
      "final n = e.widget.runtimeType.toString(); "
      "if (n == '$target') hit++; "
      "if (n.startsWith('XB')) { xbCount++; if (xbTypes.length < 30) xbTypes.add(n); } "
      "final kids = <Element>[]; e.visitChildren(kids.add); "
      "for (var i = kids.length - 1; i >= 0; i--) se.add(kids[i]); } "
      "return 'hit=' + hit.toString() + ' xb=' + xbCount.toString() + ' total=' + total.toString() + ' :: ' + xbTypes.join(','); })()";
  print(await evalOn(expr));
  await ws.close();
}
