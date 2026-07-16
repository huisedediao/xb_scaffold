import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// 构建一个无内置边缘返回手势的 PageRoute。
///
/// Flutter 在 iOS 上会为 MaterialPageRoute 自动添加
/// CupertinoPageTransitionsBuilder，其中内置了边缘滑动返回手势，
/// 与 XBIosEdgeBackGesture 的 RawGestureDetector 在竞技场中冲突。
/// 使用 PageRouteBuilder 替代，只保留了从右向左的滑入动画，
/// 不添加任何手势，让 XBIosEdgeBackGesture 独占边缘手势处理。
PageRouteBuilder<void> _testPageRoute(Widget page) {
  return PageRouteBuilder(
    pageBuilder: (_, __, ___) => page,
    transitionDuration: const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 300),
    transitionsBuilder: (_, animation, __, child) {
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1.0, 0.0),
          end: Offset.zero,
        ).animate(CurvedAnimation(
          parent: animation,
          curve: Curves.easeOut,
        )),
        child: child,
      );
    },
  );
}

class XBIosEdgeBackTestPage extends StatefulWidget {
  const XBIosEdgeBackTestPage({super.key});

  @override
  State<XBIosEdgeBackTestPage> createState() => _XBIosEdgeBackTestPageState();
}

class _XBIosEdgeBackTestPageState extends State<XBIosEdgeBackTestPage> {
  bool _globalEnabled = true;
  bool _enabled = true;
  bool _supportLeftEdge = true;
  bool _supportRightEdge = true;
  double _edgeWidth = 32;
  double _triggerDistance = 25;
  double _triggerVelocity = 644;
  double _maxDragOffset = 25;
  double _maxIndicatorHeight = 124;
  double _indicatorRevealDistance = 46;
  double _indicatorSlowdownStartProgress = 0;
  double _iconSize = 16;

  @override
  void initState() {
    super.initState();
    XBIosEdgeBackGesture.globalEnabled.value = _globalEnabled;
  }

  @override
  Widget build(BuildContext context) {
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;

    return Scaffold(
      appBar: AppBar(title: const Text('XBIosEdgeBackGesture 测试')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!isIOS)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade300),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: Colors.orange.shade700),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '此手势仅在 iOS 平台生效，当前平台无法测试实际手势效果。'
                      '请使用 iOS 模拟器或真机运行。',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          _sectionTitle('全局开关'),
          SwitchListTile(
            title: const Text('globalEnabled'),
            subtitle: const Text('关闭后所有页面的手势失效'),
            value: _globalEnabled,
            onChanged: (v) {
              setState(() {
                _globalEnabled = v;
                XBIosEdgeBackGesture.globalEnabled.value = v;
              });
            },
          ),
          const Divider(),
          _sectionTitle('手势配置'),
          SwitchListTile(
            title: const Text('enabled'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          SwitchListTile(
            title: const Text('supportLeftEdge'),
            value: _supportLeftEdge,
            onChanged: (v) => setState(() => _supportLeftEdge = v),
          ),
          SwitchListTile(
            title: const Text('supportRightEdge'),
            value: _supportRightEdge,
            onChanged: (v) => setState(() => _supportRightEdge = v),
          ),
          const SizedBox(height: 16),
          _sectionTitle('参数调节'),
          _sliderRow('edgeWidth', _edgeWidth, 8, 80,
              (v) => setState(() => _edgeWidth = v)),
          _sliderRow('triggerDistance', _triggerDistance, 20, 200,
              (v) => setState(() => _triggerDistance = v)),
          _sliderRow('triggerVelocity', _triggerVelocity, 100, 2000,
              (v) => setState(() => _triggerVelocity = v)),
          _sliderRow('maxDragOffset', _maxDragOffset, 20, 200,
              (v) => setState(() => _maxDragOffset = v)),
          _sliderRow('maxIndicatorHeight', _maxIndicatorHeight, 80, 400,
              (v) => setState(() => _maxIndicatorHeight = v)),
          _sliderRow('indicatorRevealDistance', _indicatorRevealDistance, 10,
              120, (v) => setState(() => _indicatorRevealDistance = v)),
          _sliderRow(
            'slowdownStartProgress',
            _indicatorSlowdownStartProgress,
            0,
            1,
            (v) => setState(() => _indicatorSlowdownStartProgress = v),
            valueLabelBuilder: (v) => '${(v * 100).round()}%',
          ),
          _sliderRow('iconSize', _iconSize, 12, 36,
              (v) => setState(() => _iconSize = v)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _pushTestPage,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('进入测试子页面，滑动屏幕边缘返回'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _pushLongContentPage,
            icon: const Icon(Icons.list),
            label: const Text('进入长列表子页面（测试滚动冲突）'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: _pushDeepPage,
            icon: const Icon(Icons.layers),
            label: const Text('进入多层嵌套页面'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
    );
  }

  Widget _sliderRow(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    String Function(double)? valueLabelBuilder,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(width: 140, child: Text(label)),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
              width: 50,
              child: Text(
                valueLabelBuilder?.call(value) ?? value.toStringAsFixed(0),
                textAlign: TextAlign.right,
              )),
        ],
      ),
    );
  }

