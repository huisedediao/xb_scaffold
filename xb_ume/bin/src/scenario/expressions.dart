// VM evaluate 表达式集合（与 bin/ide_gui.dart、bin/src/scenario/runner.dart
// 中已实测的版本同源）。
//
// 约定：
//   - 表达式必须是单行 IIFE（VM eval 对多行 IIFE 会返回未调用的 Closure）；
//   - 分隔符统一用 String.fromCharCode(N) 在表达式内构造，避免多层转义；
//   - 同一段遍历顺序（栈 + 逆序 push children）保证 find 与 tap 的索引一致。
library;

/// 常用 evaluate 库上下文：表达式里的符号可见性由所在库决定。
const String kLibBinding = 'package:flutter/src/widgets/binding.dart';
const String kLibTextInput = 'package:flutter/src/services/text_input.dart';
const String kLibNavigator = 'package:flutter/src/widgets/navigator.dart';
const String kLibXbUme = 'package:xb_ume/src/core/xb_ume.dart';
const String kLibStoreRegistry =
    'package:xb_ume/src/core/xb_ume_store_registry.dart';

/// 任意文本嵌入 evaluate 字符串字面量的转义（$ 与引号必须转义）。
String escapeEvalString(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll(r'$', r'\$')
    .replaceAll("'", r"\'")
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll('\t', r'\t');

/// 每次注入唯一 pointer id：down 派发中业务异常导致 up 未发时，_hitTests
/// 残留 pointer 0 会让后续 tap 撞断言永久卡死（f_jlink 实测）。
int nextPointerId() => DateTime.now().microsecondsSinceEpoch & 0x3fffffff;

/// Element 树全量（binding.dart 上下文）。
/// 输出：每行 深度\u0001类型\u0001key\u0001bounds(x,y,w,h 逻辑像素，无则空)\u0003；
/// 末尾空行 + dpr\u0001物理宽\u0001物理高。
const String wtreeExpr =
    "(() { final v = WidgetsBinding.instance.platformDispatcher.views.first; "
    "final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return 'NO_ROOT'; "
    "final out = StringBuffer(); final sep = String.fromCharCode(1); "
    "final row = String.fromCharCode(3); final se = <Element>[root]; final sd = <int>[0]; "
    "while (se.isNotEmpty) { final e = se.removeLast(); final d = sd.removeLast(); "
    "var b = ''; final r = e.renderObject; "
    "if (r is RenderBox && r.attached) { final p = r.localToGlobal(r.paintBounds.topLeft); "
    "b = p.dx.round().toString() + ',' + p.dy.round().toString() + ',' "
    "+ r.paintBounds.width.round().toString() + ',' + r.paintBounds.height.round().toString(); } "
    "var k = ''; final key = e.widget.key; if (key != null) { k = key.toString(); "
    "if (k.length > 60) { k = k.substring(0, 60); } } "
    "out.write(d.toString()); out.write(sep); out.write(e.widget.runtimeType.toString()); "
    "out.write(sep); out.write(k); out.write(sep); out.write(b); out.write(row); "
    "final kids = <Element>[]; e.visitChildren(kids.add); "
    "for (var i = kids.length - 1; i >= 0; i--) { se.add(kids[i]); sd.add(d + 1); } } "
    "out.write(row); out.write(v.devicePixelRatio.toString()); out.write(sep); "
    "out.write(v.physicalSize.width.round().toString()); out.write(sep); "
    "out.write(v.physicalSize.height.round().toString()); return out.toString(); })()";

/// 页面可见文本（binding.dart 上下文），条目以 \u0002 分隔。
/// Offstage 子树（下层页面保活）跳过，避免误导。
String pageTextExpr({int limit = 200}) =>
    "(() { final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return ''; "
    "final out = <String>[]; final seen = <String>{}; "
    "void add(String? t) { if (t == null) return; final s = t.trim(); "
    "if (s.isEmpty) return; if (seen.add(s)) out.add(s); } "
    "void visit(Element e) { if (out.length >= $limit) return; "
    "final tn = e.widget.runtimeType.toString(); "
    "if (tn == 'Offstage') { try { if ((e.widget as dynamic).offstage == true) return; } catch (_) {} } "
    "try { if (tn == 'Text') { add((e.widget as dynamic).data as String?); } "
    "else if (tn == 'EditableText') { add((e.widget as dynamic).controller.text as String?); } "
    "} catch (_) {} "
    "e.visitChildren(visit); } visit(root); "
    "return out.join(String.fromCharCode(2)); })()";

/// 路由栈快照（navigator.dart 上下文）：路由名以逗号拼接。
const String routesExpr =
    "(() { final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return 'NO_ROOT'; "
    "final navs = <NavigatorState>[]; "
    "void walk(Element e) { final w = e.widget; "
    "if (w is Navigator && e is StatefulElement && e.state is NavigatorState) "
    "{ navs.add(e.state as NavigatorState); } e.visitChildren(walk); } "
    "root.visitChildren(walk); "
    "if (navs.isEmpty) return 'NO_NAV'; "
    "final out = StringBuffer(); "
    "for (final h in navs[0]._history) { if (!h.isPresent) continue; "
    "out.write(h.route.settings.name); "
    "out.write(String.fromCharCode(44)); } return out.toString(); })()";

/// 帧内注入守卫。
///
/// VM `evaluate` 会在安全点插入到应用**当前调用栈中间**执行：如果那时正好在
/// build/layout/paint（persistentCallbacks）里，注入的指针或路由变更就会从
/// 布局内部改写 widget 树（`setState` → `Build scheduled during frame.`），
/// 严重时会把 Navigator 事务卡死（页面停在动画起点、`_debugLocked` 不复位）。
/// 命中不安全相位时返回 BUSY，由调用方等待下一帧重试。
const String busyGuard =
    "final _phase = SchedulerBinding.instance.schedulerPhase; "
    "if (_phase == SchedulerPhase.persistentCallbacks || "
    "_phase == SchedulerPhase.midFrameMicrotasks) return 'BUSY'; ";

/// 指针注入前置语句：复位“卡住”的 Navigator AbsorbPointer。
///
/// Navigator 在每次路由变更后会把内层 AbsorbPointer 直接置为 absorbing=true，
/// 依赖下一帧 rebuild 复位；窗口被遮挡时引擎不产帧，该状态会永久保留，
/// 导致其后注入的所有指针都被静默吞掉（表现为 tap 返回 OK 但界面无反应）。
const String unstickPrelude =
    "final _root0 = WidgetsBinding.instance.renderViewElement; "
    "if (_root0 != null) { "
    "final _se = <Element>[_root0]; "
    "while (_se.isNotEmpty) { final _e = _se.removeLast(); "
    "final _ro = _e.renderObject; "
    "if (_ro != null && _ro.runtimeType.toString() == 'RenderAbsorbPointer') { "
    "try { if ((_ro as dynamic).absorbing == true && "
    "_ro.debugCreator.toString().contains('Navigator')) { "
    "(_ro as dynamic).absorbing = false; } } catch (_) {} } "
    "_e.visitChildren(_se.add); } } "
    "try { SchedulerBinding.instance.scheduleFrame(); } catch (_) {} ";

/// 点位 tap：GestureBinding.handlePointerEvent down+up 同点（binding.dart）。
/// phys=true 时入参是截图物理像素，表达式内先除 dpr。
String tapExpr(String x, String y, {bool phys = false, int pointer = 0}) {
  final pos = phys
      ? "final pos = Offset($x, $y) / WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; "
      : "final pos = Offset($x, $y); ";
  return "(() { $unstickPrelude$busyGuard$pos"
      "final pe = PointerDownEvent(pointer: $pointer, position: pos); "
      "final ue = PointerUpEvent(pointer: $pointer, position: pos); "
      // up 派发才是 onTap 执行点，业务异常会从这里逃出 eval；必须就地兜住，
      // 否则 eval 栈里的 `Eval.<anonymous closure>` 帧会让框架的栈格式化断言二次崩溃。
      "try { GestureBinding.instance.handlePointerEvent(pe); "
      "GestureBinding.instance.handlePointerEvent(ue); } catch (e) { "
      "try { GestureBinding.instance.handlePointerEvent(ue); } catch (_) {} "
      "return 'ERR:' + e.runtimeType.toString() + ':' + e.toString().split(String.fromCharCode(10)).first; } "
      "return 'OK'; })()";
}

/// 向当前焦点输入框写文本（text_input.dart 上下文，_instance 是库内私有）。
String inputExpr(String text) =>
    "(() { final c = TextInput._instance._currentConnection; "
    "if (c == null) return 'NO_CONN'; "
    "final s = '${escapeEvalString(text)}'; "
    "(c._client as dynamic).updateEditingValue(TextEditingValue("
    "text: s, selection: TextSelection.collapsed(offset: s.length))); "
    "return 'OK'; })()";

/// 树中存在类型匹配（支持泛型前缀）且有尺寸的 RenderBox。
String assertVisibleExpr(String type) {
  final t = escapeEvalString(type);
  return "(() { final root = WidgetsBinding.instance.renderViewElement; "
      "if (root == null) return 'NO_ROOT'; "
      "final se = <Element>[root!]; "
      "while (se.isNotEmpty) { final e = se.removeLast(); "
      "final t = e.widget.runtimeType.toString(); var ok = t == '$t'; "
      "if (!ok) { final g = t.indexOf('<'); if (g > 0 && t.substring(0, g) == '$t') ok = true; } "
      "if (ok) { final r = e.renderObject; if (r is RenderBox && r.attached "
      "&& r.hasSize && r.size.width > 0 && r.size.height > 0) return 'FOUND'; } "
      "final kids = <Element>[]; e.visitChildren(kids.add); "
      "for (var i = kids.length - 1; i >= 0; i--) se.add(kids[i]); } "
      "return 'NOT_FOUND'; })()";
}

/// 按条件查找组件（binding.dart 上下文）。
///
/// 匹配维度：
///   byType  —— runtimeType 含 value（支持泛型前缀精确匹配）
///   byKey   —— key.toString() 含 value
///   byText  —— Text.data / EditableText.controller.text 含 value
///   bySemantics —— Semantics 标签含 value（部分组件才有）
///
/// 输出每行：idx\u0001depth\u0001type\u0001key\u0001bounds\u0001text\u0001file:line:col\u0003
///   idx 是同一 DFS 序号（供 tapElementExpr 精确定位）；
///   bounds 为逻辑像素 x,y,w,h；text 与 source 可能为空。
/// 遍历顺序必须与 tapElementExpr 保持一致。
String findWidgetExpr({
  required String by,
  required String value,
  bool exact = false,
  int limit = 20,
}) {
  final v = escapeEvalString(value);
  // 各分支只给 ok 赋值，声明统一放在循环体内（exact 对所有维度都是全等匹配）。
  // 注意：全等操作符不能写成 `x.==(v)`，所以全等/包含必须拼成两种独立模板。
  String hit(String expr) => exact ? "$expr == '$v'" : "$expr.contains('$v')";
  final cond = switch (by) {
    'key' => "final k = e.widget.key; ok = k != null && ${hit('k.toString()')};",
    'text' => "try { final tn2 = e.widget.runtimeType.toString(); "
        "if (tn2 == 'Text') { final d = (e.widget as dynamic).data; ok = d is String && ${hit('d')}; } "
        "else if (tn2 == 'EditableText') { final t2 = (e.widget as dynamic).controller.text; ok = t2 is String && ${hit('t2')}; } "
        "} catch (_) {}",
    'semantics' => "try { final s2 = (e.widget as dynamic).properties; "
        "if (s2 != null) { final lb = (s2 as dynamic).label; ok = lb is String && ${hit('lb')}; } "
        "} catch (_) {}",
    _ => "final t2 = e.widget.runtimeType.toString(); ok = t2 == '$v'; "
        "if (!ok) { final g = t2.indexOf('<'); if (g > 0 && t2.substring(0, g) == '$v') ok = true; }",
  };
  return "(() { final root = WidgetsBinding.instance.renderViewElement; "
      "if (root == null) return 'NO_ROOT'; "
      "final sep = String.fromCharCode(1); final row = String.fromCharCode(3); "
      "final out = StringBuffer(); var idx = 0; var hits = 0; "
      "final se = <Element>[root]; final sd = <int>[0]; "
      "String loc(Element e) { try { final jm = e.toDiagnosticsNode().toJsonMap("
      "InspectorSerializationDelegate(service: WidgetInspectorService.instance, "
      "includeProperties: false, subtreeDepth: 1)); final l = jm['creationLocation']; "
      "if (l is Map) { final f = (l['file'] ?? '').toString(); "
      "if (f.isNotEmpty) { return f + ':' + ((l['line'] ?? 0)).toString() + ':' "
      "+ ((l['column'] ?? 0)).toString(); } } } catch (_) {} return ''; } "
      "String txt(Element e) { try { final tn = e.widget.runtimeType.toString(); "
      "if (tn == 'Text') { final d = (e.widget as dynamic).data; if (d is String) return d; } "
      "else if (tn == 'EditableText') { return (e.widget as dynamic).controller.text as String? ?? ''; } "
      "} catch (_) {} return ''; } "
      "while (se.isNotEmpty) { final e = se.removeLast(); final d = sd.removeLast(); "
      "var ok = false; $cond "
      "if (ok) { "
      "final tok = idx.toString(); var b = ''; final r = e.renderObject; "
      "if (r is RenderBox && r.attached) { final p = r.localToGlobal(r.paintBounds.topLeft); "
      "b = p.dx.round().toString() + ',' + p.dy.round().toString() + ',' "
      "+ r.paintBounds.width.round().toString() + ',' + r.paintBounds.height.round().toString(); } "
      "var k = ''; final key = e.widget.key; if (key != null) { k = key.toString(); "
      "if (k.length > 60) { k = k.substring(0, 60); } } "
      "out.write(tok); out.write(sep); out.write(d.toString()); "
      "out.write(sep); out.write(e.widget.runtimeType.toString()); out.write(sep); out.write(k); "
      "out.write(sep); out.write(b); out.write(sep); "
      "final tt = txt(e); String ts = tt.replaceAll(String.fromCharCode(1), ' '); "
      "ts = ts.replaceAll(String.fromCharCode(2), ' '); ts = ts.replaceAll(String.fromCharCode(3), ' '); "
      "if (ts.length > 200) { ts = ts.substring(0, 200); } out.write(ts); out.write(sep); "
      "out.write(loc(e)); out.write(row); hits++; if (hits >= $limit) break; } "
      "idx++; final kids = <Element>[]; e.visitChildren(kids.add); "
      "for (var i = kids.length - 1; i >= 0; i--) { se.add(kids[i]); sd.add(d + 1); } } "
      "if (hits == 0 && idx == 0) return 'NO_ROOT'; "
      "return out.isEmpty ? 'NOT_FOUND' : out.toString(); })()";
}

/// 点击第 idx 个 Element 的中心点（遍历顺序与 findWidgetExpr 一致）。
String tapElementExpr(int idx, {int pointer = 0}) =>
    "(() { $unstickPrelude$busyGuard"
    "final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return 'NO_ROOT'; "
    "final se = <Element>[root]; var i = 0; Element? found; "
    "while (se.isNotEmpty) { final e = se.removeLast(); "
    "if (i == $idx) { found = e; break; } i++; "
    "final kids = <Element>[]; e.visitChildren(kids.add); "
    "for (var j = kids.length - 1; j >= 0; j--) se.add(kids[j]); } "
    "if (found == null) return 'NOT_FOUND'; "
    "final r = found!.renderObject; "
    "if (r is! RenderBox || !r.attached || !r.hasSize) return 'NO_BOX'; "
    "if (r.size.width <= 0 || r.size.height <= 0) return 'ZERO_SIZE'; "
    "final c = r.localToGlobal(r.size.center(Offset.zero)); "
    "final pid = $pointer; final pe = PointerDownEvent(pointer: pid, position: c); "
    "final ue = PointerUpEvent(pointer: pid, position: c); "
    "try { GestureBinding.instance.handlePointerEvent(pe); "
    "GestureBinding.instance.handlePointerEvent(ue); } catch (e) { "
    "try { GestureBinding.instance.handlePointerEvent(ue); } catch (_) {} "
    "return 'ERR:' + e.runtimeType.toString() + ':' + e.toString().split(String.fromCharCode(10)).first; } "
    "return 'OK:' + c.dx.round().toString() + ',' + c.dy.round().toString(); })()";

/// 取第 idx 个 Element 的中心点（遍历顺序与 findWidgetExpr 一致，不点击）。
/// 返回：x,y 或 NOT_FOUND / NO_ROOT / NO_BOX / ZERO_SIZE。
String elementCenterExpr(int idx) =>
    "(() { final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return 'NO_ROOT'; "
    "final se = <Element>[root]; var i = 0; Element? found; "
    "while (se.isNotEmpty) { final e = se.removeLast(); "
    "if (i == $idx) { found = e; break; } i++; "
    "final kids = <Element>[]; e.visitChildren(kids.add); "
    "for (var j = kids.length - 1; j >= 0; j--) se.add(kids[j]); } "
    "if (found == null) return 'NOT_FOUND'; "
    "final r = found!.renderObject; "
    "if (r is! RenderBox || !r.attached || !r.hasSize) return 'NO_BOX'; "
    "if (r.size.width <= 0 || r.size.height <= 0) return 'ZERO_SIZE'; "
    "final c = r.localToGlobal(r.size.center(Offset.zero)); "
    "return c.dx.toStringAsFixed(1) + ',' + c.dy.toStringAsFixed(1); })()";

/// 屏幕信息（binding.dart）：dpr\u0001逻辑宽\u0001逻辑高。
const String screenInfoExpr =
    "(() { final v = WidgetsBinding.instance.platformDispatcher.views.first; "
    "final d = v.devicePixelRatio; final s = v.physicalSize / d; "
    "return d.toString() + String.fromCharCode(1) + s.width.toStringAsFixed(1) "
    "+ String.fromCharCode(1) + s.height.toStringAsFixed(1); })()";

/// 路由栈详情（navigator.dart 上下文）。
/// 输出每行：name\u0001routeType\u0001argsType\u0001present\u0003
const String routeStackExpr =
    "(() { final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return 'NO_ROOT'; "
    "final navs = <NavigatorState>[]; "
    "void walk(Element e) { final w = e.widget; "
    "if (w is Navigator && e is StatefulElement && e.state is NavigatorState) "
    "{ navs.add(e.state as NavigatorState); } e.visitChildren(walk); } "
    "root.visitChildren(walk); "
    "if (navs.isEmpty) return 'NO_NAV'; "
    "final sep = String.fromCharCode(1); final row = String.fromCharCode(3); "
    "final out = StringBuffer(); "
    "for (final h in navs[0]._history) { final r = h.route; "
    "final a = r.settings.arguments; "
    "out.write(r.settings.name ?? '-'); out.write(sep); "
    "out.write(r.runtimeType.toString()); out.write(sep); "
    "out.write(a == null ? '-' : a.runtimeType.toString()); out.write(sep); "
    "out.write(h.isPresent ? '1' : '0'); out.write(row); } "
    "return out.toString(); })()";

/// 路由操作（navigator.dart）：pop / pushNamed。返回 OK / LAST_ROUTE / NO_NAV / …
String routeOpExpr(String op, {String name = ''}) {
  const walk = 'final root = WidgetsBinding.instance.renderViewElement; '
      "if (root == null) return 'NO_ROOT'; "
      'final navigators = <NavigatorState>[]; '
      'void walk(Element e) { final w = e.widget; '
      'if (w is Navigator && e is StatefulElement && e.state is NavigatorState) '
      '{ navigators.add(e.state as NavigatorState); } e.visitChildren(walk); } '
      'root.visitChildren(walk); ';
  if (op == 'pop') {
    return '(() { $walk'
        "if (navigators.isEmpty) return 'NO_NAV'; "
        "if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks || "
        "SchedulerBinding.instance.schedulerPhase == SchedulerPhase.midFrameMicrotasks) "
        "return 'BUSY'; "
        "final n = navigators[0]; "
        "final present = n._history.where((final e) => e.isPresent).length; "
        "if (present <= 1) return 'LAST_ROUTE'; "
        // _debugLocked 是 debug 期的重入保护位：某次 pop 中途抛异常时框架不会复位它，
        // 之后所有 pop 都会撞 '!_debugLocked' 断言（release/profile 无此字段，忽略即可）。
        "try { n._debugLocked = false; } catch (_) {} "
        "try { n.pop(); return 'OK'; } catch (e) { "
        "try { n._debugLocked = false; } catch (_) {} "
        "return 'ERR:' + e.runtimeType.toString() + ':' + "
        "e.toString().split(String.fromCharCode(10)).first; } })()";
  }
  return '(() { $walk'
      "if (navigators.isEmpty) return 'NO_NAV'; "
      "if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks || "
      "SchedulerBinding.instance.schedulerPhase == SchedulerPhase.midFrameMicrotasks) "
      "return 'BUSY'; "
      "final n = navigators[0]; "
      "if (n.widget.onGenerateRoute == null) return 'NO_ROUTE_TABLE'; "
      "try { final r = n._routeNamed('${escapeEvalString(name)}', arguments: null); "
      "if (r == null) return 'UNKNOWN'; n.push(r); return 'OK'; "
      "} catch (e) { return 'ERR:' + e.runtimeType.toString() + ':' + "
      "e.toString().split(String.fromCharCode(10)).first; } })()";
}

/// 网络记录（xb_ume core 上下文，与 GUI Network Tab 同源）。
/// 输出每行：method\u0001url\u0001statusCode\u0001status\u0001durationMs\u0001time\u0001error\u0003
String networkExpr({int? sinceMs, int limit = 50}) {
  final filter = sinceMs == null
      ? ''
      : "final c = DateTime.fromMillisecondsSinceEpoch($sinceMs); ";
  final where = sinceMs == null ? '' : '.where((e) => e.time.isAfter(c)) ';
  return "(() { final n = XBUme.controller.network; $filter"
      "final sep = String.fromCharCode(1); final row = String.fromCharCode(3); "
      "final out = StringBuffer(); var c2 = 0; "
      "String clean(Object? s) { final t = (s ?? '').toString(); "
      "return t.replaceAll(String.fromCharCode(1), ' ').replaceAll(String.fromCharCode(2), ' ')"
      ".replaceAll(String.fromCharCode(3), ' '); } "
      "for (final e in n$where) { if (c2 >= $limit) break; c2++; "
      "out.write(clean(e.method)); out.write(sep); out.write(clean(e.url)); out.write(sep); "
      "out.write(clean(e.statusCode)); out.write(sep); out.write(clean(e.status.name)); out.write(sep); "
      "out.write(clean(e.durationMs)); out.write(sep); "
      "out.write(e.time.toIso8601String()); out.write(sep); out.write(clean(e.error)); out.write(row); } "
      "return out.toString(); })()";
}

/// 单条网络详情（按 url 精确 + 时间最近的记录）。
/// 输出：method\u0001url\u0001reqHeaders\u0001reqBody\u0001respHeaders\u0001respBody\u0001status\u0001duration
String networkDetailExpr(String url) {
  final u = escapeEvalString(url);
  return "(() { final n = XBUme.controller.network; final sep = String.fromCharCode(1); "
      "String clean(Object? s) { final t = (s ?? '').toString(); "
      "return t.replaceAll(String.fromCharCode(1), ' ').replaceAll(String.fromCharCode(3), ' '); } "
      "for (final e in n.reversed) { if (e.url.toString() == '$u') { "
      "return clean(e.method) + sep + clean(e.url) + sep + clean(e.requestHeaders) + sep "
      "+ clean(e.requestBody) + sep + clean(e.responseHeaders) + sep + clean(e.responseBody) + sep "
      "+ clean(e.statusCode) + sep + clean(e.durationMs); } } return 'NOT_FOUND'; })()";
}

/// app 内 console 记录（XBUme.controller.logs）。
/// 输出每行：level\u0001tag\u0001message\u0001time\u0003（stack 只在末尾附加，避免撑爆）
String consoleExpr({String? level, String? keyword, int? sinceMs, int limit = 50}) {
  final filters = <String>[];
  if (level != null && level.isNotEmpty) {
    filters.add("e.level.name == '${escapeEvalString(level)}'");
  }
  if (keyword != null && keyword.isNotEmpty) {
    final k = escapeEvalString(keyword);
    filters.add("(e.message.contains('$k') || e.tag.contains('$k'))");
  }
  if (sinceMs != null) {
    filters.add('e.time.isAfter(DateTime.fromMillisecondsSinceEpoch($sinceMs))');
  }
  final where = filters.isEmpty ? '' : '.where((e) => ${filters.join(' && ')}) ';
  return "(() { final l = XBUme.controller.logs; "
      "final sep = String.fromCharCode(1); final row = String.fromCharCode(3); "
      "final out = StringBuffer(); var c = 0; "
      "String clean(Object? s) { final t = (s ?? '').toString(); "
      "return t.replaceAll(String.fromCharCode(1), ' ').replaceAll(String.fromCharCode(2), ' ') "
      ".replaceAll(String.fromCharCode(3), ' '); } "
      "for (final e in l$where) { if (c >= $limit) break; c++; "
      "out.write(clean(e.level.name)); out.write(sep); out.write(clean(e.tag)); out.write(sep); "
      "var m = clean(e.message); if (m.length > 500) { m = m.substring(0, 500); } "
      "out.write(m); out.write(sep); out.write(e.time.toIso8601String()); out.write(row); } "
      "return out.toString(); })()";
}

/// 帧耗时统计（XBUme.controller.frames）。
/// 输出：count\u0001avgTotal\u0001avgBuild\u0001avgRaster\u0001jank
const String framesExpr =
    "(() { final f = XBUme.controller.frames; final sep = String.fromCharCode(1); "
    "if (f.isEmpty) return '0' + sep + '0' + sep + '0' + sep + '0' + sep + '0'; "
    "var t = 0.0; var b = 0.0; var r = 0.0; var j = 0; "
    "for (final e in f) { final tot = e.totalMs; "
    "t += tot; b += e.buildMs; r += e.rasterMs; if (tot >= 16.7) { j++; } } "
    "final n = f.length; "
    "return n.toString() + sep + (t / n).toStringAsFixed(2) + sep "
    "+ (b / n).toStringAsFixed(2) + sep + (r / n).toStringAsFixed(2) + sep + j.toString(); })()";

/// 已注册 Store / 类实例（扩展组 inspect 用，上下文 kLibStoreRegistry）。
/// 输出每行：id\u0001className\u0003
const String storeListExpr =
    "(() { final sep = String.fromCharCode(1); final row = String.fromCharCode(3); "
    "final out = StringBuffer(); "
    "XBUmeStoreRegistry.resolvedStores.forEach((k, v) { "
    "out.write(k); out.write(sep); out.write(v.runtimeType.toString()); out.write(row); }); "
    "return out.toString(); })()";
