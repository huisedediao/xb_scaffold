import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xb_echo_logger/xb_echo_logger.dart';

/// 用于测试的自定义存储实现。
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

  group('TestStorage', () {
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
      await storage.setString(
          'xb_echo_logger_queue', '[{"id":1,"content":"old"}]');

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

      expect(queue.pendingCount, equals(0));

      await queue.init();

      await Future.delayed(const Duration(milliseconds: 5));
      expect(queue.pendingCount, equals(1));

      await queue.addTask({'id': 2, 'content': 'new'});
      expect(queue.pendingCount, equals(2));

      await completer.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
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

      expect(processingOrder, equals([1, 2, 3]));
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
          if (id == 1) throw Exception('simulated failure');
          return true;
        },
        startDelay: const Duration(milliseconds: 10),
      );

      await queue.init();
      await queue.addTask({'id': 1});
      await queue.addTask({'id': 2});
      await queue.addTask({'id': 3});

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
      await queue.addTask({'id': 3});

      await completer.future.timeout(const Duration(seconds: 3));

      expect(received.first, equals(2));
      expect(received.last, equals(3));
    });

    test('clear empties the queue', () async {
      final storage = EchoMemoryStorage();
      final queue = EchoQueue(
        storage: storage,
        sender: (info) async => true,
        startDelay: const Duration(seconds: 10),
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

    test('provider callbacks are stored correctly', () {
      final config = EchoConfig(
        echoHost: 'http://example.com:3000',
        appId: 'com.test.app',
        userIdProvider: () => 'user-123',
        sidProvider: () => 'session-abc',
        deviceProvider: () => 'iPhone15',
        systemVersionProvider: () => '17.0',
        appVersionProvider: () => '1.0.0',
        environmentProvider: () => 'production',
      );

      expect(config.userIdProvider?.call(), equals('user-123'));
      expect(config.sidProvider?.call(), equals('session-abc'));
      expect(config.deviceProvider?.call(), equals('iPhone15'));
      expect(config.systemVersionProvider?.call(), equals('17.0'));
      expect(config.appVersionProvider?.call(), equals('1.0.0'));
      expect(config.environmentProvider?.call(), equals('production'));
    });
  });

  group('EchoHttpClient', () {
    test('post returns false for unreachable host', () async {
      final result = await EchoHttpClient.post(
        'http://192.0.2.1:9999/echo',
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

  group('XBEchoLogger', () {
    test(
      'full lifecycle: init, echo, err, pendingCount, checkConnectivity',
      () async {
        // sentItems 收集所有通过 customSender 发送的条目
        // 注意：customSender 同时被 echo（通过队列）和 err（直接）使用
        final allSentItems = <Map<String, dynamic>>[];

        await XBEchoLogger.init(
          config: EchoConfig(
            echoHost: 'http://localhost:3000',
            appId: 'com.example.integration',
            isDebugMode: true,
            startDelay: const Duration(milliseconds: 10),
            userIdProvider: () => 'user_001',
            sidProvider: () => 'sid_abc',
            deviceProvider: () => 'iPhone15',
            systemVersionProvider: () => '17.0',
            appVersionProvider: () => '2.0.0',
            errorReceivers: ['admin@test.com'],
            customSender: (info) async {
              allSentItems.add(info);
              return true;
            },
          ),
        );

        final instance = XBEchoLogger.instance;

        // 1. echo: 发送普通日志（通过队列异步消费）
        await instance.echo(content: '第一条日志');
        await instance.echo(
          content: '第二条日志',
          extraInfo: {'extra': 'value'},
        );

        // 等待队列消费完成（startDelay + 处理时间）
        await Future.delayed(const Duration(milliseconds: 200));

        // echo 的条目没有 receivers 字段，err 的有
        final echoItems =
            allSentItems.where((m) => !m.containsKey('receivers')).toList();
        expect(echoItems.length, greaterThanOrEqualTo(2));

        final firstLog = echoItems.first;
        expect(firstLog['content'], equals('第一条日志'));
        expect(firstLog['appid'], equals('com.example.integration'));
        expect(firstLog['mode'], equals('debug'));
        expect(firstLog['userId'], equals('user_001'));
        expect(firstLog['sid'], equals('sid_abc'));
        expect(firstLog['device'], equals('iPhone15'));
        expect(firstLog['systemVersion'], equals('17.0'));
        expect(firstLog['appVersion'], equals('2.0.0'));

        final secondLog = echoItems[1];
        expect(secondLog['extra'], equals('value'));

        // 2. err: 发送错误日志（去重测试）
        instance.err(content: '第一次错误');
        await Future.delayed(const Duration(milliseconds: 1200));

        instance.err(content: '第一次错误'); // 重复，应被去重，不发送
        await Future.delayed(const Duration(milliseconds: 200));

        instance.err(content: '第二次错误'); // 不同内容，应发送
        await Future.delayed(const Duration(milliseconds: 1200));

        // err 发送了 2 条（去重过滤了 1 条）
        final errItems = allSentItems
            .where((m) => m.containsKey('receivers'))
            .toList();
        expect(errItems.length, equals(2));
        expect(errItems[0]['content'], equals('第一次错误'));
        expect(errItems[1]['content'], equals('第二次错误'));

        // 3. pendingCount: 队列应该为空（echo 已经消费完了）
        expect(instance.pendingCount, equals(0));

        // 4. checkConnectivity: 不可达主机应返回 false
        final connected = await instance.checkConnectivity();
        expect(connected, isFalse);
      },
    );
  });
}
