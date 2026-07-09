import 'echo_storage.dart';

/// Echo 日志组件配置。
///
/// [echoHost] 和 [appId] 为必填项，其余均有默认值。
/// 动态信息（userId、sid、设备信息等）通过回调注入，解耦项目依赖。
class EchoConfig {
  // ---- 必填 ----

  /// Echo 服务器地址，例如 "http://144.168.61.190:3000"
  final String echoHost;

  /// 应用标识，例如 "com.jfapp.bcloud"
  final String appId;

  // ---- 可选：动态信息提供者 ----

  /// 当前登录用户的 ID
  final String Function()? userIdProvider;

  /// 当前会话的 sid
  final String Function()? sidProvider;

  /// 应用版本号
  final String Function()? appVersionProvider;

  /// 设备型号，例如 "apple iPhone12,1" 或 "Xiaomi 2106118C"
  final String Function()? deviceProvider;

  /// 操作系统版本，例如 "15.0" 或 "12"
  final String Function()? systemVersionProvider;

  /// 设备唯一标识
  final String Function()? udidProvider;

  /// 环境标识，例如 "正式"、"测试"、"预发布"
  final String Function()? environmentProvider;

  /// 页面导航日志（用于追踪用户操作路径）
  final String Function()? pageLogProvider;

  // ---- 可选：运行模式 ----

  /// 是否为调试模式，影响 mode 字段值
  final bool isDebugMode;

  // ---- 可选：队列配置 ----

  /// 队列最大容量，超出后丢弃最旧记录。默认 1000
  final int queueMaxSize;

  /// 应用启动后延迟多久开始消费队列。默认 2 秒
  final Duration startDelay;

  // ---- 可选：存储 ----

  /// 队列持久化存储，null 则使用 [EchoMemoryStorage]（仅内存，不持久化）
  final EchoStorage? storage;

  // ---- 可选：HTTP 发送器 ----

  /// 自定义 HTTP 发送器，签名: `Future<bool> Function(Map<String, dynamic> infoMap)`。
  /// 返回 true 表示发送成功，false 表示失败。
  /// 不设置则使用内置 dio 发送器。
  final Future<bool> Function(Map<String, dynamic>)? customSender;

  // ---- 可选：错误上报 ----

  /// 错误通知接收人邮箱列表
  final List<String> errorReceivers;

  /// 本地日志写入回调，用于在发送 err 时同步写本地日志
  final void Function(Map<String, dynamic>)? localLogWriter;

  /// 错误去重列表持久化存储 key，用于跨启动去重
  final String errorDedupStorageKey;

  const EchoConfig({
    required this.echoHost,
    required this.appId,
    this.userIdProvider,
    this.sidProvider,
    this.appVersionProvider,
    this.deviceProvider,
    this.systemVersionProvider,
    this.udidProvider,
    this.environmentProvider,
    this.pageLogProvider,
    this.isDebugMode = false,
    this.queueMaxSize = 1000,
    this.startDelay = const Duration(seconds: 2),
    this.storage,
    this.customSender,
    this.errorReceivers = const [],
    this.localLogWriter,
    this.errorDedupStorageKey = 'xb_echo_logger_error_dedup',
  });

  /// 获取 mode 字符串
  String get mode => isDebugMode ? 'debug' : 'release';
}