  void _pushTestRoute(Widget page) {
    Navigator.of(context).push(_testPageRoute(page));
  }

  void _pushTestPage() {
    _pushTestRoute(_BackSubPage(
      enabled: _enabled,
      supportLeftEdge: _supportLeftEdge,
      supportRightEdge: _supportRightEdge,
      edgeWidth: _edgeWidth,
      triggerDistance: _triggerDistance,
      triggerVelocity: _triggerVelocity,
      maxDragOffset: _maxDragOffset,
      maxIndicatorHeight: _maxIndicatorHeight,
      indicatorRevealDistance: _indicatorRevealDistance,
      indicatorSlowdownStartProgress: _indicatorSlowdownStartProgress,
      iconSize: _iconSize,
      depth: 1,
    ));
  }

  void _pushLongContentPage() {
    _pushTestRoute(_LongListSubPage(
      enabled: _enabled,
      supportLeftEdge: _supportLeftEdge,
      supportRightEdge: _supportRightEdge,
      edgeWidth: _edgeWidth,
      triggerDistance: _triggerDistance,
      triggerVelocity: _triggerVelocity,
      maxDragOffset: _maxDragOffset,
      maxIndicatorHeight: _maxIndicatorHeight,
      indicatorRevealDistance: _indicatorRevealDistance,
      indicatorSlowdownStartProgress: _indicatorSlowdownStartProgress,
      iconSize: _iconSize,
    ));
  }

  void _pushDeepPage() {
    _pushTestRoute(_BackSubPage(
      enabled: _enabled,
      supportLeftEdge: _supportLeftEdge,
      supportRightEdge: _supportRightEdge,
      edgeWidth: _edgeWidth,
      triggerDistance: _triggerDistance,
      triggerVelocity: _triggerVelocity,
      maxDragOffset: _maxDragOffset,
      maxIndicatorHeight: _maxIndicatorHeight,
      indicatorRevealDistance: _indicatorRevealDistance,
      indicatorSlowdownStartProgress: _indicatorSlowdownStartProgress,
      iconSize: _iconSize,
      depth: 3,
    ));
  }
}

/// 普通子页面（支持多层嵌套）
class _BackSubPage extends StatelessWidget {
  const _BackSubPage({
    required this.enabled,
    required this.supportLeftEdge,
    required this.supportRightEdge,
    required this.edgeWidth,
    required this.triggerDistance,
    required this.triggerVelocity,
    required this.maxDragOffset,
    required this.maxIndicatorHeight,
    required this.indicatorRevealDistance,
    required this.indicatorSlowdownStartProgress,
    required this.iconSize,
    required this.depth,
  });

