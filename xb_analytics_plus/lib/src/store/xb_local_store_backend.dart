import 'xb_local_store_backend_stub.dart'
    if (dart.library.io) 'xb_local_store_backend_io.dart'
    if (dart.library.html) 'xb_local_store_backend_web.dart';

abstract class XBLocalStoreBackend {
  Future<void> init();

  Future<void> appendLines(List<String> lines);

  Future<List<String>> readLines();

  Future<void> overwriteLines(List<String> lines);

  Future<void> clear();

  Future<void> close();
}

XBLocalStoreBackend createXBLocalStoreBackend({required String namespace}) {
  return createXBLocalStoreBackendImpl(namespace: namespace);
}
