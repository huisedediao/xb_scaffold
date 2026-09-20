import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 间距来源：周围用户组件，或父组件边缘。
enum XBUmeSpacingSource { component, parentEdge }

/// 间距方向。
enum XBUmeSpacingDirection { up, down, left, right }

/// 单个方向的间距测量结果。
class XBUmeSpacingItem {
  const XBUmeSpacingItem({
    required this.direction,
    required this.distance,
    required this.source,
    this.sourceWidgetType,
    this.sourceRect,
  });

  final XBUmeSpacingDirection direction;

  /// 间距（逻辑像素，>= 0）。
  final double distance;
  final XBUmeSpacingSource source;

  /// 来源为用户组件时的组件类型，父组件边缘时为 null。
  final String? sourceWidgetType;

  /// 参照组件的全局 rect（用于绘制参照高亮框；父边缘来源时为父容器 rect）。
  final Rect? sourceRect;

  String get arrow {
    switch (direction) {
      case XBUmeSpacingDirection.up:
        return '↑';
      case XBUmeSpacingDirection.down:
        return '↓';
      case XBUmeSpacingDirection.left:
        return '←';
      case XBUmeSpacingDirection.right:
        return '→';
    }
  }

  /// 单项描述，如 `↑30.0(XBCell)` 或 `↓12.0(parent)`。
  String get describe {
    final target = source == XBUmeSpacingSource.parentEdge
        ? 'parent'
        : sourceWidgetType ?? 'component';
    return '$arrow${distance.toStringAsFixed(1)}($target)';
  }
}

/// 选中组件的四方向间距测量结果。
class XBUmeWidgetSpacing {
  const XBUmeWidgetSpacing({
    required this.targetRect,
    this.up,
    this.down,
    this.left,
    this.right,
  });

  /// 目标组件的全局 rect（用于 overlay 绘制测量线）。
  final Rect targetRect;
  final XBUmeSpacingItem? up;
  final XBUmeSpacingItem? down;
  final XBUmeSpacingItem? left;
  final XBUmeSpacingItem? right;

  List<XBUmeSpacingItem> get items =>
      <XBUmeSpacingItem?>[up, down, left, right]
          .whereType<XBUmeSpacingItem>()
          .toList(growable: false);

  bool get hasAny => items.isNotEmpty;

  /// 气泡摘要文本，如 `↑30.0(XBCell)  ↓12.0(parent)`。
  String get summaryText => items.map((item) => item.describe).join('  ');
}

/// 候选参照组件。
class _CandidateBox {
  const _CandidateBox(this.widgetType, this.rect, this.box);

  final String widgetType;
  final Rect rect;
  final RenderBox box;
}

/// 计算选中组件与其周围用户组件 / 父组件边缘的四方向间距。
///
/// 测量语义与肉眼所见一致：
/// - 候选参照只保留"用户写的组件"：按源码归属过滤（与 locator 一致，
///   排除 Flutter/Dart SDK 构建的组件），并叠加系统组件类型过滤
///   （Semantics/Listener/Padding 等即便写在用户代码里也不作为参照）；
/// - 每个方向取"离得最近的用户组件"边缘间距，不限制组件层级；
/// - 与目标矩形相交的组件（祖先容器、包裹层等）不会作为该方向参照；
/// - 某方向没有任何用户组件时，回退为到父组件对应边缘的间距；
/// - 父边缘回退同样只认用户组件（布局容器如 Column/Stack 除外），
///   找不到时退化为任意实质不同的祖先 rect；
/// - 父级 rect 与目标 rect 相同（如 Positioned/ParentDataWidget 包裹）时，
///   继续向上找到第一个 rect 实质不同的祖先。
class XBUmeWidgetSpacingCalculator {
  const XBUmeWidgetSpacingCalculator({this.debugLog = false});

  /// 是否输出间距测量调试日志（诊断读数异常时打开，host 中默认
  /// 跟随 kDebugMode）。
  final bool debugLog;

  /// 方向判断容差（逻辑像素），允许边缘轻微重叠仍视为贴合。
  static const double _tolerance = 0.5;

