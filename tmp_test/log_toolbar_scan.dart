import 'dart:async';
import 'dart:convert';
import 'dart:io';

// 扫描日志页工具栏在不同窗口宽度下的布局：元素位置、是否出视口、是否被遮挡。
// 用法：dart log_toolbar_scan.dart <cdpWsUrl>
Future<void> main(List<String> args) async {
  if (args.length < 1) {
    stderr.writeln('usage: log_toolbar_scan.dart <cdpWsUrl>');
    exit(2);
  }
  final ws = await WebSocket.connect(args[0]);
  var seq = 0;
  final pending = <int, Completer<Map<String, Object?>>>{};
  ws.listen((raw) {
    final m = jsonDecode(raw as String) as Map<String, Object?>;
    final id = m['id'];
    if (id is int) pending.remove(id)?.complete(m);
  });
  Future<Map<String, Object?>> call(String method,
      [Map<String, Object?> params = const {}]) {
    final id = ++seq;
    final c = Completer<Map<String, Object?>>();
    pending[id] = c;
    ws.add(jsonEncode(<String, Object?>{
      'id': id,
      'method': method,
      'params': params,
    }));
    return c.future;
  }

  Future<Object?> eval(String expr) async {
    final r = await call('Runtime.evaluate', <String, Object?>{
      'expression': expr,
      'returnByValue': true,
      'awaitPromise': true,
    });
    final result = r['result'] as Map<String, Object?>?;
    final ex = result?['exceptionDetails'];
    if (ex != null) {
      stderr.writeln('JS_ERROR: ${jsonEncode(ex)}');
      return null;
    }
    return (result?['result'] as Map<String, Object?>?)?['value'];
  }

  const probe = r'''
(function(){
  document.querySelector('.tab[data-tab=logs]').click();
  var row = document.querySelector('#page-logs .row');
  if (!row) return JSON.stringify({err:'no row'});
  var es = [].map.call(row.children, function(e){
    var r = e.getBoundingClientRect();
    var cx = Math.round(r.x + r.width/2), cy = Math.round(r.y + Math.min(r.height/2, 8));
    var top = document.elementFromPoint(cx, cy);
    var label = (e.id || e.className || e.textContent || '').toString().replace(/\s+/g,'').slice(0,10);
    var covered = !(top === e || e.contains(top));
    return {t:label, x:Math.round(r.x), w:Math.round(r.width),
            right:Math.round(r.right), y:Math.round(r.y), h:Math.round(r.height),
            out: r.right > innerWidth + 0.5 || r.x < -0.5, cov: covered,
            top: top ? ((top.id || top.className || top.tagName || '')+'').slice(0,12) : ''};
  });
  var mr = document.querySelector('main');
  return JSON.stringify({iw:innerWidth, rowH:Math.round(row.getBoundingClientRect().height),
    rowW:Math.round(row.getBoundingClientRect().width), rowSW:row.scrollWidth,
    mainSW:mr.scrollWidth, mainCW:mr.clientWidth, es:es});
})()
''';

  for (final w in const [800, 1000, 1100, 1200, 1280, 1366, 1440, 1600, 1800, 1920]) {
    await call('Emulation.setDeviceMetricsOverride', <String, Object?>{
      'width': w,
      'height': 900,
      'deviceScaleFactor': 1,
      'mobile': false,
    });
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final v = await eval(probe);
    print('W=$w :: $v');
  }
  await call('Emulation.clearDeviceMetricsOverride');
  await ws.close();
}
