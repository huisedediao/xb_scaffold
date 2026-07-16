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
    this.triggerDistance = 41,
    this.triggerVelocity = 644,
    this.maxDragOffset = 21,
    this.indicatorSize = 44,
    this.maxIndicatorHeight = 124,
    this.indicatorRevealDistance = 38,
    this.indicatorSlowdownStartProgress = 0,
    this.indicatorVerticalFollowFactor = 0.1,
    this.indicatorBulgeVerticalFollowFactor = 0.05,
    this.maxIndicatorBulgeVerticalOffset = 12,
    this.indicatorColor,
    this.iconColor = Colors.white,
    this.iconSize = 16,
  })  : assert(maxIndicatorHeight > 0, 'maxIndicatorHeight must be positive'),
        assert(
          indicatorRevealDistance > 0,
          'indicatorRevealDistance must be positive',
        ),
        assert(
          indicatorSlowdownStartProgress >= 0 &&
              indicatorSlowdownStartProgress <= 1,
          'indicatorSlowdownStartProgress must be between 0 and 1',
        ),
        assert(
          indicatorVerticalFollowFactor >= 0 &&
              indicatorVerticalFollowFactor <= 1,
          'indicatorVerticalFollowFactor must be between 0 and 1',
        ),
        assert(
          indicatorBulgeVerticalFollowFactor >= 0 &&
              indicatorBulgeVerticalFollowFactor <= 1,
          'indicatorBulgeVerticalFollowFactor must be between 0 and 1',
        ),
        assert(
          maxIndicatorBulgeVerticalOffset >= 0,
          'maxIndicatorBulgeVerticalOffset must not be negative',
        ),
        assert(
          iconSize > 0,
          'iconSize must be positive',
        );

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

  /// 边缘半透明指示区域的最大高度。
  ///
  /// 指示区域随手指向屏幕内滑动逐渐增高，达到该值后不再增高。
  final double maxIndicatorHeight;

  /// 指示区域在线性增长时从屏幕边缘完全展开所需的拖动距离。
  ///
  /// 启用减速增长后，实际完整展开距离会根据
  /// [indicatorSlowdownStartProgress] 延长。
  final double indicatorRevealDistance;

  /// 指示区域开始减速增长的展开进度，取值范围为 0 到 1。
  ///
  /// 设为 0 表示全程减速增长，设为 1 表示保持线性增长。
  final double indicatorSlowdownStartProgress;

  /// 手指纵向位移传递给指示区域的比例，取值范围为 0 到 1。
  final double indicatorVerticalFollowFactor;

  /// 手指纵向位移传递给鼓包内部位置的比例，取值范围为 0 到 1。
  final double indicatorBulgeVerticalFollowFactor;

  /// 鼓包在指示区域内部允许的最大纵向偏移。
  final double maxIndicatorBulgeVerticalOffset;
  final Color? indicatorColor;
  final Color iconColor;

  /// 返回箭头图标的尺寸。
  final double iconSize;

  @override
  State<XBIosEdgeBackGesture> createState() => _XBIosEdgeBackGestureState();
}

enum _XBIosBackEdge { left, right }

class _XBIosEdgeBackGestureState extends State<XBIosEdgeBackGesture> {
  Offset? _startPosition;
  DateTime? _startTime;
  int? _trackingPointer;
  bool _gestureTracking = false;
  bool _gestureAccepted = false;
  bool _triggeringBack = false;
  double _dragDistance = 0;
  double _verticalDragDistance = 0;
  double _indicatorCenterY = 0;
  double _contentWidth = 0;
  double _contentHeight = 0;
  _XBIosBackEdge? _activeEdge;

