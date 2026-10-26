// 设备后端抽象（P2）：把「手机/模拟器/桌面上装包、起停、按键、抓崩溃」
// 收敛成一套接口，供 MCP 工具层调用。
//
// 设计要点：
//   - 能力显式声明（capabilities）：不支持的能力由默认实现抛
//     [DeviceUnsupported]，工具层转成结构化 unsupported，不假装支持；
//   - 后端可插拔：adb / hdc / simctl / idevice / mobile-mcp 各自实现，
//     registry 负责按 --device-backend 组装与路由；
//   - 只做「进程外黑盒操作」，与 VM service 的进程内白盒操作互补。
library;

/// 后端能做的事。
enum DeviceCapability {
  install,
  uninstall,
  launch,
  terminate,
  pressKey,
  tapNative,
  crashList,
  crashGet,
}

/// 可注入的按键（各后端自行映射到平台键码）。
enum DeviceKey {
  back,
  home,
  enter,
  delete,
  tab,
  escape,
  menu,
  appSwitch,
  volumeUp,
  volumeDown,
  power,
}

/// 解析按键名；未知返回 null。
DeviceKey? parseDeviceKey(String raw) {
  final s = raw.trim().toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');
  for (final k in DeviceKey.values) {
    if (k.name.toLowerCase() == s) return k;
  }
  const alias = <String, DeviceKey>{
    'backbutton': DeviceKey.back,
    'return': DeviceKey.enter,
    'del': DeviceKey.delete,
    'backspace': DeviceKey.delete,
    'appswitch': DeviceKey.appSwitch,
    'recent': DeviceKey.appSwitch,
    'volup': DeviceKey.volumeUp,
    'voldown': DeviceKey.volumeDown,
  };
  return alias[s];
}

/// 一台可由后端操作的设备。
class DeviceInfo {
  DeviceInfo({
    required this.backend,
    required this.id,
    required this.name,
    required this.platform,
    required this.state,
    this.model,
    this.osVersion,
  });

  final String backend;
  final String id;
  final String name;

  /// android / ios / harmonyos / macos
  final String platform;
  final String state;
  final String? model;
  final String? osVersion;

  bool get usable =>
      state.toLowerCase() == 'device' || state.toLowerCase() == 'booted';

  Map<String, Object?> toJson() => <String, Object?>{
        'backend': backend,
        'id': id,
        'name': name,
        'platform': platform,
        'state': state,
        if (model != null) 'model': model,
        if (osVersion != null) 'osVersion': osVersion,
        'usable': usable,
      };
}

/// 一条崩溃记录摘要。
class CrashReport {
  CrashReport({
    required this.id,
    required this.title,
    this.package,
    this.time,
    this.summary = '',
    this.path,
  });

  final String id;
  final String title;
  final String? package;
  final DateTime? time;
  final String summary;

  /// 源文件路径（iOS .ips / 设备上的日志文件）。
  final String? path;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        if (package != null) 'package': package,
        if (time != null) 'time': time!.toIso8601String(),
        if (summary.isNotEmpty) 'summary': summary,
        if (path != null) 'path': path,
      };
}

/// 能力不支持：不是错误，是后端边界。
class DeviceUnsupported implements Exception {
  DeviceUnsupported(this.capability, this.backend, this.reason);

  final DeviceCapability capability;
  final String backend;
  final String reason;

  @override
  String toString() => '$backend 不支持 ${capability.name}：$reason';
}

/// 命令执行失败（有 stderr / 退出码）。
class DeviceCommandError implements Exception {
  DeviceCommandError(this.backend, this.command, this.message);

  final String backend;
  final String command;
  final String message;

  @override
  String toString() => '$backend 命令失败（$command）：$message';
}

/// 设备后端基类：默认全部不支持，子类只覆盖能做的那几项。
abstract class DeviceBridge {
  /// 后端标识：adb / hdc / simctl / idevice / mobile-mcp。
  String get backend;

  /// 是否可用（可执行文件是否就绪、适配器是否连上）。
  bool get available;

  /// 不可用原因（available=false 时必填，供 xbume_devices 展示）。
  String? get unavailableReason => null;

  Set<DeviceCapability> get capabilities;

  bool supports(DeviceCapability c) => available && capabilities.contains(c);

  /// 能力清单（JSON 数组，工具层直接透出）。
  List<String> get capabilityNames =>
      capabilities.map((c) => c.name).toList(growable: false);

  Future<List<DeviceInfo>> listDevices();

  /// 预热连接（如适配器握手）；失败不抛，供能力矩阵展示前调用。
  Future<void> warmup() async {}

  Future<void> install(String deviceId, String artifact) =>
      _unsupported(DeviceCapability.install);

  Future<void> uninstall(String deviceId, String packageId) =>
      _unsupported(DeviceCapability.uninstall);

  /// 启动已安装的 app；返回可读说明（组件名 / 进程号等）。
  Future<String> launch(String deviceId, String packageId) =>
      _unsupported(DeviceCapability.launch);

  Future<void> terminate(String deviceId, String packageId) =>
      _unsupported(DeviceCapability.terminate);

  Future<void> pressKey(String deviceId, DeviceKey key) =>
      _unsupported(DeviceCapability.pressKey);

  Future<void> tapNative(String deviceId, int x, int y) =>
      _unsupported(DeviceCapability.tapNative);

  Future<List<CrashReport>> crashList(
    String deviceId, {
    String? packageId,
    int limit = 20,
  }) =>
      _unsupported(DeviceCapability.crashList);

  Future<String> crashGet(String deviceId, String crashId) =>
      _unsupported(DeviceCapability.crashGet);

  /// 释放后端持有的资源（子进程 / 长连接）。进程内后端无需实现。
  Future<void> dispose() async {}

  Never _unsupported(DeviceCapability c) => throw DeviceUnsupported(
        c,
        backend,
        unavailableReason ?? '该后端未实现此操作',
      );
}
