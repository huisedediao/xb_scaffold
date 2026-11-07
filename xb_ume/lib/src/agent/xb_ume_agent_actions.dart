// 直连 Agent 的「组件树 / 动作 / 截图」实现（app 进程内，AOT 可用）。
//
// 与 VM 表达式（bin/src/scenario/expressions.dart）刻意保持同一套语义：
//   - Element 遍历顺序 = 栈式 DFS（根先访问，子节点按正序），`ref` 就是这个序号，
//     所以 find_widget 给的 ref 可以直接喂给 tap / swipe；
//   - findWidget 输出行格式与 VM 版**逐字节相同**（字段 \u0001、行 \u0003、7 列），
//     主机侧解析代码一行都不用改；
//   - 类型名支持泛型前缀匹配（`Foo<int>` 命中 `Foo`）；
//   - 注入前等安全帧相位（VM 侧靠 busyGuard 返回 BUSY 重试，这里是普通 Dart 代码，
//     直接等 persistentCallbacks 过去再发）。
//
// 唯一的硬差别：AOT 没有 kernel，`creationLocation` 取不到，所以 source 列恒为空，
// 截图也不再依赖 inspector（直接读根 Layer / RepaintBoundary 光栅化）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 字段分隔符（与 VM 表达式一致）。
const String kAgentSep = '\u0001';

/// 行分隔符（与 VM 表达式一致）。
const String kAgentRow = '\u0003';

/// 已初始化的 WidgetsBinding；纯 Dart / 单元测试环境里可能还没有（返回 null）。
WidgetsBinding? agentBindingOrNull() {
  try {
    return WidgetsBinding.instance;
  } catch (_) {
    return null;
  }
}

/// 首帧前（或没 binding 时）为 null。
Element? agentRootElement() => agentBindingOrNull()?.rootElement;

/// 全树先序遍历（顺序与 VM 侧栈式 DFS 相同）。
Iterable<Element> agentWalkElements() sync* {
  final root = agentRootElement();
  if (root == null) return;
  yield* _walk(root);
}

Iterable<Element> _walk(Element e) sync* {
  yield e;
  final kids = <Element>[];
  e.visitChildren(kids.add);
  for (final k in kids) {
    yield* _walk(k);
  }
}

String _typeOf(Element e) {
  try {
    return e.widget.runtimeType.toString();
  } catch (_) {
    return '';
  }
}

bool _typeMatches(String type, String want) {
  if (type == want) return true;
  final g = type.indexOf('<');
  return g > 0 && type.substring(0, g) == want;
}

String _textOf(Element e) {
  try {
    final w = e.widget;
    if (w is Text) return w.data ?? '';
    if (w is EditableText) return w.controller.text;
  } catch (_) {
    // 个别自定义 widget 的属性访问会抛，按空文本处理。
  }
  return '';
}

String _keyOf(Element e) {
  var k = '';
  try {
    final key = e.widget.key;
    if (key != null) {
      k = key.toString();
      if (k.length > 60) k = k.substring(0, 60);
    }
  } catch (_) {
    // key.toString() 允许被覆写抛异常。
  }
  return k;
}

/// 逻辑像素包围盒：`x,y,w,h`；无 RenderBox 时返回空串（与 VM 版一致）。
String _boundsOf(Element e) {
  final r = e.renderObject;
  if (r is RenderBox && r.attached) {
    final p = r.localToGlobal(r.paintBounds.topLeft);
    return '${p.dx.round()},${p.dy.round()},'
        '${r.paintBounds.width.round()},${r.paintBounds.height.round()}';
  }
  return '';
}

String _clean(String s, {int max = 0}) {
  var t = s
      .replaceAll(kAgentSep, ' ')
      .replaceAll('\u0002', ' ')
      .replaceAll(kAgentRow, ' ');
  if (max > 0 && t.length > max) t = t.substring(0, max);
  return t;
}

