import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final ws = await WebSocket.connect('ws://127.0.0.1:51680/ws');
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

  // 列出所有 XB* Element 的类型与 bounds（看 show 按钮在哪）
  final expr = "(() { final root = WidgetsBinding.instance.renderViewElement; "
      "if (root == null) return 'NO_ROOT'; "
      "final out = <String>[]; "
      "void walk(Element e) { "
      "final n = e.widget.runtimeType.toString(); "
      "if (n.startsWith('XB')) { "
      "final rb = e.renderObject; "
      "String r = 'none'; "
      "if (rb is RenderBox && rb.attached && rb.hasSize) { "
      "final p = rb.localToGlobal(Offset.zero); "
      "r = p.dx.toStringAsFixed(0) + ',' + p.dy.toStringAsFixed(0) + ' ' + rb.size.width.toStringAsFixed(0) + 'x' + rb.size.height.toStringAsFixed(0); } "
      "out.add(n + '@' + r); } "
      "e.visitChildren(walk); } "
      "walk(root); "
      "return out.join(' | '); })()";
  print(await evalOn(expr));
  await ws.close();
}