  final bool enabled;
  final bool supportLeftEdge;
  final bool supportRightEdge;
  final double edgeWidth;
  final double triggerDistance;
  final double triggerVelocity;
  final double maxDragOffset;
  final double maxIndicatorHeight;
  final double indicatorRevealDistance;
  final double indicatorSlowdownStartProgress;
  final double iconSize;
  final int depth;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: XBIosEdgeBackGesture(
        enabled: enabled,
        supportLeftEdge: supportLeftEdge,
        supportRightEdge: supportRightEdge,
        edgeWidth: edgeWidth,
        triggerDistance: triggerDistance,
        triggerVelocity: triggerVelocity,
        maxDragOffset: maxDragOffset,
        maxIndicatorHeight: maxIndicatorHeight,
        indicatorRevealDistance: indicatorRevealDistance,
        indicatorSlowdownStartProgress: indicatorSlowdownStartProgress,
        iconSize: iconSize,
        onBack: () => Navigator.of(context).maybePop(),
        child: _buildContent(context),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final colors = [Colors.blue, Colors.green, Colors.orange, Colors.red];
    final color = colors[(depth - 1) % colors.length];

    return Scaffold(
      appBar: AppBar(
        title: Text('子页面 (深度: $depth)'),
        backgroundColor: color,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              depth > 1
                  ? Icons.arrow_back_ios_new_rounded
                  : Icons.swipe_rounded,
              size: 64,
              color: color,
            ),
            const SizedBox(height: 16),
            Text(
              depth > 1 ? '从屏幕边缘右滑返回上一层' : '从屏幕左边缘右滑 / 右边缘左滑返回',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              '当前深度: $depth',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
            ),
            if (depth > 1) ...[
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    _testPageRoute(_BackSubPage(
                      enabled: enabled,
                      supportLeftEdge: supportLeftEdge,
                      supportRightEdge: supportRightEdge,
                      edgeWidth: edgeWidth,
                      triggerDistance: triggerDistance,
                      triggerVelocity: triggerVelocity,
                      maxDragOffset: maxDragOffset,
                      maxIndicatorHeight: maxIndicatorHeight,
                      indicatorRevealDistance: indicatorRevealDistance,
                      indicatorSlowdownStartProgress:
                          indicatorSlowdownStartProgress,
                      iconSize: iconSize,
                      depth: depth - 1,
                    )),
                  );
                },
                child: Text('再推一层 (深度 ${depth - 1})'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 长列表子页面（测试与 ScrollView 的滑动冲突）
class _LongListSubPage extends StatelessWidget {
  const _LongListSubPage({
    required this.enabled,
    required this.supportLeftEdge,
    required this.supportRightEdge,
    required this.edgeWidth,
    required this.triggerDistance,
    required this.triggerVelocity,
    required this.maxDragOffset,
    required this.maxIndicatorHeight,
    required this.indicatorRevealDistance,
    required this.indicatorSlowdownStartProgress,
    required this.iconSize,
  });

  final bool enabled;
  final bool supportLeftEdge;
  final bool supportRightEdge;
  final double edgeWidth;
  final double triggerDistance;
  final double triggerVelocity;
  final double maxDragOffset;
  final double maxIndicatorHeight;
  final double indicatorRevealDistance;
  final double indicatorSlowdownStartProgress;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: XBIosEdgeBackGesture(
        enabled: enabled,
        supportLeftEdge: supportLeftEdge,
        supportRightEdge: supportRightEdge,
        edgeWidth: edgeWidth,
        triggerDistance: triggerDistance,
        triggerVelocity: triggerVelocity,
        maxDragOffset: maxDragOffset,
        maxIndicatorHeight: maxIndicatorHeight,
        indicatorRevealDistance: indicatorRevealDistance,
        indicatorSlowdownStartProgress: indicatorSlowdownStartProgress,
        iconSize: iconSize,
        onBack: () => Navigator.of(context).maybePop(),
        child: Scaffold(
          appBar: AppBar(
            title: const Text('长列表页面 (测试滚动冲突)'),
            backgroundColor: Colors.teal,
            foregroundColor: Colors.white,
          ),
          body: ListView.builder(
            itemCount: 50,
            itemBuilder: (context, index) {
              return ListTile(
                leading: CircleAvatar(child: Text('${index + 1}')),
                title: Text('列表项 ${index + 1}'),
                subtitle: const Text('从屏幕边缘滑动返回，非边缘区域正常滚动'),
              );
            },
          ),
        ),
      ),
    );
  }
}
