import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'xb_auto_track_config.dart';
import 'xb_auto_track_fingerprint.dart';

/// 从 hitTest 结果构建语义指纹（类型链 + 可读文本 + 路由名）。
///
/// RenderObject → Element 的反查依赖 [RenderObject.debugCreator]：
/// 框架仅在 debug 断言块内为其赋值（见 framework.dart 的
/// `_debugUpdateRenderObjectOwner`），因此本采集器只在 debug/profile
/// 下产出完整类型链；release 下反查失败返回 null，降级策略属 P3 范畴。
class XBChainFingerprinter {
  XBChainFingerprinter({XBAutoTrackConfig config = const XBAutoTrackConfig()})
      : _config = config;

  /// 框架内置噪声类型：无业务语义的布局/手势/焦点壳层。
  /// 不剔除的话，Material 层级就会耗尽 maxDepth，业务类型永远进不了链。
  /// 匹配规则为完整类型名（含私有类型）。
  static const Set<String> _noiseTypes = <String>{
    // 布局壳
    'ConstrainedBox', 'Padding', 'Align', 'Center', 'SizedBox', 'AspectRatio',
    'FractionallySizedBox', 'FittedBox', 'ColoredBox', 'DecoratedBox',
    'LimitedBox', 'IntrinsicWidth', 'IntrinsicHeight', 'Baseline',
    'Stack', 'Row', 'Column', 'Expanded', 'Flexible', 'Wrap', 'Flow',
    'ClipRect', 'ClipRRect', 'ClipOval', 'ClipPath', 'Transform', 'Opacity',
    'Visibility', 'Offstage', 'SafeArea', 'MediaQuery', 'Directionality',
    // Material 组件内部层级
    'Material', '_MaterialInterior', 'PhysicalShape', '_ShapeBorderPaint',
    'CustomPaint', 'NotificationListener', '_InkFeatures', 'Ink',
    'AnimatedDefaultTextStyle', 'DefaultTextStyle', 'DefaultSelectionStyle',
    'IconTheme', 'IconButtonTheme', '_ListTile', '_EffectiveTickerMode',
    // 手势/焦点/语义壳
    'Listener', 'GestureDetector', 'RawGestureDetector', 'MouseRegion',
    'Semantics', 'Focus', 'FocusScope', 'FocusTraversalGroup',
    '_FocusInheritedScope', '_ActionsScope', 'Actions', 'AbsorbPointer',
    'IgnorePointer', 'Builder', 'KeyedSubtree', 'TickerMode',
    '_InkResponseStateWidget', '_ParentInkResponseProvider',
    // 应用根层级（页面语义由 routeName 承担）
    'MaterialApp', 'WidgetsApp', 'Navigator', 'Overlay', '_Theatre',
    '_OverlayEntryWidget', 'RepaintBoundary', 'ScrollConfiguration',
    'PrimaryScrollController', 'AutomaticKeepAlive', 'Title',
  };

  static const int _maxWalkDepth = 100;

  XBAutoTrackConfig _config;

  set config(XBAutoTrackConfig value) => _config = value;

  /// 由内向外遍历 hitTest 结果，取首个可反查 Element 的链构建指纹。
  ///
  /// 注意：首个可反查 entry 构建失败（含黑名单命中）即放弃整条事件，
  /// 不能回退到外层 entry——外层在黑名单组件之外，会绕过过滤。
  XBAutoTrackFingerprint? fingerprintFrom(HitTestResult result) {
    for (final HitTestEntry entry in result.path) {
      final Element? element = _resolveElement(entry.target);
      if (element == null) continue;
      return _build(element);
    }
    return null;
  }

  /// 沿 RenderObject 父链向上寻找首个携带 debugCreator 的节点作为锚点，
  /// 再在锚点 Element 子树内精确定位命中 RenderObject 对应的 Element。
  ///
  /// debugCreator 仅在 widget update 时赋值（见 framework.dart 的
  /// `_debugUpdateRenderObjectOwner`），首次 mount 的子树均为 null，
  /// 因此不能直接信任锚点，需二次定位。
  Element? _resolveElement(Object? target) {
    if (target is! RenderObject) return null;
    RenderObject? current = target;
    Element? anchor;
    while (current != null) {
      final Object? creator = current.debugCreator;
      if (creator is DebugCreator) {
        anchor = creator.element;
        break;
      }
      current = current.parent;
    }
    if (anchor == null) return null;
    if (identical(anchor.renderObject, target)) return anchor;
    return _dfsForRenderObject(anchor, target) ?? anchor;
  }

