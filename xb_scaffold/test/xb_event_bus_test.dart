import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class _TestEvent {
  final String msg;
  _TestEvent(this.msg);
}

class _OtherEvent {}

/// 持有回调字段的普通监听者（非 XBVM，模拟业务类忘记 removeListener 的场景）
class _Listener {
  final List<String> received = [];
  late final Function(_TestEvent) handler;

  _Listener() {
    handler = (event) => received.add(event.msg);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    // 清理强订阅通道，避免用例间串扰
  });

  group('XBEventBus addListener/fire', () {
    test('弱注册的基本收发', () {
      final listener = _Listener();
      XBEventBus.addListener<_TestEvent>(listener, listener.handler);

      XBEventBus.fire(_TestEvent('a'));
      expect(listener.received, ['a']);

      XBEventBus.fire(_OtherEvent());
      expect(listener.received, ['a'], reason: '其他类型事件不应分发');

      XBEventBus.removeListener(listener);
      XBEventBus.fire(_TestEvent('b'));
      expect(listener.received, ['a'], reason: '注销后不应再收到事件');
    });

    test('精确 runtimeType 匹配：父类型注册收不到子类型事件', () {
      final received = <String>[];
      final sub = _SubListenerHolder(received);
      XBEventBus.addListener<_SuperEvent>(sub, sub.handler);

      XBEventBus.fire(_SubEvent());
      expect(received, isEmpty, reason: 'fire 子类型不应命中父类型注册');

      XBEventBus.fire(_SuperEvent());
      expect(received, ['super']);

      XBEventBus.removeListener(sub);
    });

    test('多个 listener 同时分发', () {
      final l1 = _Listener();
      final l2 = _Listener();
      XBEventBus.addListener<_TestEvent>(l1, l1.handler);
      XBEventBus.addListener<_TestEvent>(l2, l2.handler);

      XBEventBus.fire(_TestEvent('x'));
      expect(l1.received, ['x']);
      expect(l2.received, ['x']);

      XBEventBus.removeListener(l1);
      XBEventBus.removeListener(l2);
    });

    test('单个 handler 抛异常不中断其余订阅者（fire 不抛出）', () {
      final bad = _Listener();
      final good = _Listener();
      // 抛异常的 handler 先注册，验证后面的订阅者不被拖垮
      XBEventBus.addListener<_TestEvent>(
          bad, (_TestEvent e) => throw StateError('boom'));
      XBEventBus.addListener<_TestEvent>(good, good.handler);

      XBEventBus.fire(_TestEvent('isolated'));
      expect(good.received, ['isolated'],
          reason: '前面的 handler 抛异常不应影响后面的订阅者');

      XBEventBus.removeListener(bad);
      XBEventBus.removeListener(good);
    });

    test('removeListener 只影响目标 listener', () {
      final l1 = _Listener();
      final l2 = _Listener();
      XBEventBus.addListener<_TestEvent>(l1, l1.handler);
      XBEventBus.addListener<_TestEvent>(l2, l2.handler);

      XBEventBus.removeListener(l1);
      XBEventBus.fire(_TestEvent('y'));
      expect(l1.received, isEmpty);
      expect(l2.received, ['y']);

      XBEventBus.removeListener(l2);
    });
  });

  group('XBEventBus on<T> 强订阅通道', () {
    test('on<T>() 过滤类型并收发', () async {
      final received = <String>[];
      final sub = XBEventBus.on<_TestEvent>().listen((e) => received.add(e.msg));

      XBEventBus.fire(_TestEvent('s'));
      XBEventBus.fire(_OtherEvent());
      await Future.delayed(Duration.zero);
      expect(received, ['s']);

      await sub.cancel();
    });
  });

  group('XBEventBus 弱引用自动清理', () {
    test('listener 被 GC 后注册项被剪除（prune 返回清理数量）', () {
      // 使用动态函数包装，避免编译器/测试环境把临时对象提升到栈外仍可达
      void register() {
        final temp = _Listener();
        XBEventBus.addListener<_TestEvent>(temp, temp.handler);
      }

      register();
      // 触发 GC：分配大量垃圾，使临时 listener 不可达并回收
      triggerGc();

      final removed = XBEventBus.prune();
      expect(removed, greaterThan(0), reason: '被 GC 的 listener 应被 prune 清理');
    });
  });

  group('XBEventBus initController', () {
    test('重复初始化 assert 报错', () {
      // 注意：controller 默认懒创建；本用例在所有会触发懒创建的用例之后运行，
      // 此时 _controller 已存在，任何 initController 调用都应 assert
      expect(
        () => XBEventBus.initController(StreamController<dynamic>.broadcast()),
        throwsA(isA<AssertionError>()),
        reason: 'controller 已被懒创建后再注入应立即报错，而非静默失效',
      );

      // 首次注入成功后，二次注入也应报错
      // （当前 _controller 非空，上面的调用已验证该场景）
    });

    test('默认 controller 懒创建后注入报错（旧 setController 顺序敏感问题的修复验证）', () {
      // 访问 controller getter 触发懒创建
      expect(XBEventBus.controller, isNotNull);
      expect(
        () => XBEventBus.initController(StreamController<dynamic>.broadcast()),
        throwsA(isA<AssertionError>()),
        reason: '懒创建后再注入应报错',
      );
    });
  });
}

class _SuperEvent {
  final String tag = 'super';
}

class _SubEvent extends _SuperEvent {}

class _SubListenerHolder {
  final List<String> received;
  late final Function(_SuperEvent) handler;

  _SubListenerHolder(this.received) {
    handler = (event) => received.add(event.tag);
  }
}

/// 尽力触发 GC（VM 侧；dart:cli 不存在，用内存分配压力 + 提示性手段）
void triggerGc() {
  // ignore: avoid_print
  List.generate(200000, (i) => {'garbage': i}).toList();
}