  /// 判定祖先 rect 与目标 rect 是否“实质不同”的阈值。
  static const double _distinctTolerance = 0.5;

  /// 父级上溯的最大层数。
  static const int _maxAncestorLevels = 10;

  /// 垂直轴重叠判定阈值：重叠长度小于该值视为不重叠。
  static const double _overlapEpsilon = 0.01;

  /// 自身不绘制内容 / 系统包装组件，不作为间距参照。
  /// （layout-only 类型不可见；Semantics/Listener 等即便由用户代码
  /// 构建也是系统组件，不符合"肉眼可见的周围组件"语义。）
  static const Set<String> _candidateSkipTypes = <String>{
    // 布局占位（不可见）。
    'Padding',
    'SizedBox',
    'ConstrainedBox',
    'Align',
    'Center',
    'FittedBox',
    'AspectRatio',
    'FractionallySizedBox',
    'LimitedBox',
    'IntrinsicWidth',
    'IntrinsicHeight',
    'Opacity',
    'Transform',
    'ClipRect',
    'ClipRRect',
    'ClipOval',
    'ClipPath',
    // 多子布局容器（box 覆盖子组件间空隙，作为参照会缩短可见间距）。
    'Column',
    'Row',
    'Stack',
    'Flex',
    'Wrap',
    'IndexedStack',
    'Expanded',
    'Flexible',
    'Spacer',
    'Positioned',
    // 系统包装组件。
    'Semantics',
    'IndexedSemantics',
    'Listener',
    'GestureDetector',
    'RawGestureDetector',
    'MouseRegion',
    'Builder',
    'LayoutBuilder',
    'KeyedSubtree',
    'RepaintBoundary',
    'Offstage',
    'Visibility',
    'AbsorbPointer',
    'IgnorePointer',
  };

  /// 父边缘回退时跳过的类型：在 [_candidateSkipTypes] 基础上保留
  /// Column/Row/Stack 等布局容器——它们的边缘即用户认知的"父组件边缘"。
  static const Set<String> _ancestorSkipTypes = <String>{
    'Padding',
    'SizedBox',
    'ConstrainedBox',
    'Align',
    'Center',
    'FittedBox',
    'AspectRatio',
    'FractionallySizedBox',
    'LimitedBox',
    'IntrinsicWidth',
    'IntrinsicHeight',
    'Opacity',
    'Transform',
    'ClipRect',
    'ClipRRect',
    'ClipOval',
    'ClipPath',
    'Expanded',
    'Flexible',
    'Spacer',
    'Positioned',
    'Semantics',
    'IndexedSemantics',
    'Listener',
    'GestureDetector',
    'RawGestureDetector',
    'MouseRegion',
    'Builder',
    'LayoutBuilder',
    'KeyedSubtree',
    'RepaintBoundary',
    'Offstage',
    'Visibility',
    'AbsorbPointer',
    'IgnorePointer',
  };

