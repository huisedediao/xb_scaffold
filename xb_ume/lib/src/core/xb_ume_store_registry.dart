/// 实例注册表：app 端把需要 GUI 查看的运行时对象（如 Provider 的
/// ChangeNotifier、全局 State、单例 service）注册进来。
///
/// GUI 侧通过 VM service 在本库上下文 eval 读取 [_stores]，按 id 拿到
/// 实例引用后用 getObject 展开字段树。注册的只是引用，不持有副本。
class XBUmeStoreRegistry {
  XBUmeStoreRegistry._();

  static final Map<String, Object> _stores = <String, Object>{};

  /// 注册（重复 id 覆盖旧值）。
  static void register(String id, Object store) => _stores[id] = store;

  /// 取消注册。
  static void unregister(String id) => _stores.remove(id);

  /// 已注册的 id 列表（仅供 app 侧调试）。
  static List<String> get ids => _stores.keys.toList(growable: false);
}
