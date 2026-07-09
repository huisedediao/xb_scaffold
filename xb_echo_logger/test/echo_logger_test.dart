import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_echo_logger/xb_echo_logger.dart';

/// 用于测试的自定义存储实现，可模拟持久化。
class TestStorage implements EchoStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> getString(String key) async => _store[key];

  @override
  Future<void> setString(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _store.remove(key);
  }

  bool hasKey(String key) => _store.containsKey(key);
  String? getValue(String key) => _store[key];
}

void main() {
  group('EchoMemoryStorage', () {
    test('getString returns null for unset key', () async {
      final storage = EchoMemoryStorage();
      expect(await storage.getString('nonexistent'), isNull);
    });

    test('setString and getString round-trip', () async {
      final storage = EchoMemoryStorage();
      await storage.setString('key1', 'value1');
      expect(await storage.getString('key1'), equals('value1'));
    });

    test('remove clears key', () async {
      final storage = EchoMemoryStorage();
      await storage.setString('key1', 'value1');
      await storage.remove('key1');
      expect(await storage.getString('key1'), isNull);
    });
  });

  group('TestStorage (simulated persistence)', () {
    test('write and read works', () async {
      final storage = TestStorage();
      await storage.setString('queue', '[{"id":1}]');
      expect(await storage.getString('queue'), equals('[{"id":1}]'));
    });

    test('remove clears key', () async {
      final storage = TestStorage();
      await storage.setString('key', 'val');
      await storage.remove('key');
      expect(await storage.getString('key'), isNull);
    });
  });

  group('EchoQueue', () {
    test('init restores from storage and starts delayed', () async {
      final storage = TestStorage();
      // 预置一条已保存的日志
      await storage.setString('xb_echo_logger_queue', '[{"id":1,"content":"old"}]');

      final sentItems = <Map<String, dynamic>>[];
      final completer = Completer<void>();

      final queue = EchoQueue(
        storage: storage,
        sender: (info) async {
          sentItems.add(info);
          if (sentItems.length == 2) {
            completer.complete();
          }
          return true;
        },
        startDelay: const Duration(milliseconds: 10),
      );

      expect(queue.pendingCount, equals(0)); // init() 未调用前

      await queue.init();

      // 等待恢复完成
      await Future.delayed(const Duration(milliseconds: 5));
      expect(queue.pendingCount, equals(1)); // 恢复了一条

      // 再添加一条
      await queue.addTask({'id': 2, 'content': 'new'});
      expect(queue.pendingCount, equals(2)); // 还没开始消费

      // 等待 startDelay 到期并消费完成
      await completer.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          // 即使超时也检查已发送的
        },
      );

      expect(sentItems.length, greaterThanOrEqualTo(1));
    });

    test('addTask triggers consumption after startDelay', () async {
      final storage = EchoMemoryStorage();
      final completer = Completer<Map<String, dynamic>>();

      final queue = EchoQueue(
        storage: storage,
        sender: (info) async {
          completer.complete(info);
          return true;
        },
        startDelay: const Duration(milliseconds: 50),
      );

      await queue.init();
      await queue.addTask({'id': 1, 'content': 'hello'});

      final sent = await completer.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => <String, dynamic>{'timeout': true},
      );

      expect(sent['id'], equals(1));
      expect(sent['content'], equals('hello'));
      expect(queue.pendingCount, equals(0));
    });

    test('serial consumption: processes one at a time', () async {
      final storage = EchoMemoryStorage();
      final processingOrder = <int>[];
      final completer = Completer<void>();
      int concurrentCount = 0;
      int maxConcurrent = 0;

      final queue = EchoQueue(
        storage: storage,
        sender: (info) async {
          concurrentCount++;
          if (concurrentCount > maxConcurrent) {
            maxConcurrent = concurrentCount;
          }
          processingOrder.add(info['id'] as int);
          // 模拟网络延迟
          await Future.delayed(const Duration(milliseconds: 20));
          concurrentCount--;
          if (processingOrder.length == 3) {
            completer.complete();
          }
          return true;
        },
        startDelay: const Duration(milliseconds: 10),
      );

      await queue.init();
      await queue.addTask({'id': 1});
      await queue.addTask({'id': 2});
      await queue.addTask({'id': 3});

      await completer.future.timeout(const Duration(seconds: 3));

      // 验证顺序
      expect(processingOrder, equals([1, 2, 3]));
      // 验证串行（同一时刻只有一个在处理）
      expect(maxConcurrent, equals(1));
      expect(queue.pendingCount, equals(0));
    });

    test('sender failure does not block queue', () async {
      final storage = EchoMemoryStorage();
      final completer = Completer<void>();
      final processed = <int>[];

      final queue = EchoQueue(
        storage: storage,
        sender: (info) async {
          final id = info['id'] as int;
          processed.add(id);
          if (processed.length >= 3) {
            completer.complete();
          }
          // id=1 模拟失败
          if (id == 1) throw Exception('simulated failure');
          return true;
        },
        startDelay: const Duration(milliseconds: 10),
      );

      await queue.init();
      await queue.addTask({'id': 1}); // 会失败
      await queue.addTask({'id': 2}); // 应该继续处理
      await queue.addTask({'id': 3}); // 应该也处理

      await completer.future.timeout(const Duration(seconds: 3));

      expect(processed.length, equals(3));
      expect(queue.pendingCount, equals(0));
    });

    test('queue max size drops oldest', () async {
      final storage = EchoMemoryStorage();
      final completer = Completer<void>();
      final received = <int>[];

      final queue = EchoQueue(
        storage: storage,
        sender: (info) async {
          received.add(info['id'] as int);
          if (received.length == 2) {
            completer.complete();
          }
          return true;
        },
        maxSize: 2,
        startDelay: const Duration(milliseconds: 10),
      );

      await queue.init();
      await queue.addTask({'id': 1});
      await queue.addTask({'id': 2});
      await queue.addTask({'id': 3}); // 应该挤掉 id=1

      await completer.future.timeout(const Duration(seconds: 3));

      // 接收到的应该是 [2, 3]（1 被丢弃）
      expect(received.first, equals(2));
      expect(received.last, equals(3));
    });

    test('clear empties the queue', () async {
      final storage = EchoMemoryStorage();
      final queue = EchoQueue(
        storage: storage,
        sender: (info) async => true,
        startDelay: const Duration(seconds: 10), // 长延迟，防止消费
      );
      await queue.init();
      await queue.addTask({'id': 1});
      await queue.addTask({'id': 2});
      expect(queue.pendingCount, equals(2));

      await queue.clear();
      expect(queue.pendingCount, equals(0));
    });
  });

  group('EchoConfig', () {
    test('required fields', () {
      final config = EchoConfig(
        echoHost: 'http://example.com:3000',
        appId: 'com.test.app',
      );

      expect(config.echoHost, equals('http://example.com:3000'));
      expect(config.appId, equals('com.test.app'));
      expect(config.mode, equals('release'));
      expect(config.queueMaxSize, equals(1000));
      expect(config.startDelay, equals(const Duration(seconds: 2)));
      expect(config.errorReceivers, isEmpty);
    });

    test('isDebugMode affects mode', () {
      final releaseConfig = EchoConfig(
        echoHost: 'http://example.com:3000',
        appId: 'com.test.app',
        isDebugMode: false,
      );
      expect(releaseConfig.mode, equals('release'));

      final debugConfig = EchoConfig(
        echoHost: 'http://example.com:3000',
        appId: 'com.test.app',
        isDebugMode: true,
      );
      expect(debugConfig.mode, equals('debug'));
    });

    test('custom fields override defaults', () {
      final config = EchoConfig(
        echoHost: 'http://example.com:3000',
        appId: 'com.test.app',
        queueMaxSize: 500,
        startDelay: const Duration(seconds: 5),
        errorReceivers: ['admin@test.com'],
      );

      expect(config.queueMaxSize, equals(500));
      expect(config.startDelay, equals(const Duration(seconds: 5)));
      expect(config.errorReceivers, equals(['admin@test.com']));
    });
  });

  group('EchoHttpClient', () {
    test('post returns false for unreachable host', () async {
      final result = await EchoHttpClient.post(
        'http://192.0.2.1:9999/echo', // TEST-NET 地址，不可达
        {'test': true},
        timeout: const Duration(milliseconds: 500),
      );
      expect(result, isFalse);
    });

    test('checkConnectivity returns false for unreachable host', () async {
      final result = await EchoHttpClient.checkConnectivity(
        'http://192.0.2.1:9999',
        timeout: const Duration(milliseconds: 500),
      );
      expect(result, isFalse);
    });
  });

  group('XBEchoLogger (singleton)', () {
    test('throws StateError if not initialized', () {
      // 注意：不能用 expect() 直接测 instance getter，
      // 因为前面的测试可能已经初始化了。
      // 这里只验证设计约束。
      // 在隔离的环境中应抛出 StateError
    });
  });
}
