import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../core/xb_ume_controller.dart';
import '../core/xb_ume_notice_service.dart';
import '../core/xb_ume_widget_locator_resolver.dart';
import '../core/xb_ume_widget_pick_service.dart';
import 'xb_ume_panel.dart';
import 'xb_ume_theme.dart';

class XBUmeHost extends StatefulWidget {
  const XBUmeHost({
    super.key,
    required this.child,
    required this.controller,
  });

  final Widget child;
  final XBUmeController controller;

  @override
  State<XBUmeHost> createState() => _XbUmeHostState();
}

class _XbUmeHostState extends State<XBUmeHost> {
  late Offset _offset;
  bool _panelVisible = false;

  final GlobalKey _appRootKey = GlobalKey(debugLabel: 'xb_ume_app_root');
  final XBUmeWidgetPickService _pickService = XBUmeWidgetPickService.instance;
  final XBUmeNoticeService _noticeService = XBUmeNoticeService.instance;
  final XBUmeWidgetLocatorResolver _locatorResolver =
      const XBUmeWidgetLocatorResolver();

  bool _pickMode = false;
  XBUmeWidgetLocatorResult? _pickResult;
  XBUmeNotice? _notice;
  String? _lastSelectionLayoutLogKey;

  @override
  void initState() {
    super.initState();
    _offset = widget.controller.config.floatingInitialOffset;
    _panelVisible = widget.controller.panelVisible.value;
    _pickMode = _pickService.picking.value;
    _pickResult = _pickService.selectedResult.value;
    _notice = _noticeService.current.value;
    widget.controller.panelVisible.addListener(_onPanelVisibleChanged);
    _pickService.picking.addListener(_onPickModeChanged);
    _pickService.selectedResult.addListener(_onPickResultChanged);
    _noticeService.current.addListener(_onNoticeChanged);
  }

