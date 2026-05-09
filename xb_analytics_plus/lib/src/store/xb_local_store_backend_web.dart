// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:convert';
import 'dart:html' as html;

import 'xb_local_store_backend.dart';

class _XBWebStoreBackend implements XBLocalStoreBackend {
  final String namespace;

  _XBWebStoreBackend({required this.namespace});

  late final String _storageKey;

  @override
  Future<void> init() async {
    _storageKey = '${namespace}_events_jsonl';
  }

  List<String> _current() {
    final content = html.window.localStorage[_storageKey];
    if (content == null || content.isEmpty) return <String>[];
    final decoded = jsonDecode(content);
    if (decoded is! List) return <String>[];
    return decoded.map((dynamic e) => '$e').toList();
  }

  @override
  Future<void> appendLines(List<String> lines) async {
    if (lines.isEmpty) return;
    final all = _current()..addAll(lines);
    html.window.localStorage[_storageKey] = jsonEncode(all);
  }

  @override
  Future<void> clear() async {
    html.window.localStorage.remove(_storageKey);
  }

  @override
  Future<void> close() async {}

  @override
  Future<List<String>> readLines() async {
    return _current();
  }

  @override
  Future<void> overwriteLines(List<String> lines) async {
    if (lines.isEmpty) {
      await clear();
      return;
    }
    html.window.localStorage[_storageKey] = jsonEncode(lines);
  }
}

XBLocalStoreBackend createXBLocalStoreBackendImpl({
  required String namespace,
}) {
  return _XBWebStoreBackend(namespace: namespace);
}
