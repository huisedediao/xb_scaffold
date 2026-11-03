import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'xb_ume_log_file.dart';

/// 追加写 + 定时刷盘 + 按大小轮转的文件实现。
///
/// 设计取舍：
/// - 用 `IOSink` 而不是每条 `writeAsStringSync`：debugPrint 风暴时同步写会掉帧；
/// - 缓冲积在内存里（`_pending`），轮转那句「关旧文件 / 开新文件」期间也不丢行；
/// - 所有 IO 失败都吞掉——日志落盘是辅助能力，绝不能反过来影响宿主 app。
class _IoLogFile implements XBUmeLogFile {
  _IoLogFile({
    required File file,
    required int maxBytes,
    required int backups,
  })  : _file = file,
        _maxBytes = maxBytes <= 0 ? 4 * 1024 * 1024 : maxBytes,
        _backups = backups < 0 ? 0 : backups {
    try {
      file.parent.createSync(recursive: true);
    } catch (_) {}
    _openSink();
  }

  final File _file;
  final int _maxBytes;
  final int _backups;

  /// 等 sink 就绪期间先攒在这里（轮转窗口只有几毫秒）。
  final List<String> _pending = <String>[];

  IOSink? _sink;
  int _bytes = 0;
  bool _rotatePending = false;
  bool _closed = false;
  Future<void>? _rotating;
  Timer? _flushTimer;

  @override
  String? get path => _file.path;

  void _openSink() {
    try {
      _sink = _file.openWrite(mode: FileMode.append);
      _bytes = _file.existsSync() ? _file.lengthSync() : 0;
    } catch (_) {
      _sink = null;
    }
    final sink = _sink;
    if (sink == null || _pending.isEmpty) return;
    try {
      sink.write(_pending.join());
      _bytes += _pending.fold<int>(0, (n, s) => n + utf8.encode(s).length);
    } catch (_) {}
    _pending.clear();
  }

  @override
  void append({
    required DateTime time,
    required String level,
    required String tag,
    required String message,
    String? stack,
  }) {
    if (_closed) return;
    final text = StringBuffer()
      ..write(time.toIso8601String())
      ..write(' [')
      ..write(level.toUpperCase())
      ..write('] ')
      ..write(tag)
      ..write(': ')
      ..write(message)
      ..write('\n');
    if (stack != null && stack.isNotEmpty) {
      text
        ..write(stack)
        ..write('\n');
    }
    final line = text.toString();
    final sink = _sink;
    if (sink == null) {
      // 正在轮转：先攒着，重开后一次性补写（上限兜底，避免内存失控）。
      if (_pending.length < 5000) _pending.add(line);
      return;
    }
    try {
      sink.write(line);
      _bytes += utf8.encode(line).length;
    } catch (_) {
      return;
    }
    if (_bytes >= _maxBytes) _rotatePending = true;
    _flushTimer ??= Timer(const Duration(milliseconds: 800), _onFlushTimer);
  }

  void _onFlushTimer() {
    _flushTimer = null;
    if (_closed) return;
    unawaited(_flushAndMaybeRotate());
  }

  Future<void> _flushAndMaybeRotate() async {
    final sink = _sink;
    if (sink != null) {
      try {
        await sink.flush();
      } catch (_) {}
    }
    if (_rotatePending && !_closed) {
      _rotatePending = false;
      await _rotate();
    }
  }

  Future<void> _rotate() async {
    final previous = _rotating;
    if (previous != null) await previous;
    _rotating = _doRotate();
    await _rotating;
    _rotating = null;
  }

  Future<void> _doRotate() async {
    final sink = _sink;
    _sink = null;
    try {
      await sink?.close();
    } catch (_) {}
    _rotateFiles();
    _bytes = 0;
    if (!_closed) _openSink();
  }

  void _rotateFiles() {
    try {
      if (_backups == 0) {
        if (_file.existsSync()) _file.deleteSync();
        return;
      }
      final oldest = File('${_file.path}.$_backups');
      if (oldest.existsSync()) oldest.deleteSync();
      for (var i = _backups - 1; i >= 1; i--) {
        final f = File('${_file.path}.$i');
        if (f.existsSync()) f.renameSync('${_file.path}.${i + 1}');
      }
      if (_file.existsSync()) _file.renameSync('${_file.path}.1');
    } catch (_) {}
  }

  @override
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final rotating = _rotating;
    if (rotating != null) await rotating;
    await _flushAndMaybeRotate();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    final rotating = _rotating;
    if (rotating != null) {
      try {
        await rotating;
      } catch (_) {}
    }
    final sink = _sink;
    _sink = null;
    try {
      await sink?.flush();
    } catch (_) {}
    try {
      await sink?.close();
    } catch (_) {}
  }
}

XBUmeLogFile? createLogFile({
  required String dir,
  required String fileName,
  required int maxBytes,
  required int backups,
}) {
  try {
    final base = dir.trim().isEmpty
        ? '${Directory.systemTemp.path}/xb_ume_logs'
        : dir.trim();
    final name = fileName.trim().isEmpty ? 'console.log' : fileName.trim();
    return _IoLogFile(
      file: File('$base/$name'),
      maxBytes: maxBytes,
      backups: backups,
    );
  } catch (_) {
    return null;
  }
}
