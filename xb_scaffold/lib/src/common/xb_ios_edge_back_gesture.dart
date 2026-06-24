import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

typedef XBIosEdgeBackCallback = FutureOr<void> Function();

/// iOS 边缘自定义返回手势。
///
/// 该组件只负责识别屏幕边缘滑动并显示返回箭头，真正的返回业务由 [onBack] 提供。
/// 不在组件内部调用 Navigator.pop，避免绕过页面已有的保存、清理、返回值传递逻辑。
///
/// [globalEnabled] 控制全局开关，设为 false 可关闭所有页面的自定义手势。
class XBIosEdgeBackGesture extends StatefulWidget {
  /// 全局开关，默认开启。设为 false 关闭所有页面的自定义 iOS 返回手势。
  static final ValueNotifier<bool> globalEnabled = ValueNotifier(true);

  const XBIosEdgeBackGesture({
    super.key,
    required this.child,
    required this.onBack,
    this.enabled = true,
    this.supportLeftEdge = true,
    this.supportRightEdge = true,
    this.edgeWidth = 32,
    this.triggerDistance = 56,
    this.triggerVelocity = 700,
    this.maxDragOffset = 40,
    this.indicatorSize = 44,
    this.indicatorColor,
    this.iconColor = Colors.white,
  });

  final Widget child;
  final XBIosEdgeBackCallback onBack;
  final bool enabled;
  final bool supportLeftEdge;
  final bool supportRightEdge;
  final double edgeWidth;
  final double triggerDistance;
  final double triggerVelocity;
  final double maxDragOffset;
  final double indicatorSize;
  final Color? indicatorColor;
  final Color iconColor;

  @override
  State<XBIosEdgeBackGesture> createState() => _XBIosEdgeBackGestureState();
}

enum _XBIosBackEdge { left, right }

class _XBIosEdgeBackGestureState extends State<XBIosEdgeBackGesture> {
  Offset? _startPosition;
  DateTime? _startTime;
  bool _gestureAccepted = false;
  bool _triggeringBack = false;
  double _dragDistance = 0;
  double _indicatorCenterY = 0;
  double _contentWidth = 0;
  _XBIosBackEdge? _activeEdge;

