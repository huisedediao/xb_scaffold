import 'xb_ume_log_file.dart';
import 'xb_ume_log_file_stub.dart'
    if (dart.library.io) 'xb_ume_log_file_io.dart';

XBUmeLogFile? buildXbUmeLogFile({
  required String dir,
  required String fileName,
  required int maxBytes,
  required int backups,
}) {
  return createLogFile(
    dir: dir,
    fileName: fileName,
    maxBytes: maxBytes,
    backups: backups,
  );
}
