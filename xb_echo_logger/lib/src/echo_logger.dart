import 'echo_config.dart';
import 'echo_http_client.dart';
import 'echo_queue.dart';
import 'echo_storage.dart';

/// Echo 日志上报组件 —— 主入口。
///
/// 使用方式：
/// ```dart
/// await XBEchoLogger.init(
///   config: EchoConfig(
///     echoHost: 'http://144.168.61.190:3000',
///     appId: 'com.example.app',
///     userIdProvider: () => myUser.id,
///     sidProvider: () => mySession.sid,
///     isDebugMode: kDebugMode,
///   ),
/// );
///
/// XBEchoLogger.instance.echo(content: '用户点击了按钮');
/// XBEchoLogger.instance.err(content: '接口返回异常');
/// ```
class XBEchoLogger {
  static XBEchoLogger? _instance;

  final EchoConfig _config;
  late final EchoQueue _queue;
  final List<int> _errorHashCodes = [];
  bool _dedupListDirty = false;

  XBEchoLogger._(this._config);

  // ---- 初始化 ----

  /// 初始化组件，必须在应用启动时调用一次。
  ///
  /// [config] 配置项，[EchoConfig.echoHost] 和 [EchoConfig.appId] 为必填。
  static Future<void> init({required EchoConfig config}) async {
    if (_instance != null) {
      throw StateError('XBEchoLogger 已初始化，不可重复调用 init()');
    }

    _instance = XBEchoLogger._(config);

    final storage = config.storage ?? EchoMemoryStorage();

    final sender = config.customSender ??
        (Map<String, dynamic> infoMap) async {
          return EchoHttpClient.post('${config.echoHost}/echo', infoMap);
        };

    _instance!._queue = EchoQueue(
      storage: storage,
      sender: sender,
      maxSize: config.queueMaxSize,
      startDelay: config.startDelay,
    );

    await _instance!._queue.init();
    await _instance!._restoreDedupList();
  }

  /// 获取单例，使用前必须先调用 [init]。
  static XBEchoLogger get instance {
    if (_instance == null) {
      throw StateError('XBEchoLogger 未初始化，请先调用 XBEchoLogger.init()');
    }
    return _instance!;
  }

  // ---- 公开 API ----

  /// 上报一条普通日志（走队列，离线缓存）。
  ///
  /// [content] 日志内容，可以是 String 或任意对象（会调用 toString()）
  /// [extraInfo] 附加字段，会合并到上报的 JSON 中
  /// [needPageLog] 是否附带页面导航路径，默认 true
  Future<void> echo({
    required dynamic content,
    Map<String, dynamic>? extraInfo,
    bool needPageLog = true,
  }) async {
    final infoMap = _buildInfoMap(content: content, needPageLog: needPageLog);
    if (extraInfo != null) {
      infoMap.addAll(extraInfo);
    }
    infoMap.addAll(_loginInfo());
    await _queue.addTask(infoMap);
  }

  /// 上报一条错误日志（直接发送，带去重，不经过队列）。
  ///
  /// [content] 错误内容
  /// [extraInfo] 附加信息
  /// [needPageLog] 是否附带页面导航路径
  ///
  /// 相同错误（content + appId + mode + userId + device + systemVersion 的 hashCode 相同）
  /// 在当前会话中只会上报一次。
  Future<void> err({
    required dynamic content,
    Map<String, dynamic>? extraInfo,
    bool needPageLog = true,
  }) async {
    final infoMap = _buildInfoMap(content: content, needPageLog: needPageLog);
    if (extraInfo != null) {
      infoMap.addAll(extraInfo);
    }
    infoMap.addAll(_loginInfo());

    // 去重：基于 content + appId + mode + userId + device + systemVersion
    final hashKey = (content.toString() +
            _config.appId +
            _config.mode +
            (infoMap['userId'] ?? '') +
            (infoMap['device'] ?? '') +
            (infoMap['systemVersion'] ?? ''))
        .hashCode;

    if (_errorHashCodes.contains(hashKey)) return;
    _errorHashCodes.add(hashKey);
    if (_errorHashCodes.length > 1000) {
      _errorHashCodes.removeAt(0);
    }
    _saveDedupList();

    // 延迟 1 秒后发送（匹配原始行为）
    Future.delayed(const Duration(seconds: 1), () async {
      final bodyParams = <String, dynamic>{
        'receivers': _config.errorReceivers,
      };
      bodyParams.addAll(infoMap);

      _config.localLogWriter?.call(bodyParams);

      final url = '${_config.echoHost}/errCatch';
      final sender = _config.customSender ??
          (Map<String, dynamic> map) async {
            return EchoHttpClient.post(url, map);
          };
      sender(bodyParams);
    });
  }

  /// 检查 Echo 服务器连通性。
  Future<bool> checkConnectivity() async {
    return EchoHttpClient.checkConnectivity(_config.echoHost);
  }

  /// 获取当前队列中待发送日志数。
  int get pendingCount => _queue.pendingCount;

  // ---- 内部实现 ----

  Map<String, dynamic> _buildInfoMap({
    required dynamic content,
    bool needPageLog = true,
  }) {
    final map = <String, dynamic>{
      'id': DateTime.now().microsecondsSinceEpoch,
      'content': content.toString(),
      'appid': _config.appId,
      'mode': _config.mode,
      'device': _config.deviceProvider?.call() ?? 'unknown',
      'systemVersion': _config.systemVersionProvider?.call() ?? 'unknown',
      'appVersion': _config.appVersionProvider?.call() ?? 'unknown',
      'environment': _config.environmentProvider?.call() ?? 'unknown',
      'udid': _config.udidProvider?.call() ?? 'unknown',
    };

    if (needPageLog) {
      final pageLog = _config.pageLogProvider?.call();
      if (pageLog != null && pageLog.isNotEmpty) {
        map['pageLog'] = pageLog;
      }
    }

    return map;
  }

  Map<String, dynamic> _loginInfo() {
    return {
      'userId': _config.userIdProvider?.call() ?? '',
      'sid': _config.sidProvider?.call() ?? '',
    };
  }

  // ---- 去重列表持久化 ----

  Future<void> _restoreDedupList() async {
    final storage = _config.storage ?? EchoMemoryStorage();
    try {
      final temp = await storage.getString(_config.errorDedupStorageKey);
      if (temp != null && temp.isNotEmpty) {
        final decoded = _parseIntList(temp);
        if (decoded != null) {
          _errorHashCodes.addAll(decoded);
        }
      }
    } catch (_) {
      _errorHashCodes.clear();
    }
  }

  void _saveDedupList() {
    _dedupListDirty = true;
    // 批量写入，避免频繁 I/O
    Future.delayed(const Duration(seconds: 5), () async {
      if (!_dedupListDirty) return;
      _dedupListDirty = false;
      final storage = _config.storage ?? EchoMemoryStorage();
      await storage.setString(
        _config.errorDedupStorageKey,
        _errorHashCodes.join(','),
      );
    });
  }

  List<int>? _parseIntList(String raw) {
    if (raw.isEmpty) return null;
    try {
      return raw.split(',').map(int.parse).toList();
    } catch (_) {
      return null;
    }
  }
}
