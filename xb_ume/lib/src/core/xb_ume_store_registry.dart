/// 实例注册表：app 端把需要 GUI 查看的运行时对象（如 Provider 的
/// ChangeNotifier、全局 State、单例 service）注册进来。
///
/// GUI 侧通过 VM service 在本库上下文 eval 读取 [resolvedStores]，按 id 拿
/// 到实例引用后用 getObject 展开字段树。内部用 WeakReference 弱持有——
/// 注册不会延长对象生命周期：页面级 controller 忘记 unregister 也会随
/// 页面销毁被正常 GC（GUI 列表自动不再显示该条目）。
class XBUmeStoreRegistry {
  XBUmeStoreRegistry._();

  static final Map<String, WeakReference<Object>> _stores =
      <String, WeakReference<Object>>{};

  /// 注册（重复 id 覆盖旧值）。
  static void register(String id, Object store) =>
      _stores[id] = WeakReference(store);

  /// 取消注册（可选：页面级对象 dispose 时调用，让 GUI 列表立即干净）。
  static void unregister(String id) => _stores.remove(id);

  /// 已注册且仍存活的 id 列表（仅供 app 侧调试）。
  static List<String> get ids => _stores.entries
      .where((e) => e.value.target != null)
      .map((e) => e.key)
      .toList(growable: false);

  /// GUI 经 VM service eval 读取：id → 存活实例。
  /// 弱引用在此解包为强引用临时副本，仅本次 eval 期间存活，不影响 GC。
  static Map<String, Object> get resolvedStores => <String, Object>{
        for (final e in _stores.entries)
          if (e.value.target != null) e.key: e.value.target!,
      };
}
