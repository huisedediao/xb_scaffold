import 'dart:convert';
import 'dart:io';

import 'xb_ume_persistence.dart';

class _FilePersistence implements XBUmePersistence {
  _FilePersistence(this.filename);

  final String filename;

  File get _file => File('${Directory.systemTemp.path}/$filename');

  @override
  Future<Map<String, dynamic>?> load() async {
    if (!await _file.exists()) return null;
    try {
      final text = await _file.readAsString();
      final jsonValue = json.decode(text);
      if (jsonValue is Map<String, dynamic>) {
        return jsonValue;
      }
      if (jsonValue is Map) {
        return jsonValue.cast<String, dynamic>();
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> save(Map<String, dynamic> jsonObject) async {
    try {
      if (!await _file.parent.exists()) {
        await _file.parent.create(recursive: true);
      }
      await _file.writeAsString(json.encode(jsonObject));
    } catch (_) {}
  }
}

XBUmePersistence createDefaultPersistence(String filename) {
  return _FilePersistence(filename);
}
