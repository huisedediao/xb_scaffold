// 结构化异常缓冲（XBUmeExceptionItem + controller.addException）单测：
// 入库字段、10 秒内同签名合并、容量淘汰、清空、JSON 往返、FlutterError 钩子。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_ume/xb_ume.dart';

/// 不落盘的内存持久化（单测不关心快照）。
class _MemoryPersistence implements XBUmePersistence {
  @override
  Future<Map<String, dynamic>?> load() async => null;

  @override
  Future<void> save(Map<String, dynamic> json) async {}
}

XBUmeController _controller({int maxExceptionRecords = 200}) {
  return XBUmeController(
    config: XBUmeConfig(
      persistenceEnabled: false,
      maxExceptionRecords: maxExceptionRecords,
    ),
    persistence: _MemoryPersistence(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('addException 保留类型/摘要/库/上下文/首帧', () {
    final c = _controller();
    c.addException(
      error: StateError('boom'),
      kind: XBUmeExceptionKind.flutter,
      message: "Bad state: boom",
      stack: StackTrace.fromString('#0      main (file:///app.dart:10:3)\n'
          '#1      run (file:///main.dart:1:1)'),
      library: 'widgets library',
      context: 'While building ListView',
    );

    final item = c.exceptions.single;
    expect(item.kind, XBUmeExceptionKind.flutter);
    expect(item.type, 'StateError');
    expect(item.message, 'Bad state: boom');
    expect(item.library, 'widgets library');
    expect(item.context, 'While building ListView');
    expect(item.stack, contains('#0'));
    expect(item.count, 1);
    expect(item.signature, contains('StateError'));
    expect(item.signature, contains('#0'), reason: '首帧要进签名，才能区分同文案不同位置');
    c.dispose();
  });

  test('10 秒内同签名重复只累加 count，不新增条目', () {
    final c = _controller();
    final st = StackTrace.fromString('#0      main (file:///app.dart:10:3)');
    for (var i = 0; i < 3; i++) {
      c.addException(error: StateError('boom'), stack: st);
    }
    expect(c.exceptions, hasLength(1));
    expect(c.exceptions.single.count, 3);
    c.dispose();
  });

  test('不同异常分别入库', () {
    final c = _controller();
    final st = StackTrace.fromString('#0      main (file:///app.dart:10:3)');
    c.addException(error: StateError('a'), stack: st);
    c.addException(error: StateError('b'), stack: st);
    c.addException(error: ArgumentError('a'), stack: st);
    expect(c.exceptions.map((e) => e.type).toList(),
        <String>['StateError', 'StateError', 'ArgumentError']);
    c.dispose();
  });

  test('超过 maxExceptionRecords 淘汰最旧', () {
    final c = _controller(maxExceptionRecords: 3);
    final st = StackTrace.fromString('#0      main (file:///app.dart:10:3)');
    for (var i = 1; i <= 5; i++) {
      c.addException(error: StateError('m$i'), stack: st);
    }
    expect(c.exceptions, hasLength(3));
    expect(c.exceptions.map((e) => e.message).toList(),
        <String>['Bad state: m3', 'Bad state: m4', 'Bad state: m5']);
    c.dispose();
  });

  test('clearExceptions 清空缓冲', () {
    final c = _controller();
    c.addException(error: StateError('boom'));
    expect(c.exceptions, isNotEmpty);
    c.clearExceptions();
    expect(c.exceptions, isEmpty);
    c.dispose();
  });

  test('XBUmeExceptionItem JSON 往返', () {
    final item = XBUmeExceptionItem(
      id: 'exc-1',
      time: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      kind: XBUmeExceptionKind.platform,
      type: 'Exception',
      message: 'Network unreachable',
      signature: 'Exception|Network unreachable|#0 main',
      stack: '#0 main (file:///app.dart:1:1)',
      library: 'platform',
      context: 'async',
      count: 4,
    );
    final back = XBUmeExceptionItem.fromJson(item.toJson());
    expect(back.id, item.id);
    expect(back.time, item.time);
    expect(back.kind, item.kind);
    expect(back.type, item.type);
    expect(back.message, item.message);
    expect(back.stack, item.stack);
    expect(back.library, item.library);
    expect(back.context, item.context);
    expect(back.count, 4);
  });

  test('FlutterError.onError 钩子写入异常缓冲', () {
    final origin = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {};
    final binding = XBUmeBinding.ensureInitialized(
      config: const XBUmeConfig(persistenceEnabled: false),
    );
    try {
      FlutterError.onError!(FlutterErrorDetails(
        exception: StateError('hook-boom'),
        stack: StackTrace.fromString('#0      main (file:///app.dart:9:9)'),
        library: 'widgets library',
        context: DiagnosticsNode.message('While building TestWidget'),
      ));
      final item = binding.controller.exceptions.single;
      expect(item.kind, XBUmeExceptionKind.flutter);
      expect(item.type, 'StateError');
      expect(item.message, contains('hook-boom'));
      expect(item.library, 'widgets library');
      expect(item.context, contains('While building TestWidget'));

      // 日志通道仍保留（老行为不变），异常只是多存一份结构化的。
      final log = binding.controller.logs
          .firstWhere((e) => e.tag == 'FlutterError' && e.level == XBUmeLogLevel.error);
      expect(log.message, contains('hook-boom'));
    } finally {
      binding.dispose();
      FlutterError.onError = origin;
    }
  });
}
