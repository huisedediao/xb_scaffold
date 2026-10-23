/// 一次进程级采样的原始计数（所有平台实现共用）。
class XBUmeProcessUsage {
  const XBUmeProcessUsage({this.cpuNs, this.rss, this.footprint});

  /// 进程累计 CPU 时间（user+sys，纳秒）；平台不支持时为 null。
  final int? cpuNs;

  /// 常驻内存（字节）。
  final int? rss;

  /// phys_footprint（字节），Xcode 内存 gauge 使用的口径；Android/OHOS 为 null。
  final int? footprint;
}
