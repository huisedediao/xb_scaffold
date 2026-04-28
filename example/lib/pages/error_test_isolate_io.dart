import 'dart:isolate';

import 'package:xb_scaffold/xb_scaffold.dart';

Future<void> triggerIsolateError() async {
  late final RawReceivePort errorPort;
  errorPort = RawReceivePort((dynamic pair) async {
    try {
      final list = pair as List<dynamic>;
      final error = list.isNotEmpty ? list[0] : 'Unknown isolate error';
      final stack = list.length > 1
          ? StackTrace.fromString(list[1].toString())
          : StackTrace.current;
      await XBErrorHandler.handle(error, stack);
    } catch (e, s) {
      await XBErrorHandler.handle(e, s);
    } finally {
      errorPort.close();
    }
  });

  await Isolate.spawn(
    _isolateEntry,
    'test',
    onError: errorPort.sendPort,
    errorsAreFatal: true,
  );
}

void _isolateEntry(String msg) {
  throw Exception('Isolate error: $msg');
}
