import 'xb_ume_persistence.dart';
import 'xb_ume_persistence_stub.dart'
    if (dart.library.io) 'xb_ume_persistence_io.dart';

XBUmePersistence buildDefaultXbUmePersistence(String filename) {
  return createDefaultPersistence(filename);
}
