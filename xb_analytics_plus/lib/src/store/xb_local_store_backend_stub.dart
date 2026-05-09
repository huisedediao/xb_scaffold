import 'xb_local_store_backend.dart';

class _XBMemoryStoreBackend implements XBLocalStoreBackend {
  final List<String> _lines = <String>[];

  @override
  Future<void> appendLines(List<String> lines) async {
    _lines.addAll(lines);
  }

  @override
  Future<void> clear() async {
    _lines.clear();
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> init() async {}

  @override
  Future<List<String>> readLines() async {
    return List<String>.from(_lines);
  }

  @override
  Future<void> overwriteLines(List<String> lines) async {
    _lines
      ..clear()
      ..addAll(lines);
  }
}

XBLocalStoreBackend createXBLocalStoreBackendImpl({
  required String namespace,
}) {
  return _XBMemoryStoreBackend();
}