  /// [searchRoot] 用于限定候选组件的搜索范围，应传入应用内容子树的根
  /// Element（排除调试工具自身的覆盖层，避免气泡/高亮框干扰测量）。
  /// 为 null 时回退为目标组件的最顶层祖先。
  XBUmeWidgetSpacing? calculate(Element element, {Element? searchRoot}) {
    final targetRect = _resolveRect(element);
    if (targetRect == null) return null;

    final targetBox = element.renderObject;
    final searchRootRenderObject = searchRoot?.renderObject;
    final appRootBox =
        searchRootRenderObject is RenderBox ? searchRootRenderObject : null;
    final candidates = _collectCandidates(
      searchRoot ?? _topmostAncestor(element),
      targetBox,
    );
    final filterByLocation =
        WidgetInspectorService.instance.isWidgetCreationTracked();
    final parentRect = _resolveDistinctAncestorRect(
      element,
      targetRect,
      filterByLocation,
    );

    final up = _nearestComponent(
          candidates,
          targetRect,
          XBUmeSpacingDirection.up,
          appRootBox,
        ) ??
        _parentEdgeItem(
          XBUmeSpacingDirection.up,
          targetRect,
          parentRect,
        );
    final down = _nearestComponent(
          candidates,
          targetRect,
          XBUmeSpacingDirection.down,
          appRootBox,
        ) ??
        _parentEdgeItem(
          XBUmeSpacingDirection.down,
          targetRect,
          parentRect,
        );
    final left = _nearestComponent(
          candidates,
          targetRect,
          XBUmeSpacingDirection.left,
          appRootBox,
        ) ??
        _parentEdgeItem(
          XBUmeSpacingDirection.left,
          targetRect,
          parentRect,
        );
    final right = _nearestComponent(
          candidates,
          targetRect,
          XBUmeSpacingDirection.right,
          appRootBox,
        ) ??
        _parentEdgeItem(
          XBUmeSpacingDirection.right,
          targetRect,
          parentRect,
        );

    if (debugLog) {
      debugPrint(
        '[xb_ume][spacing] target=${element.widget.runtimeType} '
        'rect=$targetRect candidates=${candidates.length} | '
        'up=${up?.describe ?? '-'} down=${down?.describe ?? '-'} '
        'left=${left?.describe ?? '-'} right=${right?.describe ?? '-'}',
      );
    }

    return XBUmeWidgetSpacing(
      targetRect: targetRect,
      up: up,
      down: down,
      left: left,
      right: right,
    );
  }

  /// 取 element 的 renderObject 全局 rect，无法测量时返回 null。
  Rect? _resolveRect(Element element) {
    final renderObject = element.renderObject;
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    if (!topLeft.isFinite) return null;
    return topLeft & renderObject.size;
  }

  Element? _topmostAncestor(Element element) {
    Element? top;
    element.visitAncestorElements((ancestor) {
      top = ancestor;
      return true;
    });
    return top;
  }