  /// 在锚点子树内查找目标 RenderObject 的 owner Element。
  /// 每个 RenderObject 只有一个 RenderObjectElement owner，
  /// ComponentElement 的 renderObject 只是穿透引用，不能作为匹配依据。
  Element? _dfsForRenderObject(Element element, RenderObject target) {
    if (element is RenderObjectElement &&
        identical(element.renderObject, target)) {
      return element;
    }
    Element? found;
    element.visitChildElements((Element child) {
      if (found != null) return;
      found = _dfsForRenderObject(child, target);
    });
    return found;
  }

  /// 从命中 Element 开始（含自身）向上收集类型链；黑名单命中丢弃整条事件。
  ///
  /// Element 无公开 parent getter，走公开 API visitAncestorElements。
  /// 噪声类型跳过不收集但继续遍历；遍历硬上限 [_maxWalkDepth]，
  /// 收集条数上限用 config.maxDepth。
  XBAutoTrackFingerprint? _build(Element start) {
    final config = _config;
    final List<String> types = <String>[];

    String? text;
    var walkDepth = 0;
    var dropped = false;

    void handle(Element element) {
      final String typeName = element.widget.runtimeType.toString();
      if (_isBlacklisted(typeName)) {
        dropped = true;
        return;
      }
      if (_isNoise(typeName)) return;
      text ??= _extractText(element.widget);
      types.insert(0, typeName);
    }

    handle(start);
    if (!dropped) {
      start.visitAncestorElements((Element ancestor) {
        walkDepth++;
        if (walkDepth > _maxWalkDepth ||
            dropped ||
            types.length > config.maxDepth) {
          return false;
        }
        handle(ancestor);
        return !dropped;
      });
    }
    if (dropped || types.isEmpty) return null;

    final location = _captureCreationLocation(start);
    return XBAutoTrackFingerprint(
      typeChain: types,
      depth: types.length,
      routeName: _routeNameOf(start),
      text: text,
      file: location?['file']?.toString(),
      line: (location?['line'] as num?)?.toInt(),
      column: (location?['column'] as num?)?.toInt(),
    );
  }

  /// 读取命中组件构造点的源码位置。
  ///
  /// 与 xb_ume locator 同款机制：`--track-widget-creation` 把每个 Widget
  /// 构造调用的位置编译进产物，经 widget inspector 诊断序列化读取。
  /// release 产物剥离该数据，返回 null 自然降级；异常静默不影响采集。
  Map<String, dynamic>? _captureCreationLocation(Element element) {
    try {
      final jsonNode = element.toDiagnosticsNode().toJsonMap(
            InspectorSerializationDelegate(
              service: WidgetInspectorService.instance,
              includeProperties: false,
              subtreeDepth: 1,
            ),
          );
      final location = jsonNode['creationLocation'];
      if (location is Map) return location.cast<String, dynamic>();
    } catch (_) {
      // 位置拿不到不阻断指纹。
    }
    return null;
  }

  bool _isBlacklisted(String typeName) {
    for (final prefix in _config.blacklist) {
      if (prefix.isNotEmpty && typeName.startsWith(prefix)) return true;
    }
    return false;
  }

  bool _isNoise(String typeName) {
    if (_noiseTypes.contains(typeName)) return true;
    for (final extra in _config.extraNoiseTypes) {
      if (extra.isNotEmpty && typeName.startsWith(extra)) return true;
    }
    return false;
  }

  /// 提取链上首个可读文本。Text 是组合组件（内部经 RichText 渲染），
  /// 命中 RenderParagraph 时反查到的 Element 对应 RichText，故一并处理。
  String? _extractText(Widget widget) {
    if (widget is Text) {
      final plain = widget.data ?? widget.textSpan?.toPlainText();
      return _clip(plain);
    }
    if (widget is RichText) {
      return _clip(widget.text.toPlainText());
    }
    if (widget is EditableText) {
      return _clip(widget.controller.text);
    }
    return null;
  }

  String? _clip(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.length <= _config.textMaxLength) return trimmed;
    return '${trimmed.substring(0, _config.textMaxLength)}…';
  }

  /// 路由名：ModalRoute 沿 Element 向上查找，代价与链遍历同阶且只调一次。
  String? _routeNameOf(Element element) {
    try {
      return ModalRoute.of(element)?.settings.name;
    } catch (_) {
      return null;
    }
  }
}
