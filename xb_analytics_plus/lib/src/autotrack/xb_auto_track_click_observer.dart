import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../core/xb_track_manager.dart';
import 'xb_auto_track_config.dart';
import 'xb_auto_track_element_resolver.dart';

/// 根级点击采集器：包裹在应用最外层，把所有点击产出为 auto_click 事件。
///
/// 用法：
/// ```dart
/// runApp(XBAutoTrackListener(child: MyApp()));
/// ```
///
/// 原理：根 [Listener]（translucent）不拦截、不消费任何手势，只在指针抬起时
/// 对抬起坐标重新做一次 hitTest，再经 [XBChainFingerprinter] 反查 Element
/// 构建语义指纹，走 [XBTrackManager] 既有管道分发到各 sink。
class XBAutoTrackListener extends StatefulWidget {
  const XBAutoTrackListener({
    super.key,
    required this.child,
    this.config = const XBAutoTrackConfig(),
  });

  final Widget child;
  final XBAutoTrackConfig config;

  @override
  State<XBAutoTrackListener> createState() => _XBAutoTrackListenerState();
}

class _XBAutoTrackListenerState extends State<XBAutoTrackListener> {
  late XBChainFingerprinter _fingerprinter;

  @override
  void initState() {
    super.initState();
    _fingerprinter = XBChainFingerprinter(config: widget.config);
  }

  @override
  void didUpdateWidget(covariant XBAutoTrackListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config) {
      _fingerprinter.config = widget.config;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    final config = widget.config;
    if (!config.enabled) return;
    try {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
      final fingerprint = _fingerprinter.fingerprintFrom(result);
      if (fingerprint == null) return;
      XBTrackManager.shared.track(
        config.eventName,
        params: fingerprint.toParams(),
        pageName: fingerprint.routeName,
      );
    } catch (_) {
      // 采集异常绝不影响业务交互，静默降级。
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerUp: _handlePointerUp,
      child: widget.child,
    );
  }
}