/// 按条件查找组件，返回与 VM `findWidgetExpr` 相同格式的原始串。
///
/// 每行 7 列：`ref \u0001 depth \u0001 type \u0001 key \u0001 bounds \u0001 text \u0001 source`。
/// 无渲染树返回 `NO_ROOT`，无命中返回 `NOT_FOUND`（主机侧解析靠这两个哨兵值）。
String agentFindWidgetsRaw({
  required String by,
  required String value,
  bool exact = false,
  int limit = 20,
}) {
  final root = agentRootElement();
  if (root == null) return 'NO_ROOT';
  final out = StringBuffer();
  var idx = 0;
  var hits = 0;
  bool ok(Element e) {
    switch (by) {
      case 'key':
        final k = _keyOf(e);
        return k.isNotEmpty && (exact ? k == value : k.contains(value));
      case 'text':
        final t = _textOf(e);
        return t.isNotEmpty && (exact ? t == value : t.contains(value));
      case 'semantics':
        try {
          final w = e.widget;
          if (w is Semantics) {
            final lb = w.properties.label;
            return lb != null && (exact ? lb == value : lb.contains(value));
          }
        } catch (_) {
          // 语义属性可能尚未构建。
        }
        return false;
      default:
        return _typeMatches(_typeOf(e), value);
    }
  }

  final stack = <(Element, int)>[(root, 0)];
  while (stack.isNotEmpty) {
    final (e, d) = stack.removeLast();
    if (ok(e)) {
      out
        ..write(idx)
        ..write(kAgentSep)
        ..write(d)
        ..write(kAgentSep)
        ..write(_typeOf(e))
        ..write(kAgentSep)
        ..write(_keyOf(e))
        ..write(kAgentSep)
        ..write(_boundsOf(e))
        ..write(kAgentSep)
        ..write(_clean(_textOf(e), max: 200))
        ..write(kAgentSep)
        // AOT 无 creationLocation：保持空列，主机侧按「无源码位置」展示。
        ..write('')
        ..write(kAgentRow);
      hits++;
      if (hits >= limit) break;
    }
    idx++;
    final kids = <Element>[];
    e.visitChildren(kids.add);
    for (var i = kids.length - 1; i >= 0; i--) {
      stack.add((kids[i], d + 1));
    }
  }
  return out.isEmpty ? 'NOT_FOUND' : out.toString();
}

/// 第 [ref] 个 Element（序号与 [agentFindWidgetsRaw] 同一套遍历）。
Element? agentElementAt(int ref) {
  if (ref < 0) return null;
  var i = 0;
  for (final e in agentWalkElements()) {
    if (i++ == ref) return e;
  }
  return null;
}

/// 组件树快照：与 GUI `/api/wtree` 返回结构一致（d/t/k/b + 画面元信息）。
Map<String, Object?> agentWidgetTreeJson({int maxNodes = 4000}) {
  final binding = agentBindingOrNull();
  final root = binding?.rootElement;
  final views = binding?.platformDispatcher.views ?? const <FlutterView>[];
  final view = views.isEmpty ? null : views.first;
  if (root == null || view == null) return <String, Object?>{'ok': false};
  final nodes = <Map<String, Object?>>[];
  final stack = <(Element, int)>[(root, 0)];
  while (stack.isNotEmpty && nodes.length < maxNodes) {
    final (e, d) = stack.removeLast();
    final b = _boundsOf(e);
    nodes.add(<String, Object?>{
      'd': d,
      't': _typeOf(e),
      'k': _keyOf(e),
      'b': b.isEmpty
          ? null
          : <int>[
              for (final p in b.split(',')) int.tryParse(p) ?? 0,
            ],
    });
    final kids = <Element>[];
    e.visitChildren(kids.add);
    for (var i = kids.length - 1; i >= 0; i--) {
      stack.add((kids[i], d + 1));
    }
  }
  return <String, Object?>{
    'ok': true,
    'nodes': nodes,
    'dpr': view.devicePixelRatio,
    'physW': view.physicalSize.width.round(),
    'physH': view.physicalSize.height.round(),
  };
}

