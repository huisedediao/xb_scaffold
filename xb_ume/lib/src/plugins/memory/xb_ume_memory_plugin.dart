import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/xb_process_stats.dart';
import '../../core/xb_ume_controller.dart';
import '../../core/xb_ume_plugin.dart';

/// 进程内存 / CPU / 线程数 / 系统总内存 / FPS 面板（含可拖动悬浮徽标）。
///
/// 数据全部来自 [XBUmeProcessStats]，与电脑端 GUI「性能」Tab 是同一份实现，
/// 两个入口的读数因此保持一致。内存主数字按平台取官方工具口径：
/// - iOS/macOS：`phys_footprint`（Xcode 内存 gauge）；
/// - Android/OHOS：`PSS`（Android Studio Memory Profiler 的 Total、
///   DevEco Profiler Memory 泳道），读不到 `/proc/self/smaps` 时回退 RSS。
///
/// CPU 同样是整进程口径：iOS/macOS 以单核占满为 100%（Xcode），
/// Android/OHOS 以全部核心容量合计为 100%（Android Studio / DevEco Profiler）。
class XBUmeMemoryPlugin extends XBUmePlugin {
  @override
  String get id => 'memory';

  @override
  String get title => 'Memory';

  @override
  IconData get icon => Icons.memory;

  /// 悬浮徽标开关：面板里的 Switch 监听它，徽标自身不复位状态。
  static final ValueNotifier<bool> floatingEnabled =
      ValueNotifier<bool>(false);

  /// 徽标挂到宿主根 Overlay 上：面板关闭后仍然每秒刷新，直到开关关闭。
  static OverlayEntry? _badgeEntry;

  /// 开关入口（只能从面板里点，因此一定有可用的 context / controller）。
  static void setFloating(
    bool enable, {
    required BuildContext context,
    required XBUmeController controller,
  }) {
    if (!enable) {
      hideFloatingBadge();
      return;
    }
    if (_badgeEntry != null) {
      floatingEnabled.value = true;
      return;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      // 找不到 Overlay（宿主已拆掉）时保持开关与事实一致，不假装已打开。
      floatingEnabled.value = false;
      return;
    }
    floatingEnabled.value = true;
    _badgeEntry =
        OverlayEntry(builder: (_) => _FloatingMemoryBadge(controller: controller));
    overlay.insert(_badgeEntry!);
  }

  static void hideFloatingBadge() {
    floatingEnabled.value = false;
    _badgeEntry?.remove();
    _badgeEntry = null;
  }

  @override
  void onUnregister(XBUmeController controller) {
    hideFloatingBadge();
    super.onUnregister(controller);
  }

  @override
  Widget buildPanel(BuildContext context, XBUmeController controller) {
    return _MemoryPanel(controller: controller);
  }
}

/// 采样帧数窗口：与官方工具一样按「最近若干帧」平均，避免历史帧把瞬时值拉平。
const int _kFpsWindow = 60;

/// FPS 取最近 [_kFpsWindow] 帧的 totalSpan 平均；无帧时返回 0。
double _fpsOf(XBUmeController controller) {
  final frames = controller.frames;
  if (frames.isEmpty) return 0;
  final start = frames.length > _kFpsWindow ? frames.length - _kFpsWindow : 0;
  var sum = 0.0;
  var count = 0;
  for (var i = start; i < frames.length; i++) {
    sum += frames[i].totalMs;
    count += 1;
  }
  if (count == 0 || sum <= 0) return 0;
  return count * 1000 / sum;
}

/// 主数字口径的显示名：与官方工具的栏目名对齐，便于对照。
String _memoryScopeLabel(String scope) {
  switch (scope) {
    case 'pss':
      return 'PSS';
    case 'footprint':
      return 'Footprint';
    case 'rss':
      return 'RSS';
    default:
      return 'Footprint';
  }
}

