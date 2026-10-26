import 'dart:async';
import 'dart:convert';
import 'dart:io';

late WebSocket ws;
final pending = <String, Completer<Object?>>{};
var seq = 0;

Future<Map<String, dynamic>> rpc(String method,
    [Map<String, Object?>? params]) {
  final id = 'p${seq++}';
  final c = Completer<Object?>();
  pending[id] = c;
  ws.add(jsonEncode(<String, Object?>{
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    if (params != null) 'params': params,
  }));
  return c.future
      .timeout(const Duration(seconds: 30))
      .then((v) => (v as Map).cast<String, dynamic>());
}

void main() async {
  ws = await WebSocket.connect('ws://127.0.0.1:58044/ws');
  ws.listen((m) {
    if (m is! String) return;
    final d = jsonDecode(m) as Map;
    final id = d['id']?.toString();
    final c = id == null ? null : pending.remove(id);
    if (c == null) return;
    if (d['error'] != null) {
      c.completeError(d['error']);
    } else {
      c.complete(d['result']);
    }
  });
  try {
    final vm = await rpc('getVM');
    print('VM version=${vm['version']} name=${vm['name']}');
    final isolates = (vm['isolates'] as List).cast<Map>();
    for (final iso in isolates) {
      print('isolate id=${iso['id']} name=${iso['name']}');
    }
    final isoId = isolates.first['id'];
    final isolate = await rpc('getIsolate', <String, Object?>{'isolateId': isoId});
    final libs = (isolate['libraries'] as List).cast<Map>();
    final nav = libs
        .where((l) => l['uri'] == 'package:flutter/src/widgets/navigator.dart')
        .toList();
    print('libraries=${libs.length} navigator=${nav.isEmpty ? 'MISSING' : nav.first['id']}');
    if (nav.isEmpty) return;

    final exprs = <String, String>{
      'basic': '1 + 1',
      'renderRoot': 'WidgetsBinding.instance.renderViewElement == null',
      'iife': "(() { final root = WidgetsBinding.instance.renderViewElement; "
          "if (root == null) return 'NO_ROOT'; return 'ROOT_OK'; })()",
      'walk': "(() { final root = WidgetsBinding.instance.renderViewElement; "
          "if (root == null) return 'NO_ROOT'; "
          "final navigators = <NavigatorState>[]; "
          "void walk(Element e) { final w = e.widget; "
          "if (w is Navigator && e is StatefulElement && e.state is NavigatorState) { navigators.add(e.state as NavigatorState); } "
          "e.visitChildren(walk); } "
          "root.visitChildren(walk); "
          "return 'NAVS=' + navigators.length.toString(); })()",
      'history': "(() { final root = WidgetsBinding.instance.renderViewElement; "
          "if (root == null) return 'NO_ROOT'; "
          "final navigators = <NavigatorState>[]; "
          "void walk(Element e) { final w = e.widget; "
          "if (w is Navigator && e is StatefulElement && e.state is NavigatorState) { navigators.add(e.state as NavigatorState); } "
          "e.visitChildren(walk); } "
          "root.visitChildren(walk); "
          "final sb = StringBuffer()..write(navigators.length); "
          "for (var i = 0; i < navigators.length; i++) { "
          "for (final entry in navigators[i]._history) { "
          "sb.write('|'); sb.write(entry.route.runtimeType.toString()); } } "
          "return sb.toString(); })()",
    };
    for (final e in exprs.entries) {
      try {
        final r = await rpc('evaluate', <String, Object?>{
          'isolateId': isoId,
          'targetId': nav.first['id'],
          'expression': e.value,
        });
        final brief = <String, Object?>{
          'type': r['type'],
          'kind': r['kind'],
          'value': r['valueAsString'],
          'message': r['message'],
          'class': (r['class'] as Map?)?['name'],
        };
        print('[${e.key}] OK $brief');
      } catch (err) {
        print('[${e.key}] ERROR ${jsonEncode(err)}');
      }
    }
  } finally {
    await ws.close();
  }
}