/// 屏幕信息：`dpr \u0001 逻辑宽 \u0001 逻辑高`（与 VM `screenInfoExpr` 同形）。
String agentScreenInfoRaw() {
  final views = agentBindingOrNull()?.platformDispatcher.views;
  if (views == null || views.isEmpty) return '1\u00010\u00010';
  final v = views.first;
  final dpr = v.devicePixelRatio;
  final s = v.physicalSize / dpr;
  return '${dpr.toStringAsFixed(2)}\u0001'
      '${s.width.toStringAsFixed(1)}\u0001${s.height.toStringAsFixed(1)}';
}

/// 第 [ref] 个 Element 的中心点：`x,y`（两位小数）；失败返回同 VM 的哨兵值。
String agentElementCenterRaw(int ref) {
  final e = agentElementAt(ref);
  if (e == null) return agentRootElement() == null ? 'NO_ROOT' : 'NOT_FOUND';
  final r = e.renderObject;
  if (r is! RenderBox || !r.attached || !r.hasSize) return 'NO_BOX';
  if (r.size.width <= 0 || r.size.height <= 0) return 'ZERO_SIZE';
  final c = r.localToGlobal(r.size.center(Offset.zero));
  return '${c.dx.toStringAsFixed(1)},${c.dy.toStringAsFixed(1)}';
}

