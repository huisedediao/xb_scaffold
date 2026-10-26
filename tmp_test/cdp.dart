import 'dart:async';
import 'dart:convert';
import 'dart:io';

// 用法：
//   dart cdp.dart <wsUrl> eval <expression>
//   dart cdp.dart <wsUrl> shot <pngPath>
// 通过 Chrome DevTools Protocol 在页面执行 JS 或截图（不依赖窗口焦点）。
Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: cdp.dart <wsUrl> eval <expr> | shot <png>');
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
    ws.add(jsonEncode(<String, Object?>{'id': id, 'method': method, 'params': params}));
    return c.future;
  }

  try {
    if (args[1] == 'eval') {
      final r = await call('Runtime.evaluate', <String, Object?>{
        'expression': args[2],
        'returnByValue': true,
        'awaitPromise': true,
      });
      final result = r['result'] as Map<String, Object?>?;
      final ex = result?['exceptionDetails'];
      if (ex != null) {
        stderr.writeln('JS_ERROR: ${jsonEncode(ex)}');
        exit(1);
      }
      final value = (result?['result'] as Map<String, Object?>?)?['value'];
      print(value is String ? value : jsonEncode(value));
    } else if (args[1] == 'shot') {
      final r = await call('Page.captureScreenshot', <String, Object?>{
        'format': 'png',
        'captureBeyondViewport': false,
      });
      final data = ((r['result'] as Map<String, Object?>?)?['data']) as String?;
      if (data == null) {
        stderr.writeln('SHOT_FAILED: ${jsonEncode(r)}');
        exit(1);
      }
      File(args[2]).writeAsBytesSync(base64Decode(data));
      print('saved ${args[2]}');
    } else {
      stderr.writeln('unknown mode ${args[1]}');
      exit(2);
    }
  } finally {
    await ws.close();
  }
  exit(0);
}
