import 'dart:async';

/// 全局事件总线
///
/// 订阅为弱注册：Bus 对 listener 及其回调只持弱引用，
/// listener 被业务方废弃后（即使忘记 removeListener），
/// 注册项会随 GC 自动失效，并在下次 fire/prune 时被剪除。
///
/// 注意：
/// 1. 回调须由 listener 自己持有（存字段或作为其方法），
///    否则回调可能先于 listener 被 GC 回收导致收不到事件；
///    `XBVM.listen` 已自动保管回调，VM 使用者无感知。
/// 2. 需要强订阅（临时匿名闭包等场景）请使用 [on] 获取流并自行管理取消。
/// 3. 按事件类型的 runtimeType 精确匹配分发（不做子类型匹配）。
class XBEventBus {
  XBEventBus._();

  static StreamController? _controller;

  static StreamController get controller {
    _controller ??= StreamController<dynamic>.broadcast();
    return _controller!;
  }

  /// 显式注入自定义 controller（如自定义 broadcast 策略/测试替身）。
  /// 必须在任何订阅发生前调用，重复初始化会 assert 报错。
  static void initController(StreamController customController) {
    assert(
        _controller == null,
        'XBEventBus controller has already been initialized. '
        'initController must be called before any listener/fire.');
    _controller ??= customController;
  }

  /// 已废弃：请使用 [initController]，注入时机错误时不再静默失效
  @Deprecated('Use initController instead. '
      'This method silently fails if the default controller was already created.')
  static void setController(StreamController controller) {
    initController(controller);
  }

  /// 发送事件，按 runtimeType 精确分发给对应类型的订阅者
  static void fire(dynamic event) {
    if (event == null) return;
    final entries = _entries[event.runtimeType];
    if (entries == null || entries.isEmpty) {
      // 兼容保留：仍向自定义 controller 广播，保证 on<T>() 订阅可用
      if (_controller != null && _controller!.hasListener) {
        controller.add(event);
      }
      return;
    }
    // 快照遍历：分发过程中允许 add/removeListener
    for (final entry in List<_WeakEntry>.of(entries)) {
      final handler = entry.handlerRef.target;
      if (handler == null || entry.listenerRef.target == null) {
        // 惰性清理：listener 或回调已被 GC 回收
        entries.remove(entry);
        continue;
      }
      (handler)(event);
    }
    // 兼容保留：仍向自定义 controller 广播，保证 on<T>() 订阅可用
    if (_controller != null && _controller!.hasListener) {
      controller.add(event);
    }
  }

  /// 获取事件流（强订阅通道）。
  /// 返回的流按 [T] 过滤，需自行管理 StreamSubscription 的取消。
  static Stream<T> on<T>() {
    if (T == dynamic) {
      return controller.stream as Stream<T>;
    } else {
      return controller.stream.where((event) => event is T).cast<T>();
    }
  }

  /// 弱注册：listener 须自己持有 onData（如存入字段），
  /// 否则 onData 可能先于 listener 被 GC 而收不到事件。
  /// [XBVM.listen] 已自动保管回调，VM 使用者无感知。
  static void addListener<T>(dynamic listener, Function(T data) onData) {
    // 保管回调的弱引用；listener 自己持有 onData（VM 内部已自动保管）
    final entry = _WeakEntry(listener, onData);
    _entries.putIfAbsent(T, () => []).add(entry);
    _pruneLocked(T);
  }

  /// 移除 listener 在所有事件类型下的注册。
  /// 如果 listener 是 XBVM 类型，dispose 时会自动调用，无需手动清理。
  static void removeListener(dynamic listener) {
    final deadTypes = <Type>[];
    _entries.forEach((type, entries) {
      entries.removeWhere((entry) => entry.listenerRef.target == listener);
      if (entries.isEmpty) {
        deadTypes.add(type);
      }
    });
    for (final type in deadTypes) {
      _entries.remove(type);
    }
  }

  /// 主动清理所有已被 GC 回收的注册项（通常无需手动调用，
  /// fire/addListener 时会惰性清理；测试/排查内存时可使用）
  static int prune() {
    int removed = 0;
    final deadTypes = <Type>[];
    _entries.forEach((type, entries) {
      final before = entries.length;
      entries.removeWhere((entry) =>
          entry.listenerRef.target == null || entry.handlerRef.target == null);
      removed += before - entries.length;
      if (entries.isEmpty) {
        deadTypes.add(type);
      }
    });
    for (final type in deadTypes) {
      _entries.remove(type);
    }
    return removed;
  }

  static final Map<Type, List<_WeakEntry>> _entries = {};

  static void _pruneLocked(Type type) {
    final entries = _entries[type];
    if (entries == null) return;
    entries.removeWhere((entry) =>
        entry.listenerRef.target == null || entry.handlerRef.target == null);
  }
}

class _WeakEntry {
  final WeakReference<Object> listenerRef;
  final WeakReference<Function> handlerRef;

  _WeakEntry(Object listener, Function handler)
      : listenerRef = WeakReference<Object>(listener),
        handlerRef = WeakReference<Function>(handler);
}