/// 是否处于「可以安全改界面」的帧相位。
Future<bool> _waitSafePhase({int tries = 40}) async {
  for (var i = 0; i < tries; i++) {
    // 没 binding（纯 Dart / 测试）时无从判断，直接放行，由调用方兜底。
    final binding = agentBindingOrNull();
    if (binding == null) return true;
    final phase = binding.schedulerPhase;
    if (phase != SchedulerPhase.persistentCallbacks &&
        phase != SchedulerPhase.midFrameMicrotasks) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
  return false;
}

int _pointerSeed = 1000;

/// 注入手势用的 pointer id：与真实触摸（通常从 1 起）错开，避免撞上残留 hit test。
int agentNextPointerId() => ++_pointerSeed;

String _errText(Object e) {
  final s = e.toString().split('\n').first;
  return 'ERR:${e.runtimeType}:$s';
}

Future<String> agentTapAt(
  double x,
  double y, {
  bool phys = false,
  int? pointer,
}) async {
  if (!await _waitSafePhase()) return 'BUSY';
  final views = agentBindingOrNull()?.platformDispatcher.views;
  if (views == null || views.isEmpty) return 'NO_BINDING';
  final dpr = views.first.devicePixelRatio;
  final pos = phys ? Offset(x / dpr, y / dpr) : Offset(x, y);
  final pid = pointer ?? agentNextPointerId();
  final down = PointerDownEvent(pointer: pid, position: pos);
  final up = PointerUpEvent(pointer: pid, position: pos);
  try {
    GestureBinding.instance.handlePointerEvent(down);
    GestureBinding.instance.handlePointerEvent(up);
  } catch (e) {
    // up 必须尽量发出，否则 _hitTests 残留会让后续注入撞断言。
    try {
      GestureBinding.instance.handlePointerEvent(up);
    } catch (_) {
      // 已经释放过就忽略。
    }
    return _errText(e);
  }
  return 'OK:${pos.dx.round()},${pos.dy.round()}';
}

Future<String> agentTapRef(int ref, {int? pointer}) async {
  final e = agentElementAt(ref);
  if (e == null) return agentRootElement() == null ? 'NO_ROOT' : 'NOT_FOUND';
  final r = e.renderObject;
  if (r is! RenderBox || !r.attached || !r.hasSize) return 'NO_BOX';
  if (r.size.width <= 0 || r.size.height <= 0) return 'ZERO_SIZE';
  final c = r.localToGlobal(r.size.center(Offset.zero));
  return agentTapAt(c.dx, c.dy, pointer: pointer);
}

/// 向当前焦点输入框整体替换文本。
///
/// 走 `EditableText.controller`（public API）。VM 侧用 TextInput 连接直接
/// updateEditingValue，这里等价地写 controller.value：监听链会走
/// onChanged + 平台同步，只是不依赖 text_input 的私有连接。
String agentInputText(String text) {
  for (final e in agentWalkElements()) {
    final w = e.widget;
    if (w is EditableText && w.focusNode.hasFocus) {
      try {
        w.controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        return 'OK';
      } catch (e2) {
        return _errText(e2);
      }
    }
  }
  return 'NO_CONN';
}

/// 树中是否有类型匹配且有尺寸的 RenderBox（与 VM `assertVisibleExpr` 同义）。
String agentAssertVisibleRaw(String type) {
  if (agentRootElement() == null) return 'NO_ROOT';
  for (final e in agentWalkElements()) {
    if (!_typeMatches(_typeOf(e), type)) continue;
    final r = e.renderObject;
    if (r is RenderBox &&
        r.attached &&
        r.hasSize &&
        r.size.width > 0 &&
        r.size.height > 0) {
      return 'FOUND';
    }
  }
  return 'NOT_FOUND';
}

/// 当前页面可见文本（跳过 Offstage 子树），`\u0002` 分隔（与 VM 版一致）。
String agentPageTextRaw({int limit = 200}) {
  final root = agentRootElement();
  if (root == null) return '';
  final out = <String>[];
  final seen = <String>{};
  void visit(Element e) {
    if (out.length >= limit) return;
    final w = e.widget;
    if (w is Offstage && w.offstage) return;
    final t = _textOf(e).trim();
    if (t.isNotEmpty && seen.add(t)) out.add(t);
    final kids = <Element>[];
    e.visitChildren(kids.add);
    for (final k in kids) {
      visit(k);
    }
  }

  visit(root);
  return out.join('\u0002');
}

/// 滑动：与主机侧 swipeSequence 同样的 8 段 move + 非零 delta/timeStamp，
/// 但整段循环在 app 内跑，避免每段一次 HTTP 往返把拖拽拖成慢动作。
Future<(String, String)> agentSwipe({
  required double x1,
  required double y1,
  required double x2,
  required double y2,
  int durationMs = 300,
  bool phys = false,
}) async {
  final ms = durationMs.clamp(40, 5000);
  const seg = 8;
  final moveMs = (ms / seg).round().clamp(16, 200);
  final views = agentBindingOrNull()?.platformDispatcher.views;
  final dpr = (views == null || views.isEmpty) ? 1.0 : views.first.devicePixelRatio;
  Offset p(double x, double y) =>
      phys ? Offset(x / dpr, y / dpr) : Offset(x, y);
  final pid = agentNextPointerId();
  final tsBase = DateTime.now().microsecondsSinceEpoch;
  if (!await _waitSafePhase()) return ('', '应用正在绘制帧，注入被推迟后仍未成功，请重试');
  try {
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(
      pointer: pid,
      position: p(x1, y1),
      timeStamp: Duration(microseconds: tsBase),
    ));
  } catch (e) {
    try {
      GestureBinding.instance
          .handlePointerEvent(PointerUpEvent(pointer: pid, position: p(x1, y1)));
    } catch (_) {
      // 释放失败无需处理。
    }
    return ('', 'swipe down 异常: $e');
  }
  var pm = p(x1, y1);
  for (var i = 1; i <= seg; i++) {
    final t = i / seg;
    final cur = p(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
    final tsUs = tsBase + (ms * 1000 * t).round();
    try {
      GestureBinding.instance.handlePointerEvent(PointerMoveEvent(
        pointer: pid,
        position: cur,
        delta: cur - pm,
        timeStamp: Duration(microseconds: tsUs),
      ));
    } catch (e) {
      await _safeUp(pid, p(x2, y2), tsBase + ms * 1000);
      return ('', 'swipe move 异常: $e');
    }
    pm = cur;
    await Future<void>.delayed(Duration(milliseconds: moveMs));
  }
  await _safeUp(pid, p(x2, y2), tsBase + ms * 1000);
  return (
    'swipe (${x1.round()},${y1.round()})->(${x2.round()},${y2.round()}) ${ms}ms',
    ''
  );
}

Future<void> _safeUp(int pid, Offset pos, int tsUs) async {
  await _waitSafePhase();
  try {
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(
      pointer: pid,
      position: pos,
      timeStamp: Duration(microseconds: tsUs),
    ));
  } catch (_) {
    // 指针可能已被上层释放。
  }
}