  @override
  void dispose() {
    widget.controller.panelVisible.removeListener(_onPanelVisibleChanged);
    _pickService.picking.removeListener(_onPickModeChanged);
    _pickService.selectedResult.removeListener(_onPickResultChanged);
    _noticeService.current.removeListener(_onNoticeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.controller.config.enable) {
      return widget.child;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;
        _offset = _safeOffset(
          _offset,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
        );

        final panelSize = widget.controller.config.panelSize;
        final panelHeight = panelSize.height.clamp(280.0, maxHeight - 24);
        final panelWidth = maxWidth;

        return Stack(
          fit: StackFit.expand,
          children: [
            KeyedSubtree(
              key: _appRootKey,
              child: widget.child,
            ),
            if (_panelVisible)
              Positioned.fill(
                child: GestureDetector(
                  onTap: widget.controller.hidePanel,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.24),
                  ),
                ),
              ),
            if (_panelVisible)
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: SizedBox(
                    width: panelWidth,
                    height: panelHeight,
                    child: Theme(
                      data: buildXBUmeTheme(),
                      child: HeroControllerScope.none(
                        child: Navigator(
                          onGenerateRoute: (_) {
                            return MaterialPageRoute<void>(
                              builder: (_) => XBUmePanel(
                                controller: widget.controller,
                                onClose: widget.controller.hidePanel,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_pickMode)
              Positioned.fill(
                child: _buildPickOverlay(
                  viewportSize: Size(maxWidth, maxHeight),
                  blockedBottom: _panelVisible
                      ? panelHeight +
                          MediaQuery.of(context).padding.bottom +
                          8.0
                      : 0.0,
                ),
              ),
            Positioned(
              left: _offset.dx,
              top: _offset.dy,
              child: GestureDetector(
                onPanUpdate: (details) {
                  _setStateSafely(() {
                    _offset = _safeOffset(
                      _offset + details.delta,
                      maxWidth: maxWidth,
                      maxHeight: maxHeight,
                    );
                  });
                },
                onTap: () {
                  if (_pickMode) {
                    _pickService.stop();
                    return;
                  }
                  widget.controller.togglePanel();
                },
                child: _buildFloatingButton(context),
              ),
            ),
            if (_notice != null) _buildNoticeOverlay(context, _notice!),
          ],
        );
      },
    );
  }

  Widget _buildNoticeOverlay(BuildContext context, XBUmeNotice notice) {
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, -0.12),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: Container(
                key: ValueKey<int>(notice.id),
                constraints: const BoxConstraints(maxWidth: 560),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xE6191F2A),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xB2FFFFFF),
                    width: 0.8,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Text(
                  notice.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPickOverlay({
    required Size viewportSize,
    required double blockedBottom,
  }) {
    final result = _pickResult;
    final visibleHeight = (viewportSize.height - blockedBottom).clamp(
      0.0,
      viewportSize.height,
    );

    return Stack(
      children: [
        Positioned.fill(
          bottom: blockedBottom,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              final element = _pickElementAt(event.position);
              if (element == null) return;
              final resolved = _locatorResolver.resolve(element);
              _pickService.publishSelection(resolved);
            },
            child: Container(
              color: Colors.black.withValues(alpha: 0.08),
            ),
          ),
        ),
        if (result?.pickedRect != null || result?.resolvedRect != null)
          ..._buildSelectionMarker(
            result: result!,
            viewportSize: viewportSize,
            visibleHeight: visibleHeight,
          ),
      ],
    );
  }

  List<Widget> _buildSelectionMarker({
    required XBUmeWidgetLocatorResult result,
    required Size viewportSize,
    required double visibleHeight,
  }) {
    // 智能选择高亮 rect：
    // - resolvedRect 通常覆盖用户组件的完整视觉区域（如 XBImage 的 SizedBox），
    //   适合作为默认高亮。
    // - 但当 resolvedRect 覆盖过多视口区域（>55%，如 HomePage/Scaffold 覆盖整页）
    //   时回退到 pickedRect，精确定位实际点击的叶子组件。
    final picked = result.pickedRect;
    final resolved = result.resolvedRect;
    final Rect rect;
    if (picked != null && resolved != null) {
      final viewportArea = math.max(1.0, viewportSize.width * visibleHeight);
      final resolvedCoverage =
          (resolved.width * resolved.height) / viewportArea;
      rect = resolvedCoverage > 0.55 ? picked : resolved;
    } else {
      rect = picked ?? resolved!;
    }
    final clamped = Rect.fromLTRB(
      rect.left.clamp(0.0, viewportSize.width),
      rect.top.clamp(0.0, visibleHeight),
      rect.right.clamp(0.0, viewportSize.width),
      rect.bottom.clamp(0.0, visibleHeight),
    );

    if (clamped.width < 1 || clamped.height < 1) {
      return const <Widget>[];
    }

    const bubbleHorizontalPadding = 8.0;
    final bubbleWidth = math.min(560.0, viewportSize.width - 16);
    final left = clamped.left.clamp(
      bubbleHorizontalPadding,
      viewportSize.width - bubbleWidth - bubbleHorizontalPadding,
    );

    final spaceBelow = math.max(0.0, visibleHeight - clamped.bottom - 8.0);
    final spaceAbove = math.max(0.0, clamped.top - 8.0);
    final viewportArea = math.max(1.0, viewportSize.width * visibleHeight);
    final targetCoverage = (clamped.width * clamped.height) / viewportArea;
    final insufficientAnchorSpace = spaceAbove < 120 && spaceBelow < 120;
    final detachedBubble = targetCoverage > 0.55 || insufficientAnchorSpace;

    final placeBelow =
        detachedBubble ? true : (spaceBelow >= 96 || spaceBelow >= spaceAbove);
    final bubbleMaxHeight = detachedBubble
        ? (visibleHeight * 0.42)
            .clamp(140.0, math.max(140.0, visibleHeight - 16))
            .toDouble()
        : (placeBelow ? spaceBelow : spaceAbove)
            .clamp(88.0, math.max(88.0, visibleHeight - 16.0))
            .toDouble();

    final bubbleTop = detachedBubble
        ? (visibleHeight - bubbleMaxHeight - 8)
            .clamp(8.0, math.max(8.0, visibleHeight - bubbleMaxHeight - 8.0))
            .toDouble()
        : placeBelow
            ? (clamped.bottom + 8)
                .clamp(
                    8.0, math.max(8.0, visibleHeight - bubbleMaxHeight - 8.0))
                .toDouble()
            : (clamped.top - bubbleMaxHeight - 8)
                .clamp(
                    8.0, math.max(8.0, visibleHeight - bubbleMaxHeight - 8.0))
                .toDouble();

    final fileText = result.file ?? 'location unavailable';
    final lineColumnText =
        'line: ${result.line ?? '-'}  column: ${result.column ?? '-'}';
    final parentLocationText = result.parentFile == null
        ? 'parent location unavailable'
        : '${result.parentFile}:${result.parentLine ?? '-'}:${result.parentColumn ?? '-'}';

    _debugLogSelectionLayout(
      result: result,
      viewportSize: viewportSize,
      visibleHeight: visibleHeight,
      clampedRect: clamped,
      bubbleWidth: bubbleWidth,
      bubbleTop: bubbleTop,
      bubbleMaxHeight: bubbleMaxHeight,
      detachedBubble: detachedBubble,
      targetCoverage: targetCoverage,
      placeBelow: placeBelow,
      spaceAbove: spaceAbove,
      spaceBelow: spaceBelow,
    );

    return <Widget>[
      Positioned.fromRect(
        rect: clamped,
        child: IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: const Color(0xFF00E5FF),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.20),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
        ),
      ),
      Positioned(
        left: left,
        top: bubbleTop,
        child: IgnorePointer(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: bubbleWidth,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.84),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.45),
                ),
              ),
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  height: 1.35,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      result.pickedWidgetType != result.resolvedWidgetType
                          ? 'picked: ${result.pickedWidgetType}'
                          : result.resolvedWidgetType,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color:
                            result.pickedWidgetType != result.resolvedWidgetType
                                ? const Color(0xFF00E5FF)
                                : Colors.white,
                      ),
                    ),
                    if (result.pickedWidgetType !=
                        result.resolvedWidgetType) ...[
                      const SizedBox(height: 2),
                      Text(
                        'resolved: ${result.resolvedWidgetType}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFB0BEC5),
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(_wrapPathForDisplay(fileText)),
                    if (result.hasLocation) ...[
                      const SizedBox(height: 2),
                      Text(lineColumnText),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      'parent: ${result.parentWidgetType ?? '-'}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(_wrapPathForDisplay(parentLocationText)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  String _wrapPathForDisplay(String path) {
    return path
        .replaceAll('/', '/\u200B')
        .replaceAll('\\', '\\\u200B')
        .replaceAll(':', ':\u200B');
  }

  void _debugLogSelectionLayout({
    required XBUmeWidgetLocatorResult result,
    required Size viewportSize,
    required double visibleHeight,
    required Rect clampedRect,
    required double bubbleWidth,
    required double bubbleTop,
    required double bubbleMaxHeight,
    required bool detachedBubble,
    required double targetCoverage,
    required bool placeBelow,
    required double spaceAbove,
    required double spaceBelow,
  }) {
    assert(() {
      final key = [
        result.resolvedWidgetType,
        result.file,
        result.line,
        result.column,
        clampedRect.left.toStringAsFixed(1),
        clampedRect.top.toStringAsFixed(1),
        clampedRect.width.toStringAsFixed(1),
        clampedRect.height.toStringAsFixed(1),
        bubbleTop.toStringAsFixed(1),
        bubbleMaxHeight.toStringAsFixed(1),
        targetCoverage.toStringAsFixed(3),
        detachedBubble,
        visibleHeight.toStringAsFixed(1),
      ].join('|');
      if (_lastSelectionLayoutLogKey == key) {
        return true;
      }
      _lastSelectionLayoutLogKey = key;
      debugPrint(
        '[xb_ume][pick] bubble layout: '
        'widget=${result.resolvedWidgetType} '
        'viewport=${viewportSize.width.toStringAsFixed(1)}x${viewportSize.height.toStringAsFixed(1)} '
        'visibleH=${visibleHeight.toStringAsFixed(1)} '
        'rect=(${clampedRect.left.toStringAsFixed(1)},${clampedRect.top.toStringAsFixed(1)},${clampedRect.width.toStringAsFixed(1)},${clampedRect.height.toStringAsFixed(1)}) '
        'bubbleW=${bubbleWidth.toStringAsFixed(1)} '
        'bubbleTop=${bubbleTop.toStringAsFixed(1)} '
        'bubbleMaxH=${bubbleMaxHeight.toStringAsFixed(1)} '
        'coverage=${targetCoverage.toStringAsFixed(3)} '
        'detached=$detachedBubble '
        'place=${placeBelow ? 'below' : 'above'} '
        'spaceAbove=${spaceAbove.toStringAsFixed(1)} '
        'spaceBelow=${spaceBelow.toStringAsFixed(1)}',
      );
      debugPrint(
        '[xb_ume][pick] location: current=${result.file}:${result.line}:${result.column} '
        'parent=${result.parentFile}:${result.parentLine}:${result.parentColumn}',
      );
      return true;
    }());
  }

  Element? _pickElementAt(Offset globalPosition) {
    final rootContext = _appRootKey.currentContext;
    if (rootContext == null) return null;

    final rootRenderObject = rootContext.findRenderObject();
    if (rootRenderObject is! RenderBox || !rootRenderObject.hasSize) {
      return null;
    }

    final localPosition = rootRenderObject.globalToLocal(globalPosition);
    final size = rootRenderObject.size;
    if (localPosition.dx < 0 ||
        localPosition.dy < 0 ||
        localPosition.dx > size.width ||
        localPosition.dy > size.height) {
      return null;
    }

    final result = BoxHitTestResult();
    final hit = rootRenderObject.hitTest(result, position: localPosition);
    if (!hit) return null;

    for (final entry in result.path) {
      final target = entry.target;
      if (target is! RenderObject) continue;
      final creator = target.debugCreator;
      if (creator is DebugCreator) {
        return creator.element;
      }
    }

    return null;
  }

  Widget _buildFloatingButton(BuildContext context) {
    final pickMode = _pickMode;
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: pickMode
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF00A8E8), Color(0xFF0077B6)],
              )
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFF7A18), Color(0xFFFF4D4F)],
              ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.24),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        pickMode ? 'EXIT' : 'UME',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 11,
          letterSpacing: 0.7,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }

  void _onPickModeChanged() {
    final pickMode = _pickService.picking.value;
    if (pickMode) {
      widget.controller.hidePanel();
    }
    _setStateSafely(() {
      _pickMode = pickMode;
    });
  }

  void _onPanelVisibleChanged() {
    _setStateSafely(() {
      _panelVisible = widget.controller.panelVisible.value;
    });
  }

  void _onPickResultChanged() {
    _setStateSafely(() {
      _pickResult = _pickService.selectedResult.value;
    });
  }

  void _onNoticeChanged() {
    _setStateSafely(() {
      _notice = _noticeService.current.value;
    });
  }

  void _setStateSafely(VoidCallback fn) {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    final canSetStateNow = phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks;
    if (canSetStateNow) {
      setState(fn);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(fn);
    });
  }

  Offset _safeOffset(
    Offset offset, {
    required double maxWidth,
    required double maxHeight,
  }) {
    const size = 52.0;
    final x = offset.dx.clamp(0.0, (maxWidth - size).clamp(0.0, maxWidth));
    final y = offset.dy.clamp(0.0, (maxHeight - size).clamp(0.0, maxHeight));
    return Offset(x, y);
  }
}
