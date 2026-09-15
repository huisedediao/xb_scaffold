import 'package:flutter/material.dart';

/// 淡入/淡出容器
///
/// 通过 [XBFadeWidgetState.show] / [XBFadeWidgetState.hide] 控制显隐。
/// 动画由 AnimationController 驱动，与屏幕刷新（vsync）对齐；
/// 页面不可见时 ticker 自动暂停，不产生空转开销。
class XBFadeWidget extends StatefulWidget {
  final Widget child;

  /// 动画时长
  final int milliseconds;

  /// 是否初始就要展示
  final bool initShow;

  /// 动画帧率（保留参数以兼容旧签名；动画已改为 vsync 驱动，此参数不再生效）
  final int fps;

  /// 自动开始展示动画，默认false
  final bool autoShowAnimation;

  const XBFadeWidget(
      {required this.child,
      this.milliseconds = 200,
      this.initShow = false,
      this.fps = 30,
      this.autoShowAnimation = false,
      super.key});

  @override
  State<XBFadeWidget> createState() => XBFadeWidgetState();
}

class XBFadeWidgetState extends State<XBFadeWidget>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  /// hide 完成后的回调（淡出到 0 时触发一次）
  VoidCallback? _hided;

  @override
  void initState() {
    super.initState();
    final controller = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: widget.milliseconds),
        value: widget.initShow ? 1 : 0);
    controller.addStatusListener(_onStatusChanged);
    _controller = controller;
    if (widget.autoShowAnimation) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          show();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant XBFadeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller?.duration = Duration(milliseconds: widget.milliseconds);
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) {
      final callback = _hided;
      if (callback != null) {
        _hided = null;
        callback();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // FadeTransition 直接更新渲染层透明度，不经 setState 重建子树
    return FadeTransition(
      opacity: _controller!,
      child: widget.child,
    );
  }

  /// 淡入。重复调用安全（从当前进度继续）；
  /// 会取消尚未完成的 hide 回调（hide 后立刻 show 的场景）
  show() {
    _hided = null;
    _controller?.forward();
  }

  /// 淡出，完成后触发一次 [done]。
  /// 已完全隐藏时保持"异步触发回调"语义，不在调用栈内同步回调
  hide(VoidCallback done) {
    _hided = done;
    final controller = _controller;
    if (controller == null) return;
    if (controller.value <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_hided != done) return;
        _hided = null;
        done();
      });
      // addPostFrameCallback 不主动调度帧，静态画面下需显式调度，
      // 否则回调不可达、entry 永远无法移除
      WidgetsBinding.instance.scheduleFrame();
    } else {
      controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }
}