/// 路由操作：`pop` / `push`（名字跳转）。返回与 VM 版相同的哨兵值。
Future<String> agentRouteOp(String op, {String name = ''}) async {
  NavigatorState? nav;
  for (final e in agentWalkElements()) {
    final s = e is StatefulElement ? e.state : null;
    if (s is NavigatorState) {
      nav = s;
      break;
    }
  }
  if (nav == null) return 'NO_NAV';
  if (!await _waitSafePhase()) return 'BUSY';
  if (op == 'pop') {
    try {
      if (!nav.canPop()) return 'LAST_ROUTE';
      nav.pop();
      return 'OK';
    } catch (e) {
      return _errText(e);
    }
  }
  if (nav.widget.onGenerateRoute == null) return 'NO_ROUTE_TABLE';
  try {
    nav.pushNamed(name);
    return 'OK';
  } catch (e) {
    final msg = e.toString();
    if (msg.contains('Could not find a generator')) return 'UNKNOWN';
    return _errText(e);
  }
}

/// 截图：优先读根 Layer 光栅化（整屏），失败再退到面积最大的
/// RenderRepaintBoundary。返回 `{ok,data,width,height}`。
Future<Map<String, Object?>> agentScreenshot({double? pixelRatio}) async {
  final root = agentRootElement();
  if (root == null) {
    return <String, Object?>{'ok': false, 'error': 'app 尚未渲染首帧'};
  }
  final rv = root.renderObject;
  var pr = pixelRatio;
  Size? logical;
  if (rv is RenderView) {
    logical = rv.size;
    pr ??= rv.configuration.devicePixelRatio;
  }
  ui.Image? img;
  Object? firstError;
  try {
    final layer = rv?.debugLayer;
    if (layer is OffsetLayer &&
        logical != null &&
        logical.width > 0 &&
        logical.height > 0) {
      img = await layer.toImage(Offset.zero & logical, pixelRatio: pr ?? 1.0);
    }
  } catch (e) {
    firstError = e;
    img = null;
  }
  if (img == null) {
    RenderRepaintBoundary? best;
    var bestArea = 0.0;
    for (final e in agentWalkElements()) {
      final r = e.renderObject;
      if (r is RenderRepaintBoundary && r.attached && r.hasSize) {
        final a = r.size.width * r.size.height;
        if (a > bestArea) {
          bestArea = a;
          best = r;
        }
      }
    }
    if (best == null) {
      return <String, Object?>{
        'ok': false,
        'error': '没有可截图的渲染层'
            '${firstError == null ? '' : '：$firstError'}',
      };
    }
    try {
      img = await best.toImage(pixelRatio: pr ?? 1.0);
    } catch (e) {
      return <String, Object?>{'ok': false, 'error': '$e'};
    }
  }
  final image = img;
  try {
    final bd = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bd == null) {
      return <String, Object?>{'ok': false, 'error': 'PNG 编码失败'};
    }
    return <String, Object?>{
      'ok': true,
      'data': base64Encode(bd.buffer.asUint8List()),
      'width': image.width,
      'height': image.height,
    };
  } finally {
    image.dispose();
  }
}