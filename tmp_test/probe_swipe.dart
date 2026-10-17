// 临时探针：验证合成 swipe 滚动失效的根因。
// 1) 读 Scrollable offset → 2) 单 eval 内同步派发完整 down+8move+up → 3) 再读 offset。
// 用法: dart probe_swipe.dart <vm_service_port>
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
    if (msg['event'] != null) return;
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

  final vm = await call('getVM');
  final isolateId = (vm['result']['isolates'] as List).first['id'];
  final iso = await call('getIsolate', {'isolateId': isolateId});
  final libs = (iso['result']['libraries'] as List?) ?? const [];
  String? libId(String match) {
    for (final l in libs) {
      if ('${l['uri']}'.contains(match)) return (l as Map)['id'] as String?;
    }
    return null;
  }

  Future<String> eval(String libMatch, String expr) async {
    final lib = libId(libMatch);
    if (lib == null) return 'LIB_NOT_FOUND:$libMatch';
    final r = await call('evaluate', {'isolateId': isolateId, 'targetId': lib, 'expression': expr});
    if (r['error'] != null) return 'ERR:${r['error']}';
    return (r['result']['valueAsString'] ?? r['result'].toString()).toString();
  }

  const offsetExpr = r'''
"OFFSET:" + (() {
  final root = WidgetsBinding.instance.renderViewElement;
  if (root == null) return 'NO_ROOT';
  final out = <double>[];
  void visit(Element e) {
    if (e.widget.runtimeType.toString() == 'ScrollableState') {
      try { out.add((e as dynamic).position.pixels as double); } catch (_) {}
    }
    e.visitChildren(visit);
  }
  visit(root);
  return out.join(',');
})()''';

  print('before: ${await eval('scrollable.dart', offsetExpr)}');
  print('resamplingEnabled: ${await eval('gestures/binding.dart', 'GestureBinding.instance.resamplingEnabled.toString()')}');

  final swipe = r'''
(() {
  final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
  Offset px(double x, double y) => Offset(x / d, y / d);
  final ts = DateTime.now().microsecondsSinceEpoch;
  GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: 998001, position: px(400, 450), timeStamp: Duration(microseconds: ts)));
  for (var i = 1; i <= 8; i++) {
    GestureBinding.instance.handlePointerEvent(PointerMoveEvent(pointer: 998001, position: px(400, 450 - i * 41), timeStamp: Duration(microseconds: ts + i * 50000)));
  }
  GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: 998001, position: px(400, 122), timeStamp: Duration(microseconds: ts + 450000)));
  return 'OK';
})()''';
  print('single-eval swipe: ${await eval('gestures/binding.dart', swipe)}');
  await Future<void>.delayed(const Duration(milliseconds: 800));
  print('after: ${await eval('scrollable.dart', offsetExpr)}');
  exit(0);
}
