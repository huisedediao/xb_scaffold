import 'xb_ume_persistence.dart';

class _NoopPersistence implements XBUmePersistence {
  @override
  Future<Map<String, dynamic>?> load() async {
    return null;
  }

  @override
  Future<void> save(Map<String, dynamic> json) async {}
}

XBUmePersistence createDefaultPersistence(String filename) {
  return _NoopPersistence();
}
