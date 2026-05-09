import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'xb_local_store_backend.dart';

class _XBIOStoreBackend implements XBLocalStoreBackend {
  final String namespace;

  _XBIOStoreBackend({required this.namespace});

  File? _file;

  @override
  Future<void> init() async {
    if (_file != null) return;
    Directory? dir;
    try {
      dir = await getApplicationSupportDirectory();
    } catch (_) {
      try {
        dir = await getApplicationDocumentsDirectory();
      } catch (_) {
        dir = await getTemporaryDirectory();
      }
    }
    final storeDir = Directory('${dir.path}/$namespace');
    if (!await storeDir.exists()) {
      await storeDir.create(recursive: true);
    }
    _file = File('${storeDir.path}/events.jsonl');
    if (!await _file!.exists()) {
      await _file!.create(recursive: true);
    }
  }

  Future<File> get _readyFile async {
    await init();
    return _file!;
  }

  @override
  Future<void> appendLines(List<String> lines) async {
    if (lines.isEmpty) return;
    final file = await _readyFile;
    final content = StringBuffer();
    for (final line in lines) {
      content.writeln(line);
    }
    await file.writeAsString(content.toString(), mode: FileMode.append);
  }

  @override
  Future<List<String>> readLines() async {
    final file = await _readyFile;
    if (!await file.exists()) return <String>[];
    return file.readAsLines();
  }

  @override
  Future<void> overwriteLines(List<String> lines) async {
    final file = await _readyFile;
    if (lines.isEmpty) {
      await file.writeAsString('');
      return;
    }
    final content = StringBuffer();
    for (final line in lines) {
      content.writeln(line);
    }
    await file.writeAsString(content.toString(), mode: FileMode.write);
  }

  @override
  Future<void> clear() async {
    final file = await _readyFile;
    if (await file.exists()) {
      await file.writeAsString('');
    }
  }

  @override
  Future<void> close() async {}
}

XBLocalStoreBackend createXBLocalStoreBackendImpl({
  required String namespace,
}) {
  return _XBIOStoreBackend(namespace: namespace);
}
