abstract class XBUmeStorageAdapter {
  String get id;

  bool get writable => false;

  Future<Map<String, dynamic>> dump();

  Future<void> setValue(String key, dynamic value) async {}

  Future<void> removeValue(String key) async {}
}

class XBUmeMapStorageAdapter implements XBUmeStorageAdapter {
  XBUmeMapStorageAdapter({
    required this.id,
    required Map<String, dynamic> data,
    this.allowWrite = false,
  }) : _data = data;

  @override
  final String id;

  final Map<String, dynamic> _data;
  final bool allowWrite;

  @override
  bool get writable => allowWrite;

  @override
  Future<Map<String, dynamic>> dump() async {
    return Map<String, dynamic>.from(_data);
  }

  @override
  Future<void> setValue(String key, dynamic value) async {
    if (!allowWrite) return;
    _data[key] = value;
  }

  @override
  Future<void> removeValue(String key) async {
    if (!allowWrite) return;
    _data.remove(key);
  }
}
