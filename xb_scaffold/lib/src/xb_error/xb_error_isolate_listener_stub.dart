import 'dart:async';

typedef XBIsolateErrorHandler = FutureOr<void> Function(
  Object error,
  StackTrace stackTrace,
);

void addXBIsolateErrorListener(XBIsolateErrorHandler handler) {}
