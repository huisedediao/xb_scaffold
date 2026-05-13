abstract class XBUmePersistence {
  Future<Map<String, dynamic>?> load();

  Future<void> save(Map<String, dynamic> json);
}
