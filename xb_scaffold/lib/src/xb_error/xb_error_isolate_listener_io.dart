import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

typedef XBIsolateErrorHandler = FutureOr<void> Function(
  Object error,
  StackTrace stackTrace,
);

RawReceivePort? _isolateErrorPort;

void addXBIsolateErrorListener(XBIsolateErrorHandler handler) {
  _isolateErrorPort ??= RawReceivePort((dynamic pair) async {
    try {
      final list = pair as List<dynamic>;
      final error = list.isNotEmpty ? list[0] : 'Unknown isolate error';
      final stack = list.length > 1
          ? StackTrace.fromString(list[1].toString())
          : StackTrace.current;
      await handler(error, stack);
    } catch (e, s) {
      debugPrint('XBErrorHandler isolate parse error: $e');
      debugPrint('$s');
    }
  });

  Isolate.current.addErrorListener(_isolateErrorPort!.sendPort);
}