  bool get _effectiveEnabled {
    return widget.enabled &&
        (widget.supportLeftEdge || widget.supportRightEdge) &&
        !_triggeringBack &&
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  Widget build(BuildContext context) {
    if (!_effectiveEnabled && !_gestureTracking) {
      return widget.child;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _contentWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        _contentHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.of(context).size.height;

        return Stack(
          children: [
            Positioned.fill(child: widget.child),
            if (_effectiveEnabled || _gestureTracking)
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
                          ..contentHeight = _contentHeight
                          ..maxIndicatorHeight = widget.maxIndicatorHeight
                          ..supportLeftEdge = widget.supportLeftEdge
                          ..supportRightEdge = widget.supportRightEdge
                          ..dragStartBehavior = DragStartBehavior.down
                          ..onPointerDown = _handlePointerDown
                          ..onPointerMove = _handlePointerMove
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
            if (_gestureTracking && _activeEdge != null)
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
                        maxIndicatorHeight: widget.maxIndicatorHeight,
                        revealDistance: widget.indicatorRevealDistance,
                        slowdownStartProgress:
                            widget.indicatorSlowdownStartProgress,
                        verticalDragDistance: _verticalDragDistance,
                        bulgeVerticalFollowFactor:
                            widget.indicatorBulgeVerticalFollowFactor,
                        maxBulgeVerticalOffset:
                            widget.maxIndicatorBulgeVerticalOffset,
                        maxHeight: constraints.maxHeight,
                        indicatorColor: widget.indicatorColor,
                        iconColor: widget.iconColor,
                        iconSize: widget.iconSize,
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

  void _handlePointerDown(PointerDownEvent event) {
    if (!_effectiveEnabled ||
        _trackingPointer != null ||
        !_isIndicatorStartYAllowed(
          startY: event.localPosition.dy,
          contentHeight: _contentHeight,
          maxIndicatorHeight: widget.maxIndicatorHeight,
        )) {
      return;
    }
    final _XBIosBackEdge? edge = _resolveEdge(event.localPosition.dx);
    if (edge == null) {
      return;
    }
    _startPosition = event.localPosition;
    _startTime = DateTime.now();
    _trackingPointer = event.pointer;
    _indicatorCenterY = event.localPosition.dy;
    _activeEdge = edge;
    setState(() {
      _dragDistance = 0;
      _verticalDragDistance = 0;
      _gestureTracking = true;
      _gestureAccepted = false;
    });
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _trackingPointer) {
      return;
    }
    _updateGesturePosition(event.localPosition);
  }

  void _handleDragStart(DragStartDetails details) {
    if (!_effectiveEnabled || !_gestureTracking || _activeEdge == null) {
      return;
    }
    _gestureAccepted = true;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_gestureAccepted) {
      return;
    }
    _updateGesturePosition(details.localPosition);
  }

  void _updateGesturePosition(Offset localPosition) {
    final Offset? startPosition = _startPosition;
    final _XBIosBackEdge? edge = _activeEdge;
    if (!_gestureTracking || startPosition == null || edge == null) {
      return;
    }
    final double deltaX = localPosition.dx - startPosition.dx;
    final double distance = switch (edge) {
      _XBIosBackEdge.left => math.max(0.0, deltaX),
      _XBIosBackEdge.right => math.max(0.0, -deltaX),
    };
    final double indicatorCenterY = startPosition.dy +
        (localPosition.dy - startPosition.dy) *
            widget.indicatorVerticalFollowFactor;
    final double verticalDragDistance = localPosition.dy - startPosition.dy;
    if (_dragDistance == distance &&
        _verticalDragDistance == verticalDragDistance &&
        _indicatorCenterY == indicatorCenterY) {
      return;
    }
    setState(() {
      _dragDistance = distance;
      _verticalDragDistance = verticalDragDistance;
      _indicatorCenterY = indicatorCenterY;
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
    if (mounted &&
        (_gestureTracking || _gestureAccepted || _dragDistance > 0)) {
      setState(() {
        _gestureTracking = false;
        _gestureAccepted = false;
        _dragDistance = 0;
        _verticalDragDistance = 0;
      });
    } else {
      _gestureTracking = false;
      _gestureAccepted = false;
      _dragDistance = 0;
      _verticalDragDistance = 0;
    }
    _startPosition = null;
    _startTime = null;
    _trackingPointer = null;
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
  double contentHeight = 0;
  double maxIndicatorHeight = 0;
  bool supportLeftEdge = true;
  bool supportRightEdge = true;
  ValueChanged<PointerDownEvent>? onPointerDown;
  ValueChanged<PointerMoveEvent>? onPointerMove;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    onPointerDown?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      onPointerMove?.call(event);
    }
    super.handleEvent(event);
  }

  @override
  bool isPointerAllowed(PointerEvent event) {
    if (!super.isPointerAllowed(event)) {
      return false;
    }
    final double effectiveEdgeWidth = math.max(0.0, edgeWidth);
    final double dx = event.localPosition.dx;
    if (!_isIndicatorStartYAllowed(
      startY: event.localPosition.dy,
      contentHeight: contentHeight,
      maxIndicatorHeight: maxIndicatorHeight,
    )) {
      return false;
    }
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

bool _isIndicatorStartYAllowed({
  required double startY,
  required double contentHeight,
  required double maxIndicatorHeight,
}) {
  if (!contentHeight.isFinite || contentHeight <= 0) {
    return false;
  }
  final double effectiveIndicatorHeight = math.max(0.0, maxIndicatorHeight);
  if (effectiveIndicatorHeight > contentHeight) {
    return false;
  }
  final double halfIndicatorHeight = effectiveIndicatorHeight / 2;
  return startY >= halfIndicatorHeight &&
      startY <= contentHeight - halfIndicatorHeight;
}

class _XBIosBackIndicator extends StatelessWidget {
  const _XBIosBackIndicator({
    required this.edge,
    required this.centerY,
    required this.dragDistance,
    required this.triggerDistance,
    required this.maxDragOffset,
    required this.size,
    required this.maxIndicatorHeight,
    required this.revealDistance,
    required this.slowdownStartProgress,
    required this.verticalDragDistance,
    required this.bulgeVerticalFollowFactor,
    required this.maxBulgeVerticalOffset,
    required this.maxHeight,
    required this.indicatorColor,
    required this.iconColor,
    required this.iconSize,
  });

  final _XBIosBackEdge edge;
  final double centerY;
  final double dragDistance;
  final double triggerDistance;
  final double maxDragOffset;
  final double size;
  final double maxIndicatorHeight;
  final double revealDistance;
  final double slowdownStartProgress;
  final double verticalDragDistance;
  final double bulgeVerticalFollowFactor;
  final double maxBulgeVerticalOffset;
  final double maxHeight;
  final Color? indicatorColor;
  final Color iconColor;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final bool isLeftEdge = edge == _XBIosBackEdge.left;
    final double triggerProgress = triggerDistance <= 0
        ? 1
        : (dragDistance / triggerDistance).clamp(0.0, 1.0).toDouble();
    final double rawRevealProgress =
        revealDistance <= 0 ? 1 : math.max(0.0, dragDistance / revealDistance);
    final double growthProgress = _applyGrowthSlowdown(
      rawRevealProgress,
      slowdownStartProgress,
    );
    final double completionProgress =
        _growthCompletionProgress(slowdownStartProgress);
    final double completionDragDistance = revealDistance <= 0
        ? dragDistance
        : revealDistance * completionProgress;
    final double effectiveDragDistance =
        math.min(dragDistance, completionDragDistance);
    final double horizontalProgress = maxDragOffset <= 0
        ? 1
        : (effectiveDragDistance / maxDragOffset).clamp(0.0, 1.0).toDouble();
    final double height = maxHeight.isFinite ? maxHeight : size * 16;
    final double naturalHandleHeight = size * 3.0 + effectiveDragDistance;
    final double availableHeight = math.max(0.0, height);
    final double targetHandleHeight = math.min(
      naturalHandleHeight,
      math.min(maxIndicatorHeight, availableHeight),
    );
    final double handleHeight = targetHandleHeight * growthProgress;
    final double maxTop = math.max(0.0, height - handleHeight);
    final double top =
        (centerY - handleHeight / 2).clamp(0.0, maxTop).toDouble();
    final double localCenterY = centerY - top;
    final double effectiveMaxBulgeOffset = math.min(
      maxBulgeVerticalOffset,
      handleHeight * 0.18,
    );
    final double bulgeOffsetY =
        (verticalDragDistance * bulgeVerticalFollowFactor)
            .clamp(-effectiveMaxBulgeOffset, effectiveMaxBulgeOffset)
            .toDouble();
    final double bulgeCenterY = (localCenterY + bulgeOffsetY)
        .clamp(handleHeight * 0.2, handleHeight * 0.8)
        .toDouble();
    final double arrowSize = iconSize / 0.78;
    final double effectiveMaxWidth = math.max(0.0, maxDragOffset);
    final double baseWidth = math.min(size * 0.68, effectiveMaxWidth);
    final double targetStretchedWidth =
        baseWidth + (effectiveMaxWidth - baseWidth) * horizontalProgress;
    final double stretchedWidth = math.min(
      effectiveMaxWidth,
      targetStretchedWidth * growthProgress,
    );
    final double arrowInset = stretchedWidth * 0.5 - arrowSize / 2;
    final double maxArrowTop = math.max(0.0, handleHeight - arrowSize);
    final double arrowTop =
        (bulgeCenterY - arrowSize / 2).clamp(0.0, maxArrowTop).toDouble();
    final double targetOpacity =
        (0.32 + triggerProgress * 0.68).clamp(0.0, 1.0).toDouble();
    final double opacity = targetOpacity * growthProgress;
    final double arrowProgress =
        ((growthProgress - 0.2) / 0.8).clamp(0.0, 1.0).toDouble();
    final double targetScale = 0.9 + triggerProgress * 0.12;
    final double scale = 0.65 + arrowProgress * (targetScale - 0.65);

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
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _XBIosBackHandlePainter(
                        edge: edge,
                        bulgeCenterY: bulgeCenterY,
                        color: indicatorColor ??
                            Colors.black.withValues(alpha: 0.58),
                      ),
                    ),
                  ),
                  if (arrowProgress > 0)
                    Positioned(
                      left: isLeftEdge ? arrowInset : null,
                      right: isLeftEdge ? null : arrowInset,
                      top: arrowTop,
                      width: arrowSize,
                      height: arrowSize,
                      child: Opacity(
                        opacity: arrowProgress,
                        child: Transform.scale(
                          scale: scale,
                          child: Icon(
                            isLeftEdge
                                ? Icons.arrow_back_ios_new_rounded
                                : Icons.arrow_back_ios_new_rounded,
                            color: iconColor,
                            size: iconSize,
                          ),
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

double _applyGrowthSlowdown(double progress, double slowdownStartProgress) {
  final double effectiveProgress = math.max(0.0, progress);
  if (slowdownStartProgress >= 1) {
    return effectiveProgress.clamp(0.0, 1.0).toDouble();
  }
  if (effectiveProgress <= slowdownStartProgress) {
    return effectiveProgress;
  }
  final double tailSpan = 2 * (1 - slowdownStartProgress);
  final double tailProgress =
      ((effectiveProgress - slowdownStartProgress) / tailSpan)
          .clamp(0.0, 1.0)
          .toDouble();
  final double slowedTailProgress =
      2 * tailProgress - tailProgress * tailProgress;
  return slowdownStartProgress +
      (1 - slowdownStartProgress) * slowedTailProgress;
}

double _growthCompletionProgress(double slowdownStartProgress) {
  return slowdownStartProgress >= 1 ? 1 : 2 - slowdownStartProgress;
}

class _XBIosBackHandlePainter extends CustomPainter {
  const _XBIosBackHandlePainter({
    required this.edge,
    required this.bulgeCenterY,
    required this.color,
  });

  final _XBIosBackEdge edge;
  final double bulgeCenterY;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final double width = size.width;
    final double height = size.height;
    final double centerY = bulgeCenterY.clamp(0.0, height).toDouble();
    final double topControl1Y = centerY * 0.3;
    final double topControl2Y = centerY * 0.5;
    final double bottomHeight = height - centerY;
    final double bottomControl1Y = centerY + bottomHeight * 0.5;
    final double bottomControl2Y = centerY + bottomHeight * 0.7;

    final Path path = switch (edge) {
      _XBIosBackEdge.left => Path()
        ..moveTo(0, 0)
        ..cubicTo(
          width * 0.18,
          topControl1Y,
          width,
          topControl2Y,
          width,
          centerY,
        )
        ..cubicTo(
          width,
          bottomControl1Y,
          width * 0.18,
          bottomControl2Y,
          0,
          height,
        )
        ..close(),
      _XBIosBackEdge.right => Path()
        ..moveTo(width, 0)
        ..cubicTo(
          width * 0.82,
          topControl1Y,
          0,
          topControl2Y,
          0,
          centerY,
        )
        ..cubicTo(
          0,
          bottomControl1Y,
          width * 0.82,
          bottomControl2Y,
          width,
          height,
        )
        ..close(),
    };

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _XBIosBackHandlePainter oldDelegate) {
    return oldDelegate.edge != edge ||
        oldDelegate.bulgeCenterY != bulgeCenterY ||
        oldDelegate.color != color;
  }
}
