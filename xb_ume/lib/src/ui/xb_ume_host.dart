import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../core/xb_ume_controller.dart';
import '../core/xb_ume_ide_jump.dart';
import '../core/xb_ume_notice_service.dart';
import '../core/xb_ume_widget_locator_resolver.dart';
import '../core/xb_ume_widget_pick_service.dart';
import '../core/xb_ume_widget_spacing_calculator.dart';
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
  late final XBUmeWidgetLocatorResolver _locatorResolver;

  bool _pickMode = false;
  XBUmeWidgetLocatorResult? _pickResult;
  bool _bubbleExpanded = false;
  // 信息气泡相对默认位置的拖拽偏移；切换选中组件时重置。
  Offset _bubbleDragDelta = Offset.zero;
  // 用于读取气泡自身尺寸，拖拽时做边界 clamp。
  final GlobalKey _bubbleKey = GlobalKey(debugLabel: 'xb_ume_bubble');
  // 跳转请求发出后的浮动提示（锚定被点击的箭头，2s 自动消失）。
  String? _bubbleTipText;
  Rect? _bubbleTipAnchor;
  Offset _bubbleTipOffset = Offset.zero;
  final GlobalKey _bubbleTipKey = GlobalKey(debugLabel: 'xb_ume_bubble_tip');
  Timer? _bubbleActionTimer;
  XBUmeNotice? _notice;
  String? _lastSelectionLayoutLogKey;

  @override
  void initState() {
    super.initState();
    _offset = widget.controller.config.floatingInitialOffset;
    _locatorResolver = XBUmeWidgetLocatorResolver(
      inspectablePackages: widget.controller.config.locatorInspectablePackages,
    );
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
    _bubbleActionTimer?.cancel();
    _bubbleTipText = null;
    _bubbleTipAnchor = null;
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
        // 跳转反馈浮动提示：锚定被点击的箭头，置于 Stack 顶层，
        // 不受气泡展开/滚动影响。
        if (_bubbleTipText != null && _bubbleTipAnchor != null)
          Positioned(
            left: _bubbleTipOffset.dx,
            top: _bubbleTipOffset.dy,
            // 透明 Material：提供文字渲染上下文，否则 Text 无样式继承
            // 会显示 Flutter 默认的黄色双下划线。
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                key: _bubbleTipKey,
                constraints: const BoxConstraints(maxWidth: 260),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xE6101418),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  _bubbleTipText!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF00E5FF),
                  ),
                ),
              ),
            ),
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

    // 间距测量：以实际参与高亮的 rect 对应的 Element 为目标。
    final Element spacingTarget =
        (picked != null && rect == picked)
            ? result.pickedElement
            : result.resolvedElement;
    final XBUmeWidgetSpacing? spacing = const XBUmeWidgetSpacingCalculator(
      debugLog: kDebugMode,
    ).calculate(
      spacingTarget,
      searchRoot: _appRootKey.currentContext as Element?,
    );

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

    // 拖拽偏移边界 clamp：保证气泡四周至少留 8px 在可视区内。
    Offset clampBubbleDelta(Offset delta) {
      var bubbleW = bubbleWidth;
      var bubbleH = 40.0;
      final bubbleRo = _bubbleKey.currentContext?.findRenderObject();
      if (bubbleRo is RenderBox && bubbleRo.hasSize) {
        bubbleW = bubbleRo.size.width;
        bubbleH = bubbleRo.size.height;
      }
      final minX = 8.0 - (left + bubbleW);
      final maxX = viewportSize.width - 8.0 - left;
      final minY = 8.0 - bubbleTop;
      final maxY = visibleHeight - 8.0 - bubbleTop - bubbleH;
      return Offset(
        delta.dx.clamp(math.min(minX, maxX), math.max(minX, maxX)).toDouble(),
        delta.dy.clamp(math.min(minY, maxY), math.max(minY, maxY)).toDouble(),
      );
    }

    final Widget bubble = Material(
      color: Colors.transparent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 展开态为全屏面板，不参与拖拽；收起态支持拖动。
        onPanUpdate: _bubbleExpanded
            ? null
            : (details) {
                _setStateSafely(() {
                  _bubbleDragDelta =
                      clampBubbleDelta(_bubbleDragDelta + details.delta);
                });
              },
        onTap: () {
          _setStateSafely(() {
            _bubbleExpanded = !_bubbleExpanded;
          });
        },
        child: Container(
          key: _bubbleKey,
          width: _bubbleExpanded ? null : bubbleWidth,
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
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: _bubbleExpanded ? double.infinity : bubbleMaxHeight,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 头部行：_jumpableRow 自带 Expanded 行布局，
                    // 不可再包无界 Row（Expanded 需有界宽度约束）。
                    _jumpableRow(
                      file: result.file,
                      line: result.line,
                      column: result.column,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            result.pickedWidgetType !=
                                    result.resolvedWidgetType
                                ? 'picked: ${result.pickedWidgetType}'
                                : result.resolvedWidgetType,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: result.pickedWidgetType !=
                                      result.resolvedWidgetType
                                  ? const Color(0xFF00E5FF)
                                  : Colors.white,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            Icons.drag_indicator,
                            size: 12,
                            color: const Color(0xFF00E5FF)
                                .withValues(alpha: 0.6),
                          ),
                        ],
                      ),
                    ),
                    if (result.pickedWidgetType !=
                        result.resolvedWidgetType) ...[
                      const SizedBox(height: 2),
                      _jumpableRow(
                        file: result.file,
                        line: result.line,
                        column: result.column,
                        child: Text(
                          'resolved: ${result.resolvedWidgetType}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFB0BEC5),
                          ),
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
                    _jumpableRow(
                      file: result.parentFile,
                      line: result.parentLine,
                      column: result.parentColumn,
                      child: Text(
                        'parent: ${result.parentWidgetType ?? '-'}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 2),
                    _jumpableRow(
                      file: result.parentFile,
                      line: result.parentLine,
                      column: result.parentColumn,
                      child: Text(_wrapPathForDisplay(parentLocationText)),
                    ),
                    if (spacing != null && spacing.hasAny) ...[
                      const SizedBox(height: 6),
                      Text(
                        'spacing: ${spacing.summaryText}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFFB0BEC5),
                        ),
                      ),
                    ],
                    if (_bubbleExpanded) ..._buildChainRows(result),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _bubbleExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 14,
                          color: const Color(0xFF00E5FF),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _bubbleExpanded
                              ? 'Collapse chain'
                              : 'Expand full chain '
                                  '(${_visibleChainNodes(result).length})',
                          style: const TextStyle(
                            color: Color(0xFF00E5FF),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final safePadding = MediaQuery.of(context).padding;

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
      if (_bubbleExpanded)
        // 展开态：气泡充满整个可视区域（避开顶部/底部安全区与底部面板区）。
        Positioned(
          left: 8,
          right: 8,
          top: safePadding.top + 8,
          bottom: math.max(
            safePadding.bottom + 8,
            viewportSize.height - visibleHeight + 8,
          ),
          child: bubble,
        )
      else
        Positioned(
          left: left + _bubbleDragDelta.dx,
          top: bubbleTop + _bubbleDragDelta.dy,
          child: bubble,
        ),
      // 间距标注：绘制在最上层，避免被高亮框/气泡遮挡影响读数。
      if (spacing != null && spacing.hasAny)
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _SpacingGuidesPainter(
                spacing: spacing,
                viewportSize: viewportSize,
                visibleHeight: visibleHeight,
              ),
            ),
          ),
        ),
    ];
  }

  /// 展开态下只展示“代码可见”层（业务代码、本地库、三方包，
  /// 过滤 Flutter SDK 框架层），顺序为根 → 被点击组件。
  /// 若没有任何可见层（极端情况）则回退展示全部。
  List<XBUmeLocatorChainNode> _visibleChainNodes(
    XBUmeWidgetLocatorResult result,
  ) {
    final all = result.chain.reversed.toList(growable: false);
    final visible = all.where((node) => node.visible).toList(growable: false);
    return visible.isEmpty ? all : visible;
  }

  /// 展开态下的完整组件链条（根 → 被点击组件）。
  /// 按文件分组展示：文件路径在上、组件名在下，文件之间有明显分割线。
  List<Widget> _buildChainRows(XBUmeWidgetLocatorResult result) {
    final nodes = _visibleChainNodes(result);
    final rows = <Widget>[];
    String? currentFile;
    var hasGroup = false;
    for (final node in nodes) {
      final file = node.hasLocation ? node.file : null;
      if (file != currentFile) {
        // 切换到新的文件分组：先插入分割线，再展示文件头。
        if (hasGroup) {
          rows.add(const SizedBox(height: 8));
          rows.add(
            Container(
              height: 1,
              color: const Color(0xFF00E5FF).withValues(alpha: 0.22),
            ),
          );
          rows.add(const SizedBox(height: 8));
        }
        rows.add(
          Text(
            file == null ? 'unknown location' : _wrapPathForDisplay(file),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Color(0xFFB0BEC5),
            ),
          ),
        );
        currentFile = file;
        hasGroup = true;
      }
      rows.add(
        _jumpableRow(
          file: node.file,
          line: node.line,
          column: node.column,
          child: _buildChainRow(node),
        ),
      );
    }
    return <Widget>[
      const SizedBox(height: 6),
      Container(
        height: 1,
        color: const Color(0xFF00E5FF).withValues(alpha: 0.25),
      ),
      const SizedBox(height: 6),
      const Text(
        'widget chain (root → picked):',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 2),
      const Text(
        '点击行尾箭头可在 IDE 打开源码',
        style: TextStyle(fontSize: 10, color: Color(0xFF8B95A5)),
      ),
      const SizedBox(height: 2),
      ...rows,
    ];
  }

  Widget _buildChainRow(XBUmeLocatorChainNode node) {
    final FontWeight weight =
        (node.isResolved || node.isPicked) ? FontWeight.w700 : FontWeight.w600;
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            node.widgetType,
            style: TextStyle(color: Colors.white, fontWeight: weight),
          ),
          if (node.hasLocation)
            Text(
              'line: ${node.line}  column: ${node.column}',
              style: const TextStyle(fontSize: 10, color: Color(0xFF8B95A5)),
            ),
        ],
      ),
    );
  }

  /// 可跳转行：行尾带箭头按钮，点击经 VM service 事件请求 IDE 打开源码。
  Widget _jumpableRow({
    required Widget child,
    required String? file,
    required int? line,
    required int? column,
  }) {
    final jumpable = file != null && file.isNotEmpty && line != null;
    if (!jumpable) {
      return child;
    }
    return Row(
      children: [
        Expanded(child: child),
        // 热区：图标外加四向 padding，保证点击目标 ≥ 28x28。
        Builder(
          builder: (buttonContext) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                Rect? anchorRect;
                final ro = buttonContext.findRenderObject();
                if (ro is RenderBox && ro.hasSize) {
                  anchorRect = ro.localToGlobal(Offset.zero) & ro.size;
                }
                _openSourceFromLocation(
                  file: file,
                  line: line,
                  column: column,
                  anchorRect: anchorRect,
                );
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Icon(
                  Icons.north_east,
                  size: 12,
                  color: Color(0xFF00E5FF),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _openSourceFromLocation({
    required String? file,
    required int? line,
    required int? column,
    Rect? anchorRect,
  }) async {
    final sent = await XBUmeIdeJump.requestOpen(
      file: file,
      line: line,
      column: column,
    );
    if (anchorRect != null) {
      _showBubbleAction(
        sent ? '已发送 IDE 打开请求，路径已复制' : '路径已复制到剪贴板',
        anchorRect: anchorRect,
      );
    }
  }

  /// 在被点击的箭头旁展示浮动提示（host Stack 顶层，2s 自动消失）。
  void _showBubbleAction(String text, {required Rect anchorRect}) {
    _setStateSafely(() {
      _bubbleTipText = text;
      _bubbleTipAnchor = anchorRect;
      _bubbleTipOffset = _tipOffsetFor(
        anchorRect,
        const Size(240, 32), // 插入前的估算尺寸，post frame 后实测修正。
      );
    });
    _bubbleActionTimer?.cancel();
    _bubbleActionTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      _setStateSafely(() {
        _bubbleTipText = null;
        _bubbleTipAnchor = null;
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _bubbleTipText == null || _bubbleTipAnchor == null) {
        return;
      }
      final ro = _bubbleTipKey.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.hasSize) {
        final offset = _tipOffsetFor(_bubbleTipAnchor!, ro.size);
        if (offset != _bubbleTipOffset) {
          _setStateSafely(() {
            _bubbleTipOffset = offset;
          });
        }
      }
    });
  }

  /// 计算提示浮层位置：默认在锚点上方居中，空间不足时放到下方，
  /// 并 clamp 在可视区内。
  Offset _tipOffsetFor(Rect anchor, Size tipSize) {
    final size = MediaQuery.of(context).size;
    var dx = anchor.center.dx - tipSize.width / 2;
    dx = dx.clamp(8.0, math.max(8.0, size.width - tipSize.width - 8));
    var dy = anchor.top - tipSize.height - 8;
    if (dy < 8) {
      dy = anchor.bottom + 8;
    }
    dy = dy.clamp(8.0, math.max(8.0, size.height - tipSize.height - 8));
    return Offset(dx, dy);
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
      if (!pickMode) {
        _bubbleExpanded = false;
      }
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
      _bubbleExpanded = false;
      _bubbleDragDelta = Offset.zero;
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

/// 间距标注绘制：在高亮框四周绘制到同级组件 / 父组件边缘的测量线与数值。
/// 同级间距用橙色，父边缘间距用绿色，与青色高亮框区分。
class _SpacingGuidesPainter extends CustomPainter {
  _SpacingGuidesPainter({
    required this.spacing,
    required this.viewportSize,
    required this.visibleHeight,
  });

  final XBUmeWidgetSpacing spacing;
  final Size viewportSize;
  final double visibleHeight;

  static const Color _componentColor = Color(0xFFFF9800);
  static const Color _parentEdgeColor = Color(0xFF4CAF50);

  @override
  void paint(Canvas canvas, Size size) {
    final clip = Rect.fromLTWH(0, 0, viewportSize.width, visibleHeight);
    final target = spacing.targetRect;

    // 参照组件虚线框：按 rect 去重（同一组件作多方向参照只画一个），
    // 弱于主高亮（虚线、1px、60% 透明度），颜色与对应测量线一致。
    final framedRects = <Rect>{};
    for (final item in spacing.items) {
      final sourceRect = item.sourceRect;
      if (sourceRect == null || !framedRects.add(sourceRect)) continue;
      final frame = Rect.fromLTRB(
        sourceRect.left.clamp(clip.left, clip.right),
        sourceRect.top.clamp(clip.top, clip.bottom),
        sourceRect.right.clamp(clip.left, clip.right),
        sourceRect.bottom.clamp(clip.top, clip.bottom),
      );
      if (frame.width < 1 || frame.height < 1) continue;
      final color = (item.source == XBUmeSpacingSource.component
              ? _componentColor
              : _parentEdgeColor)
          .withValues(alpha: 0.6);
      _drawDashedRect(canvas, frame, color);
    }

    for (final item in spacing.items) {
      final Offset from;
      final Offset to;
      if (item.direction == XBUmeSpacingDirection.up) {
        from = Offset(target.center.dx, target.top);
        to = Offset(target.center.dx, target.top - item.distance);
      } else if (item.direction == XBUmeSpacingDirection.down) {
        from = Offset(target.center.dx, target.bottom);
        to = Offset(target.center.dx, target.bottom + item.distance);
      } else if (item.direction == XBUmeSpacingDirection.left) {
        from = Offset(target.left, target.center.dy);
        to = Offset(target.left - item.distance, target.center.dy);
      } else {
        from = Offset(target.right, target.center.dy);
        to = Offset(target.right + item.distance, target.center.dy);
      }
      final clampedFrom = Offset(
        from.dx.clamp(clip.left, clip.right),
        from.dy.clamp(clip.top, clip.bottom),
      );
      final clampedTo = Offset(
        to.dx.clamp(clip.left, clip.right),
        to.dy.clamp(clip.top, clip.bottom),
      );
      final color = item.source == XBUmeSpacingSource.component
          ? _componentColor
          : _parentEdgeColor;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      final length = (clampedTo - clampedFrom).distance;
      if (length >= 1) {
        canvas.drawLine(clampedFrom, clampedTo, paint);
        _drawTick(canvas, clampedFrom, clampedTo, paint);
        _drawTick(canvas, clampedTo, clampedFrom, paint);
      }
      final mid = length >= 1
          ? Offset(
              (clampedFrom.dx + clampedTo.dx) / 2,
              (clampedFrom.dy + clampedTo.dy) / 2,
            )
          : clampedFrom;
      _drawLabel(canvas, clip, item, mid, color);
    }
  }

  /// 绘制虚线圆角边框（dash 4 / gap 3），用于标出间距参照组件。
  void _drawDashedRect(Canvas canvas, Rect rect, Color color) {
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)));
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      var draw = true;
      while (distance < metric.length) {
        final next = math.min(
          distance + (draw ? 4.0 : 3.0),
          metric.length,
        );
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next;
        draw = !draw;
      }
    }
  }

  /// 在测量线两端绘制垂直于线段的小刻度。
  void _drawTick(Canvas canvas, Offset at, Offset towards, Paint paint) {
    final dir = towards - at;
    if (dir.distance == 0) return;
    final unit = dir / dir.distance;
    final perp = Offset(-unit.dy, unit.dx) * 5;
    canvas.drawLine(at - perp, at + perp, paint);
  }

  void _drawLabel(
    Canvas canvas,
    Rect clip,
    XBUmeSpacingItem item,
    Offset mid,
    Color color,
  ) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: item.distance.toStringAsFixed(1),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1.0,
          decoration: TextDecoration.none,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final bool vertical = item.direction == XBUmeSpacingDirection.up ||
        item.direction == XBUmeSpacingDirection.down;
    final Offset topLeft;
    if (vertical) {
      topLeft = Offset(mid.dx + 4, mid.dy - textPainter.height / 2);
    } else {
      topLeft = Offset(
        mid.dx - textPainter.width / 2,
        mid.dy - textPainter.height - 4,
      );
    }
    final double x = topLeft.dx.clamp(
      clip.left + 2,
      math.max(clip.left + 2, clip.right - textPainter.width - 2),
    );
    final double y = topLeft.dy.clamp(
      clip.top + 2,
      math.max(clip.top + 2, clip.bottom - textPainter.height - 2),
    );
    final bgRect = Rect.fromLTWH(
      x - 4,
      y - 2,
      textPainter.width + 8,
      textPainter.height + 4,
    );
    // 实底彩色标签：橙 = 到可见组件，绿 = 到父边缘，保证各方向读数清晰。
    canvas.drawRRect(
      RRect.fromRectAndRadius(bgRect, const Radius.circular(3)),
      Paint()..color = color,
    );
    textPainter.paint(canvas, Offset(x, y));
  }

  @override
  bool shouldRepaint(covariant _SpacingGuidesPainter oldDelegate) {
    return oldDelegate.spacing != spacing ||
        oldDelegate.viewportSize != viewportSize ||
        oldDelegate.visibleHeight != visibleHeight;
  }
}
