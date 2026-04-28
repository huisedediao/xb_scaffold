import 'package:xb_scaffold/xb_scaffold.dart';

Future<void> triggerIsolateError() async {
  await XBErrorHandler.handle(
    UnsupportedError('isolate error test is not supported on web'),
    StackTrace.current,
  );
}
