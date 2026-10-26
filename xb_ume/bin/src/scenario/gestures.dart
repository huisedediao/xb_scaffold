// 手势注入序列（MCP 与 CLI runner 共用）。
//
// 关键经验（均为实测踩坑）：
//   - PointerDownEvent 必须用唯一 pointer id，否则业务异常导致 up 未派发时
//     _hitTests 残留会让后续注入撞断言永久卡死；
//   - PointerMoveEvent 必须显式传 delta 与非零递增 timeStamp，否则
//     DragGestureRecognizer 永远达不到 18px touchSlop，滑动无反应；
//   - VM eval 必须是单行 IIFE。
library;

import 'expressions.dart';
import 'inject.dart';
import 'vm_client.dart';

/// 屏幕逻辑尺寸（宽, 高, dpr）；读取失败返回 null。
Future<(double, double, double)?> screenInfo(VmClient vm) async {
  try {
    final s = await vm.evalStringOn(kLibBinding, screenInfoExpr);
    final p = s.split('\u0001');
    if (p.length < 3) return null;
    final dpr = double.tryParse(p[0]) ?? 1;
    final w = double.tryParse(p[1]);
    final h = double.tryParse(p[2]);
    if (w == null || h == null) return null;
    return (w, h, dpr);
  } catch (_) {
    return null;
  }
}

/// 注入一次滑动（逻辑坐标；phys=true 表示入参为截图物理像素）。
///
/// 返回 (actual, error)：error 为空即成功。
Future<(String, String)> swipeSequence(
  VmClient vm, {
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
  String px(double v) => phys ? '($v / d)' : v.toString();
  final pid = nextPointerId();
  final tsBase = DateTime.now().microsecondsSinceEpoch;

  String downReply;
  try {
    downReply = await evalInject(
        vm,
        kLibBinding,
        '(() { $unstickPrelude$busyGuard'
        'final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; '
        'try { GestureBinding.instance.handlePointerEvent('
        'PointerDownEvent(pointer: $pid, position: Offset(${px(x1)}, ${px(y1)}), '
        'timeStamp: Duration(microseconds: $tsBase))); } catch (e) { '
        'GestureBinding.instance.handlePointerEvent('
        'PointerUpEvent(pointer: $pid, position: Offset(${px(x1)}, ${px(y1)}))); '
        "return 'ERR:' + e.toString(); } return 'OK'; })()");
  } catch (e) {
    return ('', 'swipe down 注入失败: $e');
  }
  if (downReply != 'OK') {
    if (downReply == 'BUSY') return ('', busyHint);
    final d = downReply.startsWith('ERR:') ? downReply.substring(4) : downReply;
    return ('', 'swipe down 异常: $d');
  }

  var pmx = x1;
  var pmy = y1;
  for (var i = 1; i <= seg; i++) {
    final t = i / seg;
    final mx = x1 + (x2 - x1) * t;
    final my = y1 + (y2 - y1) * t;
    final tsUs = tsBase + (ms * 1000 * t).round();
    String moveReply;
    try {
      // move 同样要避开帧内相位：拖拽回调会直接改 ScrollPosition，
      // 若插到 layout 中执行会撞 `scroll_position.dart` 的 persistentCallbacks 断言。
      moveReply = await evalInject(
          vm,
          kLibBinding,
          '(() { $busyGuard'
          'final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; '
          'GestureBinding.instance.handlePointerEvent('
          'PointerMoveEvent(pointer: $pid, position: Offset(${px(mx)}, ${px(my)}), '
          'delta: Offset(${px(mx)} - ${px(pmx)}, ${px(my)} - ${px(pmy)}), '
          "timeStamp: Duration(microseconds: $tsUs))); return 'OK'; })()",
          tries: 40);
    } catch (e) {
      await _safeUp(vm, pid, px(x2), px(y2), tsBase + ms * 1000);
      return ('', 'swipe move 注入失败: $e');
    }
    if (moveReply != 'OK') {
      await _safeUp(vm, pid, px(x2), px(y2), tsBase + ms * 1000);
      return (
        '',
        moveReply == 'BUSY' ? busyHint : 'swipe move 异常: $moveReply'
      );
    }
    pmx = mx;
    pmy = my;
    await Future<void>.delayed(Duration(milliseconds: moveMs));
  }
  await _safeUp(vm, pid, px(x2), px(y2), tsBase + ms * 1000);
  return (
    'swipe (${x1.round()},${y1.round()})->(${x2.round()},${y2.round()}) ${ms}ms',
    ''
  );
}

/// up 必须发出（释放指针），失败静默——异常路径已在上层报告。
///
/// 用 [evalInject] 等到安全相位再发：up 会结束拖拽并触发惯性/回弹，
/// 插在 layout 里同样会撞滚动位置断言。
Future<void> _safeUp(
    VmClient vm, int pid, String x, String y, int tsUs) async {
  try {
    await evalInject(
        vm,
        kLibBinding,
        '(() { $busyGuard'
        'final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; '
        'GestureBinding.instance.handlePointerEvent('
        'PointerUpEvent(pointer: $pid, position: Offset($x, $y), '
        "timeStamp: Duration(microseconds: $tsUs))); return 'OK'; })()",
        tries: 40);
  } catch (_) {
    // 指针可能已被上层释放，忽略。
  }
}

/// 方向滑动：按屏幕逻辑尺寸取起点/终点（留 12% 边距）。
Future<(String, String)> swipeByDirection(
  VmClient vm,
  String direction, {
  double? distance,
  int durationMs = 300,
}) async {
  final info = await screenInfo(vm);
  if (info == null) return ('', '无法读取屏幕尺寸（会话可能已断开）');
  final (w, h, _) = info;
  final dir = direction.toLowerCase();
  final vertical = dir == 'up' || dir == 'down';
  final maxLen = (vertical ? h : w) * 0.76;
  final len = (distance ?? maxLen).clamp(40, maxLen);
  final cx = w / 2;
  final cy = h / 2;
  double x1, y1, x2, y2;
  switch (dir) {
    case 'up':
      x1 = cx;
      y1 = cy + len / 2;
      x2 = cx;
      y2 = cy - len / 2;
    case 'down':
      x1 = cx;
      y1 = cy - len / 2;
      x2 = cx;
      y2 = cy + len / 2;
    case 'left':
      x1 = cx + len / 2;
      y1 = cy;
      x2 = cx - len / 2;
      y2 = cy;
    case 'right':
      x1 = cx - len / 2;
      y1 = cy;
      x2 = cx + len / 2;
      y2 = cy;
    default:
      return ('', '不支持的方向 $direction（up/down/left/right）');
  }
  return swipeSequence(
    vm,
    x1: x1,
    y1: y1,
    x2: x2,
    y2: y2,
    durationMs: durationMs,
  );
}
