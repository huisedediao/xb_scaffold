/// 一次进程级采样的原始计数（所有平台实现共用）。
class XBUmeProcessUsage {
  const XBUmeProcessUsage({
    this.cpuNs,
    this.rss,
    this.footprint,
    this.pss,
    this.pssItems,
    this.cpuCores,
    this.cpuScope = 'core',
    this.platform = '',
  });

  /// 进程累计 CPU 时间（user+sys，纳秒）；平台不支持时为 null。
  final int? cpuNs;

  /// 常驻内存（字节）。
  final int? rss;

  /// phys_footprint（字节），Xcode 内存 gauge 使用的口径；Android/OHOS 为 null。
  final int? footprint;

  /// PSS（字节，共享页按进程数比例分摊），Android Studio / DevEco 的内存口径；
  /// 由 `/proc/self/smaps` 汇总，平台不允许读取时为 null。
  final int? pss;

  /// PSS 分类（官方分类名 → 字节）：Android 用 dumpsys 的 App Summary 分类，
  /// OHOS 用 DevEco Memory 泳道的内存类型。
  final Map<String, int>? pssItems;

  /// 逻辑核数，用于把进程 CPU 时间换算成「占总容量」的百分比。
  final int? cpuCores;

  /// CPU 百分比口径：`core` = 单核占满 100%（Xcode / top）；
  /// `total` = 全部核心容量合计 100%（Android Studio / DevEco Profiler）。
  final String cpuScope;

  /// `Platform.operatingSystem` 的取值（ios/macos/android/ohos/linux）。
  final String platform;
}