  /// 读取组件的 creation location 源码文件（与 locator resolver 同源做法）。
  String? _creationLocationFile(Element element) {
    try {
      final node = element.toDiagnosticsNode();
      final jsonNode = node.toJsonMap(
        InspectorSerializationDelegate(
          service: WidgetInspectorService.instance,
          includeProperties: false,
          subtreeDepth: 1,
        ),
      );
      final location = jsonNode['creationLocation'];
      if (location is Map) {
        return location['file']?.toString();
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// 是否为用户代码位置：有源码位置且不属于 Flutter/Dart SDK。
  /// 业务代码、path 依赖库、pub-cache 三方包均视为用户代码。
  bool _isUserCodeLocation(String? file) {
    if (file == null || file.isEmpty) return false;
    final lower = _normalizeLocationFile(file).toLowerCase();
    return !(lower.startsWith('dart:') ||
        lower.startsWith('package:flutter/') ||
        lower.contains('/packages/flutter/') ||
        lower.contains('/flutter/packages/flutter/'));
  }

  String _normalizeLocationFile(String file) {
    try {
      final uri = Uri.parse(file);
      if (uri.scheme == 'file') {
        return uri.toFilePath();
      }
    } catch (_) {
      // ignored
    }
    return file;
  }

  /// 遍历搜索范围内的用户组件，收集候选参照。
  ///
  /// 过滤规则（与肉眼所见对齐）：
  /// - 系统组件类型（[_candidateSkipTypes]）不作为参照；
  /// - widget creation tracking 可用时，仅保留源码归属为用户代码的组件；
  /// - 排除目标自身的 renderBox 与不可见（零尺寸）组件；
  /// - 多个用户组件共享同一 renderBox 时，仅保留最外层（首个遍历到的）。
  List<_CandidateBox> _collectCandidates(
    Element? root,
    RenderObject? targetBox,
  ) {
    if (root == null) return const <_CandidateBox>[];
    final filterByLocation =
        WidgetInspectorService.instance.isWidgetCreationTracked();
    final boxes = <_CandidateBox>[];
    final seenBoxes = <RenderObject, void>{};

    void visitor(Element element) {
      final widgetType = '${element.widget.runtimeType}';
      if (!_candidateSkipTypes.contains(widgetType)) {
        final box = element.renderObject;
        if (box is RenderBox &&
            box.attached &&
            box.hasSize &&
            !identical(box, targetBox) &&
            !seenBoxes.containsKey(box)) {
          final topLeft = box.localToGlobal(Offset.zero);
          if (topLeft.isFinite) {
            final rect = topLeft & box.size;
            final isUserCode = !filterByLocation ||
                _isUserCodeLocation(_creationLocationFile(element));
            if (rect.width > 0 && rect.height > 0 && isUserCode) {
              seenBoxes[box] = null;
              boxes.add(_CandidateBox(widgetType, rect, box));
            }
          }
        }
      }
      element.visitChildren(visitor);
    }

    try {
      root.visitChildren(visitor);
    } catch (_) {
      // 元素树在遍历期间发生变动时，保留已收集的结果。
    }
    return boxes;
  }

  XBUmeSpacingItem? _nearestComponent(
    List<_CandidateBox> candidates,
    Rect target,
    XBUmeSpacingDirection direction,
    RenderBox? appRootBox,
  ) {
    XBUmeSpacingItem? best;
    var bestDistance = double.infinity;
    var invisibleSkipped = 0;
    for (final candidate in candidates) {
      final rect = candidate.rect;
      final bool inDirection;
      final bool overlapped;
      final double rawDistance;
      if (direction == XBUmeSpacingDirection.up) {
        inDirection = rect.bottom <= target.top + _tolerance;
        overlapped =
            _overlapLength(rect.left, rect.right, target.left, target.right) >
                _overlapEpsilon;
        rawDistance = target.top - rect.bottom;
      } else if (direction == XBUmeSpacingDirection.down) {
        inDirection = rect.top >= target.bottom - _tolerance;
        overlapped =
            _overlapLength(rect.left, rect.right, target.left, target.right) >
                _overlapEpsilon;
        rawDistance = rect.top - target.bottom;
      } else if (direction == XBUmeSpacingDirection.left) {
        inDirection = rect.right <= target.left + _tolerance;
        overlapped =
            _overlapLength(rect.top, rect.bottom, target.top, target.bottom) >
                _overlapEpsilon;
        rawDistance = target.left - rect.right;
      } else {
        inDirection = rect.left >= target.right - _tolerance;
        overlapped =
            _overlapLength(rect.top, rect.bottom, target.top, target.bottom) >
                _overlapEpsilon;
        rawDistance = rect.left - target.right;
      }
      if (!inDirection || !overlapped) continue;
      final distance = math.max(0.0, rawDistance);
      if (distance >= bestDistance) continue;
      // 可见性过滤：被上层不透明路由覆盖（如下层路由残留组件，其
      // Element 树仍完成布局、尺寸有效但不可绘制）或 Offstage 的组件，
      // 命中测试不可达，不作为参照。
      if (appRootBox != null &&
          !_isVisibleFromAppRoot(appRootBox, candidate, direction)) {
        invisibleSkipped++;
        continue;
      }
      bestDistance = distance;
      best = XBUmeSpacingItem(
        direction: direction,
        distance: distance,
        source: XBUmeSpacingSource.component,
        sourceWidgetType: candidate.widgetType,
        sourceRect: rect,
      );
    }
    if (debugLog && invisibleSkipped > 0) {
      debugPrint(
        '[xb_ume][spacing] ${direction.name}: 剔除 $invisibleSkipped 个'
        '命中不可达候选（通常为下层路由残留或 Offstage 组件）',
      );
    }
    return best;
  }

  /// 取候选组件朝向目标一侧边缘内侧的采样点（全局坐标），
  /// 用于命中测试可见性判断。
  Offset _edgeSamplePoint(Rect rect, XBUmeSpacingDirection direction) {
    final insetX = math.min(2.0, rect.width / 2);
    final insetY = math.min(2.0, rect.height / 2);
    switch (direction) {
      case XBUmeSpacingDirection.up:
        return Offset(rect.center.dx, rect.bottom - insetY);
      case XBUmeSpacingDirection.down:
        return Offset(rect.center.dx, rect.top + insetY);
      case XBUmeSpacingDirection.left:
        return Offset(rect.right - insetX, rect.center.dy);
      case XBUmeSpacingDirection.right:
        return Offset(rect.left + insetX, rect.center.dy);
    }
  }

  /// 候选组件在应用根子树中是否"视觉可达"：
  /// 在其朝向目标一侧边缘取采样点对 searchRoot 的 renderBox 做命中测试，
  /// 命中路径包含该组件（或其后代）才算可见。被上层不透明路由覆盖、
  /// Offstage、或被其他组件完全遮挡的候选会被剔除。
  bool _isVisibleFromAppRoot(
    RenderBox appRootBox,
    _CandidateBox candidate,
    XBUmeSpacingDirection direction,
  ) {
    try {
      final sample = _edgeSamplePoint(candidate.rect, direction);
      final position = appRootBox.globalToLocal(sample);
      final result = BoxHitTestResult();
      if (!appRootBox.hitTest(result, position: position)) return false;
      for (final entry in result.path) {
        if (entry is! BoxHitTestEntry) continue;
        RenderObject? current = entry.target;
        var depth = 0;
        while (current != null && depth < 32) {
          if (identical(current, candidate.box)) return true;
          current = current.parent;
          depth++;
        }
      }
      return false;
    } catch (_) {
      // 命中测试异常时不剔除候选，保持旧行为。
      return true;
    }
  }

  double _overlapLength(double aStart, double aEnd, double bStart, double bEnd) {
    return math.min(aEnd, bEnd) - math.max(aStart, bStart);
  }

  /// 由父级向上找父边缘参照：
  /// 第一优先：非系统包装类型的用户组件祖先（且 filterByLocation 时
  /// 源码归属为用户代码），rect 与目标实质不同；
  /// 兜底：任意 rect 实质不同的祖先（ParentDataWidget 等包裹层与目标
  /// 共享同一 renderObject，会被"实质不同"判定自然跳过）。
  Rect? _resolveDistinctAncestorRect(
    Element element,
    Rect targetRect,
    bool filterByLocation,
  ) {
    Rect? userCandidate;
    Rect? anyCandidate;
    var levels = 0;
    element.visitAncestorElements((ancestor) {
      final rect = _resolveRect(ancestor);
      if (rect != null && _isDistinctRect(rect, targetRect)) {
        anyCandidate ??= rect;
        final widgetType = '${ancestor.widget.runtimeType}';
        final isUserComponent = !_ancestorSkipTypes.contains(widgetType) &&
            (!filterByLocation ||
                _isUserCodeLocation(_creationLocationFile(ancestor)));
        if (isUserComponent && userCandidate == null) {
          userCandidate = rect;
          return false;
        }
      }
      levels++;
      return levels < _maxAncestorLevels;
    });
    return userCandidate ?? anyCandidate;
  }

  bool _isDistinctRect(Rect a, Rect b) {
    return (a.left - b.left).abs() > _distinctTolerance ||
        (a.top - b.top).abs() > _distinctTolerance ||
        (a.right - b.right).abs() > _distinctTolerance ||
        (a.bottom - b.bottom).abs() > _distinctTolerance;
  }

  XBUmeSpacingItem? _parentEdgeItem(
    XBUmeSpacingDirection direction,
    Rect target,
    Rect? parentRect,
  ) {
    if (parentRect == null) return null;
    final double rawDistance;
    if (direction == XBUmeSpacingDirection.up) {
      rawDistance = target.top - parentRect.top;
    } else if (direction == XBUmeSpacingDirection.down) {
      rawDistance = parentRect.bottom - target.bottom;
    } else if (direction == XBUmeSpacingDirection.left) {
      rawDistance = target.left - parentRect.left;
    } else {
      rawDistance = parentRect.right - target.right;
    }
    return XBUmeSpacingItem(
      direction: direction,
      distance: math.max(0.0, rawDistance),
      source: XBUmeSpacingSource.parentEdge,
      sourceRect: parentRect,
    );
  }
}