/// 一次采样的结果（面板与徽标共用）。
class _MemorySample {
  const _MemorySample({
    this.primary,
    this.scope = '',
    this.rss,
    this.footprint,
    this.cpu = -1,
    this.threads,
    this.totalMemory,
    this.fps = 0,
  });

  final int? primary;
  final String scope;
  final int? rss;
  final int? footprint;
  final double cpu;
  final int? threads;
  final int? totalMemory;
  final double fps;
}

_MemorySample _sampleOf(XBUmeController controller) {
  final raw = XBUmeProcessStats.sample();
  int? asInt(Object? value) => value is num ? value.toInt() : null;
  double asDouble(Object? value) => value is num ? value.toDouble() : -1;
  return _MemorySample(
    primary: asInt(raw['primaryMemory']),
    scope: raw['memoryScope'] is String ? raw['memoryScope'] as String : '',
    rss: asInt(raw['rss']),
    footprint: asInt(raw['footprint']),
    cpu: asDouble(raw['cpuPercent']),
    threads: asInt(raw['threads']),
    totalMemory: asInt(raw['totalMemory']),
    fps: _fpsOf(controller),
  );
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

class _MemoryPanel extends StatefulWidget {
  const _MemoryPanel({required this.controller});

  final XBUmeController controller;

  @override
  State<_MemoryPanel> createState() => _MemoryPanelState();
}

class _MemoryPanelState extends State<_MemoryPanel> {
  static const int _maxHistoryCount = 20;

  Timer? _timer;
  _MemorySample _sample = const _MemorySample();
  int _tick = 0;
  final List<int> _history = [];

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    final sample = _sampleOf(widget.controller);
    setState(() {
      _sample = sample;
      _tick += 1;
      final primary = sample.primary;
      _history.add(primary ?? -1);
      if (_history.length > _maxHistoryCount) {
        _history.removeAt(0);
      }
    });
  }

  String _formatMb(int? bytes) {
    if (bytes == null || bytes <= 0) return '获取失败(平台不支持)';
    return _mb(bytes);
  }

  Widget _chip(String key, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.black.withValues(alpha: 0.04),
      ),
      child: Text(
        '$key: $value',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sample = _sample;
    final rows = <MapEntry<String, String>>[
      MapEntry<String, String>(
          'Current Memory (${_memoryScopeLabel(sample.scope)})',
          '${_formatMb(sample.primary)} (${sample.primary ?? -1} B)'),
      MapEntry<String, String>(
          'Current RSS', '${_formatMb(sample.rss)} (${sample.rss ?? -1} B)'),
      MapEntry<String, String>('Sample Count', '$_tick'),
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              const Text(
                'App Memory Monitor (1s refresh)',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              OutlinedButton(
                onPressed: _refresh,
                child: const Text('Refresh'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip('CPU',
                  sample.cpu > 0 ? '${sample.cpu.toStringAsFixed(1)}%' : 'N/A'),
              _chip('FPS',
                  sample.fps > 0 ? sample.fps.toStringAsFixed(1) : 'N/A'),
              _chip('Threads', sample.threads?.toString() ?? 'N/A'),
              _chip(
                'Footprint',
                sample.footprint != null && sample.footprint! > 0
                    ? _mb(sample.footprint!)
                    : 'N/A',
              ),
              _chip(
                'Total Mem',
                sample.totalMemory != null
                    ? '${(sample.totalMemory! / (1024 * 1024)).toStringAsFixed(0)} MB'
                    : 'N/A',
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        ValueListenableBuilder<bool>(
          valueListenable: XBUmeMemoryPlugin.floatingEnabled,
          builder: (context, enabled, _) {
            return SwitchListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              title: const Text(
                'Floating memory badge',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              value: enabled,
              onChanged: (value) => XBUmeMemoryPlugin.setFloating(
                value,
                context: context,
                controller: widget.controller,
              ),
            );
          },
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length + 1,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              if (index < rows.length) {
                final row = rows[index];
                return ListTile(
                  dense: true,
                  title: Text(
                    row.key,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  subtitle: SelectableText(
                    row.value,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF111827),
                    ),
                  ),
                );
              }
              // 最后一行：历史采样列表
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'History (last 20 samples)',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    if (_history.isEmpty)
                      const Text('No samples', style: TextStyle(fontSize: 12))
                    else
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final bytes in _history.reversed)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color: bytes <= 0
                                    ? Colors.grey.shade300
                                    : Colors.black.withValues(alpha: 0.04),
                              ),
                              child: Text(
                                bytes <= 0
                                    ? 'N/A'
                                    : (bytes / (1024 * 1024))
                                        .toStringAsFixed(1),
                                style: const TextStyle(
                                    fontSize: 11, fontWeight: FontWeight.w600),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FloatingMemoryBadge extends StatefulWidget {
  const _FloatingMemoryBadge({required this.controller});

  final XBUmeController controller;

  @override
  State<_FloatingMemoryBadge> createState() => _FloatingMemoryBadgeState();
}

class _FloatingMemoryBadgeState extends State<_FloatingMemoryBadge> {
  static const double _badgeWidth = 170;
  static const double _badgeHeight = 132;

  Timer? _timer;
  _MemorySample _sample = const _MemorySample();
  // 基准位置 + 拖动增量：拖动中仅改 RenderTransform 矩阵（paint-only，跟手），
  // 松手后合并到基准位置。
  Offset _pos = Offset.zero;
  Offset _dragDelta = Offset.zero;
  final GlobalKey _transformKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    final sample = _sampleOf(widget.controller);
    setState(() {
      _sample = sample;
    });
  }

  Offset _clamp(Offset target, Size size) {
    return Offset(
      target.dx.clamp(0.0, (size.width - _badgeWidth).clamp(0.0, size.width)),
      target.dy
          .clamp(0.0, (size.height - _badgeHeight).clamp(0.0, size.height)),
    );
  }

  String _mbOrDash(int? bytes) => bytes != null && bytes > 0 ? _mb(bytes) : '--';

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // 默认右上角，拖动后可停靠任意位置
    final base =
        _pos == Offset.zero ? Offset(size.width - _badgeWidth - 16, 90) : _pos;
    final clamped = _clamp(base, size);

    final sample = _sample;
    return Positioned(
      left: clamped.dx,
      top: clamped.dy,
      child: Transform(
        key: _transformKey,
        transform: Matrix4.translationValues(_dragDelta.dx, _dragDelta.dy, 0),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            _dragDelta = Offset.zero;
          },
          onPanUpdate: (details) {
            _dragDelta += details.delta;
            final next = _clamp(clamped + _dragDelta, size);
            final renderTransform =
                _transformKey.currentContext?.findRenderObject()
                    as RenderTransform?;
            if (renderTransform != null) {
              renderTransform.transform = Matrix4.translationValues(
                next.dx - clamped.dx,
                next.dy - clamped.dy,
                0,
              );
            }
          },
          onPanEnd: (_) {
            setState(() {
              _pos = _clamp(clamped + _dragDelta, size);
              _dragDelta = Offset.zero;
            });
          },
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: _badgeWidth,
              height: _badgeHeight,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24, width: 0.8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row('Mem', _mbOrDash(sample.primary)),
                  _row('RSS', _mbOrDash(sample.rss)),
                  _row('CPU',
                      sample.cpu > 0 ? '${sample.cpu.toStringAsFixed(1)}%' : 'N/A'),
                  _row('FPS',
                      sample.fps > 0 ? sample.fps.toStringAsFixed(1) : 'N/A'),
                  _row('Threads', sample.threads?.toString() ?? 'N/A'),
                  _row(
                    'Sys Mem',
                    sample.totalMemory != null
                        ? '${(sample.totalMemory! / (1024 * 1024)).toStringAsFixed(0)} MB'
                        : 'N/A',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
          // 窄屏 / 大字体下不让长数值把 Row 撑破，宁可按省略号截断。
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