  bool get _effectiveEnabled {
    return widget.enabled &&
        (widget.supportLeftEdge || widget.supportRightEdge) &&
        !_triggeringBack &&
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  Widget build(BuildContext context) {
    if (!_effectiveEnabled && !_gestureAccepted) {
      return widget.child;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _contentWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;

        return Stack(
          children: [
            Positioned.fill(child: widget.child),
            if (_effectiveEnabled || _gestureAccepted)
              Positioned.fill(
                child: RawGestureDetector(
                  behavior: HitTestBehavior.translucent,
                  gestures: {
                    _XBIosEdgeHorizontalDragGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                            _XBIosEdgeHorizontalDragGestureRecognizer>(
                      () => _XBIosEdgeHorizontalDragGestureRecognizer(
                        debugOwner: this,
                      ),
                      (_XBIosEdgeHorizontalDragGestureRecognizer instance) {
                        instance
                          ..edgeWidth = widget.edgeWidth
                          ..contentWidth = _contentWidth
                          ..supportLeftEdge = widget.supportLeftEdge
                          ..supportRightEdge = widget.supportRightEdge
                          ..dragStartBehavior = DragStartBehavior.down
                          ..onStart = _handleDragStart
                          ..onUpdate = _handleDragUpdate
                          ..onEnd = _handleDragEnd
                          ..onCancel = _handleDragCancel;
                      },
                    ),
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            if (_gestureAccepted && _activeEdge != null)
              Positioned.fill(
                child: AbsorbPointer(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return _XBIosBackIndicator(
                        edge: _activeEdge!,
                        centerY: _indicatorCenterY,
                        dragDistance: _dragDistance,
                        triggerDistance: widget.triggerDistance,
                        maxDragOffset: widget.maxDragOffset,
                        size: widget.indicatorSize,
                        maxHeight: constraints.maxHeight,
                        indicatorColor: widget.indicatorColor,
                        iconColor: widget.iconColor,
                      );
                    },
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _handleDragStart(DragStartDetails details) {
    if (!_effectiveEnabled) {
      return;
    }
    final _XBIosBackEdge? edge = _resolveEdge(details.localPosition.dx);
    if (edge == null) {
      return;
    }
    _startPosition = details.localPosition;
    _startTime = DateTime.now();
    _indicatorCenterY = details.localPosition.dy;
    _activeEdge = edge;
    setState(() {
      _dragDistance = 0;
      _gestureAccepted = true;
    });
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final _XBIosBackEdge? edge = _activeEdge;
    if (!_gestureAccepted || _startPosition == null || edge == null) {
      return;
    }
    final double deltaX = details.localPosition.dx - _startPosition!.dx;
    final double distance = switch (edge) {
      _XBIosBackEdge.left => math.max(0.0, deltaX),
      _XBIosBackEdge.right => math.max(0.0, -deltaX),
    };
    setState(() {
      _dragDistance = distance;
      _indicatorCenterY = details.localPosition.dy;
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    final DateTime? startTime = _startTime;
    final bool accepted = _gestureAccepted;
    final double dragDistance = _dragDistance;
    final _XBIosBackEdge? edge = _activeEdge;
    _resetGesture();

    if (!accepted || startTime == null || edge == null) {
      return;
    }

    final int elapsedMs =
        math.max(1, DateTime.now().difference(startTime).inMilliseconds);
    final double fallbackVelocity = dragDistance / elapsedMs * 1000;
    final double inwardVelocity = switch (edge) {
      _XBIosBackEdge.left => details.primaryVelocity ?? fallbackVelocity,
      _XBIosBackEdge.right => details.primaryVelocity == null
          ? fallbackVelocity
          : -details.primaryVelocity!,
    };
    final double velocity = math.max(0.0, inwardVelocity);
    final bool shouldBack = dragDistance >= widget.triggerDistance ||
        velocity >= widget.triggerVelocity;

    if (shouldBack) {
      unawaited(_triggerBack());
    }
  }

  void _handleDragCancel() {
    _resetGesture();
  }

  void _resetGesture() {
    if (mounted && (_gestureAccepted || _dragDistance > 0)) {
      setState(() {
        _gestureAccepted = false;
        _dragDistance = 0;
      });
    } else {
      _gestureAccepted = false;
      _dragDistance = 0;
    }
    _startPosition = null;
    _startTime = null;
    _activeEdge = null;
  }

  _XBIosBackEdge? _resolveEdge(double dx) {
    final double edgeWidth = math.max(0.0, widget.edgeWidth);
    if (widget.supportLeftEdge && dx <= edgeWidth) {
      return _XBIosBackEdge.left;
    }
    if (widget.supportRightEdge &&
        _contentWidth > 0 &&
        dx >= _contentWidth - edgeWidth) {
      return _XBIosBackEdge.right;
    }
    return null;
  }

  Future<void> _triggerBack() async {
    if (_triggeringBack) {
      return;
    }
    if (mounted) {
      setState(() {
        _triggeringBack = true;
      });
    } else {
      _triggeringBack = true;
    }

    try {
      await Future<void>.sync(widget.onBack);
    } finally {
      if (mounted) {
        setState(() {
          _triggeringBack = false;
        });
      } else {
        _triggeringBack = false;
      }
    }
  }
}

class _XBIosEdgeHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  _XBIosEdgeHorizontalDragGestureRecognizer({super.debugOwner});

  double edgeWidth = 32;
  double contentWidth = 0;
  bool supportLeftEdge = true;
  bool supportRightEdge = true;

  @override
  bool isPointerAllowed(PointerEvent event) {
    if (!super.isPointerAllowed(event)) {
      return false;
    }
    final double effectiveEdgeWidth = math.max(0.0, edgeWidth);
    final double dx = event.localPosition.dx;
    if (supportLeftEdge && dx <= effectiveEdgeWidth) {
      return true;
    }
    if (supportRightEdge &&
        contentWidth > 0 &&
        dx >= contentWidth - effectiveEdgeWidth) {
      return true;
    }
    return false;
  }
}

class _XBIosBackIndicator extends StatelessWidget {
  const _XBIosBackIndicator({
    required this.edge,
    required this.centerY,
    required this.dragDistance,
    required this.triggerDistance,
    required this.maxDragOffset,
    required this.size,
    required this.maxHeight,
    required this.indicatorColor,
    required this.iconColor,
  });

  final _XBIosBackEdge edge;
  final double centerY;
  final double dragDistance;
  final double triggerDistance;
  final double maxDragOffset;
  final double size;
  final double maxHeight;
  final Color? indicatorColor;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final bool isLeftEdge = edge == _XBIosBackEdge.left;
    final double progress = triggerDistance <= 0
        ? 1
        : (dragDistance / triggerDistance).clamp(0.0, 1.0).toDouble();
    final double horizontalProgress = maxDragOffset <= 0
        ? 1
        : (dragDistance / maxDragOffset).clamp(0.0, 1.0).toDouble();
    final double height = maxHeight.isFinite ? maxHeight : size * 16;
    final double handleHeight = size * 3.0 + dragDistance;
    final double handleWidth = size * (0.68 + horizontalProgress * 0.28);
    final double maxTop = math.max(0.0, height - handleHeight);
    final double top =
        (centerY - handleHeight / 2).clamp(0.0, maxTop).toDouble();
    final double localCenterY = centerY - top;
    final double arrowSize = size * 0.72;
    final double stretchedWidth =
        handleWidth + horizontalProgress * (maxDragOffset - handleWidth);
    final double arrowInset =
        stretchedWidth * 0.5 - arrowSize / 2;
    final double arrowTop = (localCenterY - arrowSize / 2)
        .clamp(0.0, handleHeight - arrowSize)
        .toDouble();
    final double opacity = (0.32 + progress * 0.68).clamp(0.0, 1.0).toDouble();
    final double scale = 0.9 + progress * 0.12;

    return SizedBox.expand(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: isLeftEdge ? 0 : null,
            right: isLeftEdge ? null : 0,
            top: top,
            width: stretchedWidth,
            height: handleHeight,
            child: Opacity(
              opacity: opacity,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _XBIosBackHandlePainter(
                        edge: edge,
                        color: indicatorColor ??
                            Colors.black.withValues(alpha: 0.58),
                      ),
                    ),
                  ),
                  Positioned(
                    left: isLeftEdge ? arrowInset : null,
                    right: isLeftEdge ? null : arrowInset,
                    top: arrowTop,
                    width: arrowSize,
                    height: arrowSize,
                    child: Transform.scale(
                      scale: scale,
                      child: Icon(
                        isLeftEdge
                            ? Icons.arrow_back_ios_new_rounded
                            : Icons.arrow_back_ios_new_rounded,
                        color: iconColor,
                        size: arrowSize * 0.78,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _XBIosBackHandlePainter extends CustomPainter {
  const _XBIosBackHandlePainter({
    required this.edge,
    required this.color,
  });

  final _XBIosBackEdge edge;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final double width = size.width;
    final double height = size.height;
    final double centerY = height / 2;

    final Path path = switch (edge) {
      _XBIosBackEdge.left => Path()
        ..moveTo(0, 0)
        ..cubicTo(
          width * 0.18,
          height * 0.15,
          width,
          height * 0.25,
          width,
          centerY,
        )
        ..cubicTo(
          width,
          height * 0.75,
          width * 0.18,
          height * 0.85,
          0,
          height,
        )
        ..close(),
      _XBIosBackEdge.right => Path()
        ..moveTo(width, 0)
        ..cubicTo(
          width * 0.82,
          height * 0.15,
          0,
          height * 0.25,
          0,
          centerY,
        )
        ..cubicTo(
          0,
          height * 0.75,
          width * 0.82,
          height * 0.85,
          width,
          height,
        )
        ..close(),
    };

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _XBIosBackHandlePainter oldDelegate) {
    return oldDelegate.edge != edge || oldDelegate.color != color;
  }
}
