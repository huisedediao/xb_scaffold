/// 日志队列持久化存储接口。
///
/// 默认提供 [EchoMemoryStorage]（仅内存），
/// 使用者可实现此接口接入 SharedPreferences 或其他持久化方案。
abstract class EchoStorage {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// 基于内存的存储实现，无持久化，应用重启后队列数据丢失。
class EchoMemoryStorage implements EchoStorage {
  EchoMemoryStorage();

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
}
