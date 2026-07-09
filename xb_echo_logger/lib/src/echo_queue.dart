import 'dart:convert';

import 'echo_storage.dart';

/// 日志队列管理器 —— 组件的核心模块。
///
/// 功能：
/// - 内存队列 + 持久化存储，防止应用被杀后数据丢失
/// - 启动后延迟消费，避免与初始化流程争抢资源
/// - 串行消费（互斥锁），保证日志按序发送
/// - 发送失败自动丢弃当前条目、继续处理下一条，不阻塞队列
class EchoQueue {
  final EchoStorage _storage;
  final Future<bool> Function(Map<String, dynamic>) _sender;
  final int _maxSize;
  final Duration _startDelay;
  static const String _storeKey = 'xb_echo_logger_queue';

  bool _canExecute = false;
  final List<Map<String, dynamic>> _logs = [];

  EchoQueue({
    required EchoStorage storage,
    required Future<bool> Function(Map<String, dynamic>) sender,
    int maxSize = 1000,
    Duration startDelay = const Duration(seconds: 2),
  })  : _storage = storage,
        _sender = sender,
        _maxSize = maxSize,
        _startDelay = startDelay;

  // ---- 公开 API ----

  /// 初始化队列：从存储恢复未发送日志，延迟 [startDelay] 后开始消费。
  Future<void> init() async {
    await _restore();

    Future.delayed(_startDelay, () {
      _canExecute = true;
      _execute();
    });
  }

  /// 添加一条日志到队列。
  ///
  /// 若队列已满，丢弃最旧的记录。
  /// 调用后自动触发消费（若尚未到启动时间则等待）。
  Future<void> addTask(Map<String, dynamic> info) async {
    if (_logs.length >= _maxSize) {
      _logs.removeAt(0);
    }
    _logs.add(info);
    await _save();
    _execute();
  }

  /// 当前队列中待发送的日志数量。
  int get pendingCount => _logs.length;

  /// 清空队列（同时清除持久化数据）。
  Future<void> clear() async {
    _logs.clear();
    await _save();
  }

  // ---- 内部实现 ----

  Future<void> _restore() async {
    try {
      final temp = await _storage.getString(_storeKey);
      if (temp != null && temp.isNotEmpty) {
        final decoded = jsonDecode(temp);
        if (decoded is List) {
          _logs.addAll(decoded.cast<Map<String, dynamic>>());
        }
      }
    } catch (_) {
      _logs.clear();
    }
  }

  void _execute() {
    if (_logs.isEmpty) return;
    if (!_canExecute) return;

    _canExecute = false;
    final info = _logs.removeAt(0);
    _save();

    _sender(info).then((_) {
      _canExecute = true;
      _execute();
    }).catchError((_) {
      _canExecute = true;
      _execute();
    });
  }

  Future<void> _save() async {
    await _storage.setString(_storeKey, jsonEncode(_logs));
  }
}
