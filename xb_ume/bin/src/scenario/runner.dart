// CLI 场景执行器 + 自包含 HTML 报告。
//
// 步骤语义与 GUI「自动化」Tab 保持一致（表达式同源复制自 bin/ide_gui.dart）：
//   tap / swipe / input / wait / back / navigate / assertVisible / assertRoute /
//   assertInstance / eval / assertText / assertRequest；assertLog 依赖 GUI 的
//   日志订阅上下文，CLI 下标为 skip。
//
// 供 `dart run xb_ume:run` 在无 GUI、无浏览器的命令行 / CI 环境执行场景。
library;

import 'dart:convert';
import 'dart:io';

import 'vm_client.dart';

/// 单步执行结果。
class ScenarioStepResult {
  ScenarioStepResult(this.index, this.type, this.expect, this.step);

  final int index;
  final String type;
  final String expect;

  /// 原始步骤 JSON（报告里可展示参数）。
  final Map<String, dynamic> step;

  String actual = '';
  String error = '';
  String status = 'pass'; // pass / fail / skip
  int ms = 0;
  String? shotB64;
  String? shotFile;

  bool get isPass => status == 'pass';
  bool get isFail => status == 'fail';
  bool get isSkip => status == 'skip';
}

/// 一次场景执行的完整结果。
class ScenarioRunReport {
  ScenarioRunReport({
    required this.name,
    required this.uri,
    required this.startedAt,
    required this.endedAt,
    required this.results,
    required this.continueOnFail,
  });

  final String name;
  final String uri;
  final DateTime startedAt;
  final DateTime endedAt;
  final List<ScenarioStepResult> results;
  final bool continueOnFail;

  int get total => results.length;
  int get passCount => results.where((r) => r.isPass).length;
  int get failCount => results.where((r) => r.isFail).length;
  int get skipCount => results.where((r) => r.isSkip).length;
  bool get ok => failCount == 0;
  Duration get duration => endedAt.difference(startedAt);
}

String _escEvalString(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll(r'$', r'\$')
    .replaceAll("'", r"\'")
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll('\t', r'\t');

/// 每次注入唯一 pointer id：PointerDownEvent 默认 pointer=0，down 派发中业务
/// 异常导致 up 未发时，_hitTests 残留会让后续 tap 撞断言永久卡死。
int _nextPointer() => DateTime.now().microsecondsSinceEpoch & 0x3fffffff;

/// tap：GestureBinding.handlePointerEvent down+up 同点（binding.dart 上下文）。
String _tapExpr(String x, String y, {bool phys = false, int pointer = 0}) {
  final pos = phys
      ? 'final pos = Offset($x, $y) / WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; '
      : 'final pos = Offset($x, $y); ';
  return '(() { $pos'
      'final pe = PointerDownEvent(pointer: $pointer, position: pos); '
      'try { GestureBinding.instance.handlePointerEvent(pe); } catch (e) { '
      'GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: $pointer, position: pos)); '
      "return 'ERR:' + e.toString(); } "
      'GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: $pointer, position: pos)); '
      "return 'OK'; })()";
}

/// input：直接调当前焦点 client 的 updateEditingValue（需先 tap 输入框）。
String _inputExpr(String text) =>
    '(() { final c = TextInput._instance._currentConnection; '
    "if (c == null) return 'NO_CONN'; "
    "final s = '${_escEvalString(text)}'; "
    '(c._client as dynamic).updateEditingValue(TextEditingValue('
    'text: s, selection: TextSelection.collapsed(offset: s.length))); '
    "return 'OK'; })()";

/// assertVisible：树中存在类型匹配（支持泛型前缀）且有尺寸的 RenderBox。
String _assertVisibleExpr(String type) {
  final t = _escEvalString(type);
  return '(() { final root = WidgetsBinding.instance.renderViewElement; '
      "if (root == null) return 'NO_ROOT'; "
      'final se = <Element>[root!]; '
      'while (se.isNotEmpty) { final e = se.removeLast(); '
      "final t = e.widget.runtimeType.toString(); var ok = t == '$t'; "
      "if (!ok) { final g = t.indexOf('<'); if (g > 0 && t.substring(0, g) == '$t') ok = true; } "
      'if (ok) { final r = e.renderObject; if (r is RenderBox && r.attached '
      "&& r.hasSize && r.size.width > 0 && r.size.height > 0) return 'FOUND'; } "
      'final kids = <Element>[]; e.visitChildren(kids.add); '
      'for (var i = kids.length - 1; i >= 0; i--) se.add(kids[i]); } '
      "return 'NOT_FOUND'; })()";
}

/// 路由栈快照（navigator.dart 上下文）：路由名逗号拼接。
const String _routesExpr =
    "(() { final root = WidgetsBinding.instance.renderViewElement; "
    "if (root == null) return 'NO_ROOT'; "
    'final navs = <NavigatorState>[]; '
    'void walk(Element e) { final w = e.widget; '
    'if (w is Navigator && e is StatefulElement && e.state is NavigatorState) '
    '{ navs.add(e.state as NavigatorState); } e.visitChildren(walk); } '
    'root.visitChildren(walk); '
    "if (navs.isEmpty) return 'NO_NAV'; "
    'final out = StringBuffer(); '
    'for (final h in navs[0]._history) { out.write(h.route.settings.name); '
    'out.write(String.fromCharCode(44)); } return out.toString(); })()';

/// 当前可见页面文本（跳过 offstage 保活子树），以 \u0002 分隔。
String _pageTextExpr({int limit = 200}) =>
    '(() { final root = WidgetsBinding.instance.renderViewElement; '
    "if (root == null) return ''; "
    'final out = <String>[]; final seen = <String>{}; '
    'void add(String? t) { if (t == null) return; final s = t.trim(); '
    'if (s.isEmpty) return; if (seen.add(s)) out.add(s); } '
    'void visit(Element e) { if (out.length >= $limit) return; '
    'final tn = e.widget.runtimeType.toString(); '
    "if (tn == 'Offstage') { try { if ((e.widget as dynamic).offstage == true) return; } catch (_) {} } "
    "try { if (tn == 'Text') { add((e.widget as dynamic).data as String?); } "
    "else if (tn == 'EditableText') { add((e.widget as dynamic).controller.text as String?); } "
    '} catch (_) {} '
    'e.visitChildren(visit); } visit(root); '
    'return out.join(String.fromCharCode(2)); })()';

class ScenarioRunner {
  ScenarioRunner(
    this.vm, {
    this.continueOnFail = false,
    this.shotEveryStep = false,
    this.waitAfterMs = 700,
    this.shotsDir,
    this.shotPrefix = 'run',
    this.onStep,
  });

  final VmClient vm;
  final bool continueOnFail;
  final bool shotEveryStep;
  final int waitAfterMs;
  final String? shotsDir;
  final String shotPrefix;

  /// 每步结束回调（CLI 打印进度、进度条等）。
  final void Function(ScenarioStepResult r)? onStep;

  /// 顺序执行场景步骤；失败默认停止（剩余标 skip），continueOnFail 时继续。
  Future<ScenarioRunReport> run(
      String name, List<Map<String, dynamic>> steps) async {
    final started = DateTime.now();
    final results = <ScenarioStepResult>[];
    var halted = false;
    for (var i = 0; i < steps.length; i++) {
      final st = steps[i];
      final type = (st['type'] ?? '?').toString();
      final expect = (st['expect'] ??
              (type == 'assertVisible' ? '可见 ${st['widget'] ?? ''}' : ''))
          .toString();
      final r = ScenarioStepResult(i, type, expect, st);
      results.add(r);
      if (halted) {
        r
          ..status = 'skip'
          ..error = '前序步骤失败，未执行';
        onStep?.call(r);
        continue;
      }
      final sw = Stopwatch()..start();
      try {
        final (actual, err, skip) = await _exec(st);
        r.actual = actual;
        if (skip) {
          r
            ..status = 'skip'
            ..error = err;
        } else if (err.isNotEmpty) {
          r
            ..status = 'fail'
            ..error = err;
        } else {
          r.status = 'pass';
        }
      } catch (e) {
        r
          ..status = 'fail'
          ..error = e.toString();
      }
      r.ms = sw.elapsedMilliseconds;
      if (r.isFail && !r.isSkip) {
        r.shotB64 = await _shot(i);
        if (!continueOnFail) halted = true;
      } else if (shotEveryStep) {
        r.shotB64 = await _shot(i);
      }
      onStep?.call(r);
      if (waitAfterMs > 0 && !halted) {
        await Future.delayed(Duration(milliseconds: waitAfterMs));
      }
    }
    return ScenarioRunReport(
      name: name,
      uri: vm.uri,
      startedAt: started,
      endedAt: DateTime.now(),
      results: results,
      continueOnFail: continueOnFail,
    );
  }

  Future<String?> _shot(int i) async {
    try {
      final b64 = await vm.screenshotBase64();
      if (b64.isEmpty) return null;
      if (shotsDir != null && shotsDir!.isNotEmpty) {
        try {
          final dir = Directory(shotsDir!);
          if (!dir.existsSync()) dir.createSync(recursive: true);
          final f = File('${dir.path}/$shotPrefix-step$i.png');
          f.writeAsBytesSync(base64Decode(b64));
        } catch (_) {}
      }
      return b64;
    } catch (_) {
      return null;
    }
  }

  /// 执行单步，返回 (actual, error, skip)。
  Future<(String, String, bool)> _exec(Map<String, dynamic> st) async {
    final type = (st['type'] ?? '').toString().trim();
    switch (type) {
      case 'tap':
        final x = (st['x'] as num?)?.toDouble();
        final y = (st['y'] as num?)?.toDouble();
        if (x == null || y == null) return ('', 'tap 需要 x/y 数值坐标', false);
        final s = await vm.evalStringOn(
            'package:flutter/src/widgets/binding.dart',
            _tapExpr(x.toString(), y.toString(),
                phys: (st['phys'] ?? false) == true,
                pointer: _nextPointer()));
        return (
          s,
          s == 'OK'
              ? ''
              : (s.startsWith('ERR:') ? 'tap 派发异常: ${s.substring(4)}' : 'tap 注入异常: $s'),
          false
        );
      case 'swipe':
        return await _swipe(st);
      case 'input':
        final text = (st['text'] ?? '').toString();
        final s = await vm.evalStringOn(
            'package:flutter/src/services/text_input.dart', _inputExpr(text));
        return (
          s,
          s == 'OK'
              ? ''
              : s == 'NO_CONN'
                  ? '无焦点输入框（先 tap 输入框）'
                  : '注入异常: $s',
          false
        );
      case 'wait':
        final ms = (st['ms'] as num?)?.toInt() ?? 500;
        await Future.delayed(Duration(milliseconds: ms.clamp(0, 60000)));
        return ('waited $ms ms', '', false);
      case 'back':
        final s = await vm.evalStringOn(
            'package:flutter/src/widgets/navigator.dart', _routesExpr);
        if (s == 'NO_ROOT' || s == 'NO_NAV') return (s, '无路由栈', false);
        final names = s.split(',').where((e) => e.isNotEmpty).toList();
        if (names.length <= 1) {
          return ('${names.length} route', '已是最后一个路由，无法返回', false);
        }
        final op = await _routeOp('pop');
        return (op, op == 'OK' ? '' : 'pop 失败: $op', false);
      case 'navigate':
        final name = (st['name'] ?? '').toString();
        if (name.isEmpty) return ('', 'navigate 需要 name', false);
        final op = await _routeOp('push', name: name);
        return (op, op == 'OK' ? '' : 'push 失败: $op', false);
      case 'assertVisible':
        final t = (st['widget'] ?? '').toString().trim();
        if (t.isEmpty) return ('', 'assertVisible 需要 widget（页面/组件类名）', false);
        final s = await vm.evalStringOn(
            'package:flutter/src/widgets/binding.dart', _assertVisibleExpr(t));
        return (
          s,
          s == 'FOUND'
              ? ''
              : s == 'NOT_FOUND'
                  ? '树中不存在可见的 $t'
                  : '查找异常: $s',
          false
        );
      case 'assertRoute':
        final name = (st['name'] ?? '').toString();
        final s = await vm.evalStringOn(
            'package:flutter/src/widgets/navigator.dart', _routesExpr);
        if (s == 'NO_ROOT' || s == 'NO_NAV') return (s, '无路由栈', false);
        final names = s.split(',').where((e) => e.isNotEmpty).toList();
        final top = names.isEmpty ? '' : names.last;
        return (
          top,
          name.isEmpty || top.contains(name) ? '' : '栈顶路由 $top 不匹配 $name',
          false
        );
      case 'assertInstance':
        final cls = (st['class'] ?? '').toString().trim();
        if (cls.isEmpty) return ('', 'assertInstance 需要 class', false);
        final n = await _instanceCount(cls);
        return ('$n 个', n > 0 ? '' : '堆/树上不存在 $cls 实例', false);
      case 'eval':
        final expr = (st['expr'] ?? '').toString();
        if (expr.isEmpty) return ('', 'eval 需要 expr', false);
        final s = await vm.evalStringOn(
            'package:flutter/src/widgets/binding.dart', expr);
        final expect = (st['expect'] ?? '').toString();
        return (
          s,
          expect.isEmpty || s.contains(expect) ? '' : '期望包含「$expect」实际「$s」',
          false
        );
      case 'assertText':
        final contains = (st['contains'] ?? '').toString();
        final notContains = (st['notContains'] ?? '').toString();
        if (contains.isEmpty && notContains.isEmpty) {
          return ('', 'assertText 需要 contains 或 notContains', false);
        }
        final s = await vm.evalStringOn(
            'package:flutter/src/widgets/binding.dart', _pageTextExpr());
        final texts = s.split('\u0002').where((e) => e.isNotEmpty).toList();
        if (contains.isNotEmpty) {
          final hit = texts.where((e) => e.contains(contains)).toList();
          return (
            hit.isEmpty ? '未命中' : '命中: ${hit.take(3).join(' / ')}',
            hit.isEmpty ? '页面文本中未找到「$contains」' : '',
            false
          );
        }
        final bad = texts.where((e) => e.contains(notContains)).toList();
        return (
          bad.isEmpty ? '未出现「$notContains」' : '仍存在: ${bad.take(3).join(' / ')}',
          bad.isEmpty ? '' : '页面文本中不应出现「$notContains」',
          false
        );
      case 'assertRequest':
        return await _assertRequest(st);
      case 'assertLog':
        return (
          '',
          'CLI 无日志订阅上下文（需 GUI 的日志缓冲），该步跳过',
          true
        );
      default:
        return (
          '',
          '未知步骤类型 $type（支持 tap/swipe/input/wait/back/navigate/'
              'assertVisible/assertRoute/assertInstance/assertText/'
              'assertRequest/eval）',
          false
        );
    }
  }

  Future<(String, String, bool)> _swipe(Map<String, dynamic> st) async {
    final x1 = (st['x1'] as num?)?.toDouble();
    final y1 = (st['y1'] as num?)?.toDouble();
    final x2 = (st['x2'] as num?)?.toDouble();
    final y2 = (st['y2'] as num?)?.toDouble();
    if (x1 == null || y1 == null || x2 == null || y2 == null) {
      return ('', 'swipe 需要 x1/y1/x2/y2', false);
    }
    final ms = (st['ms'] as num?)?.toInt() ?? 300;
    const seg = 8;
    final moveMs = (ms / seg).round().clamp(16, 200);
    final phys = (st['phys'] ?? false) == true;
    String px(double v) => phys ? '($v / d)' : v.toString();
    final pid = _nextPointer();
    final tsBase = DateTime.now().microsecondsSinceEpoch;
    const ctx = 'package:flutter/src/widgets/binding.dart';
    String downReply;
    try {
      downReply = await vm.evalStringOn(ctx,
          '(() { final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; '
          'try { GestureBinding.instance.handlePointerEvent('
          'PointerDownEvent(pointer: $pid, position: Offset(${px(x1)}, ${px(y1)}), timeStamp: Duration(microseconds: $tsBase))); } catch (e) { '
          'GestureBinding.instance.handlePointerEvent('
          'PointerUpEvent(pointer: $pid, position: Offset(${px(x1)}, ${px(y1)}))); '
          "return 'ERR:' + e.toString(); } return 'OK'; })()");
    } catch (e) {
      return ('', 'swipe down 注入失败: $e', false);
    }
    if (downReply != 'OK') {
      return (
        '',
        'swipe down 异常: ${downReply.startsWith('ERR:') ? downReply.substring(4) : downReply}',
        false
      );
    }
    var pmx = x1;
    var pmy = y1;
    for (var i = 1; i <= seg; i++) {
      final t = i / seg;
      final mx = x1 + (x2 - x1) * t;
      final my = y1 + (y2 - y1) * t;
      final tsUs = tsBase + (ms * 1000 * t).round();
      await vm.evalStringOn(ctx,
          '(() { final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; '
          'GestureBinding.instance.handlePointerEvent('
          'PointerMoveEvent(pointer: $pid, position: Offset(${px(mx)}, ${px(my)}), '
          'delta: Offset(${px(mx)} - ${px(pmx)}, ${px(my)} - ${px(pmy)}), '
          "timeStamp: Duration(microseconds: $tsUs))); return 'OK'; })()");
      pmx = mx;
      pmy = my;
      await Future.delayed(Duration(milliseconds: moveMs));
    }
    await vm.evalStringOn(ctx,
        '(() { final d = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio; '
        'GestureBinding.instance.handlePointerEvent('
        'PointerUpEvent(pointer: $pid, position: Offset(${px(x2)}, ${px(y2)}), timeStamp: Duration(microseconds: ${tsBase + ms * 1000}))); return \'OK\'; })()');
    return ('swipe (${x1.round()},${y1.round()})->(${x2.round()},${y2.round()})', '', false);
  }

  /// 路由操作（pop / pushNamed），与 GUI /api/routeop 同一套 eval。
  Future<String> _routeOp(String op, {String name = ''}) async {
    const walk = 'final root = WidgetsBinding.instance.renderViewElement; '
        "if (root == null) return 'NO_ROOT'; "
        'final navigators = <NavigatorState>[]; '
        'void walk(Element e) { final w = e.widget; '
        'if (w is Navigator && e is StatefulElement && e.state is NavigatorState) '
        '{ navigators.add(e.state as NavigatorState); } e.visitChildren(walk); } '
        'root.visitChildren(walk); ';
    final expr = op == 'pop'
        ? '(() { $walk'
            "if (navigators.isEmpty) return 'NO_NAV'; "
            'final h = navigators[0]._history; if (h.length <= 1) return \'LAST_ROUTE\'; '
            "navigators[0].pop(); return 'OK'; })()"
        : '(() { $walk'
            "if (navigators.isEmpty) return 'NO_NAV'; "
            'if (navigators[0].widget.onGenerateRoute == null) return \'NO_ROUTE_TABLE\'; '
            "try { final r = navigators[0]._routeNamed('${_escEvalString(name)}', arguments: null); "
            "if (r == null) return 'UNKNOWN'; navigators[0].push(r); return 'OK'; "
            "} catch (e) { return 'ERR:' + e.runtimeType.toString(); } })()";
    return vm.evalStringOn('package:flutter/src/widgets/navigator.dart', expr);
  }

  /// 堆/树上实例计数（getClassList + getInstances）。
  Future<int> _instanceCount(String cls) async {
    final iso = await vm.isolateId();
    final classList = await vm.rawRpc('getClassList', {'isolateId': iso});
    var count = 0;
    for (final c in (classList['classes'] as List? ?? <Object?>[])) {
      if (c is! Map) continue;
      final name = c['name']?.toString() ?? '';
      if (name != cls && !name.endsWith('.$cls')) continue;
      try {
        final set = await vm.rawRpc('getInstances', {
          'isolateId': iso,
          'objectId': c['id']?.toString() ?? '',
          'limit': 100,
        });
        count += (set['instances'] as List? ?? <Object?>[]).length;
      } catch (_) {}
    }
    return count;
  }

  /// app 端 ume 的 network 记录（与 GUI /api/network 同源）。
  Future<List<Map<String, String>>> _netRecords(
      {DateTime? since, int limit = 100}) async {
    final cutoffExpr = since == null
        ? ''
        : "final c = DateTime.parse('${since.toIso8601String()}'); ";
    final filterExpr = since == null ? '' : '.where((e) => e.time.isAfter(c)) ';
    final raw = await vm.evalStringOn(
      'package:xb_ume/src/core/xb_ume.dart',
      '(() { final n = XBUme.controller.network; $cutoffExpr'
      "return n$filterExpr.map((e) => [e.method, e.url, "
      "(e.statusCode ?? '').toString(), e.status.name].join('\\u0001')).join('\\u0002'); })()",
    );
    final items = <Map<String, String>>[];
    for (final line in raw.split('\u0002')) {
      if (line.isEmpty) continue;
      final p = line.split('\u0001');
      if (p.length < 4) continue;
      items.add(<String, String>{
        'method': p[0],
        'url': p[1],
        'statusCode': p[2],
        'status': p[3],
      });
    }
    return items.length > limit ? items.sublist(items.length - limit) : items;
  }

  Future<(String, String, bool)> _assertRequest(Map<String, dynamic> st) async {
    final url = (st['urlContains'] ?? '').toString().trim();
    if (url.isEmpty) return ('', 'assertRequest 需要 urlContains', false);
    final method = (st['method'] ?? '').toString().trim().toUpperCase();
    final neg = (st['not'] ?? false) == true;
    final within = (st['withinLastMs'] as num?)?.toInt();
    final since = within != null
        ? DateTime.now().subtract(Duration(milliseconds: within))
        : DateTime.now().subtract(const Duration(minutes: 5));
    List<Map<String, String>> recs;
    try {
      recs = await _netRecords(since: since, limit: 100);
    } catch (e) {
      return ('', 'app 未接入 xb_ume Network 模块（或读数失败）: $e', false);
    }
    final matched = recs
        .where((e) =>
            e['url']!.contains(url) &&
            (method.isEmpty || e['method']!.toUpperCase() == method))
        .toList();
    final desc =
        matched.map((e) => '${e['method']} ${e['url']} ${e['statusCode']}').join(' · ');
    if (neg) {
      return (
        matched.isEmpty ? '无匹配（符合预期）' : desc,
        matched.isEmpty ? '' : '不应出现的请求出现了：$desc',
        false
      );
    }
    return (
      matched.isEmpty ? '窗口内 ${recs.length} 条请求，无匹配' : desc,
      matched.isEmpty
          ? '窗口内无匹配请求（urlContains=$url${method.isEmpty ? '' : ' method=$method'}）'
          : '',
      false
    );
  }
}

String htmlEsc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// 生成自包含 HTML 报告（截图内嵌 base64，CI 可直接作为 artifact 打开）。
String buildScenarioReportHtml(
  ScenarioRunReport r, {
  String version = '',
  String command = '',
}) {
  const bd = 'padding:6px 10px;border-bottom:1px solid #ddd;text-align:left;'
      'vertical-align:top';
  final ok = r.ok;
  final badgeBg = ok ? '#2e7d32' : '#c62828';
  final badge = ok ? '✅ 全部通过' : '❌ ${r.failCount} 步失败';
  final sb = StringBuffer();
  sb.write('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>xb_ume 场景报告 · ${htmlEsc(r.name)}</title><style>'
      'body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,'
      '"Helvetica Neue",Arial,"PingFang SC","Microsoft YaHei",sans-serif;'
      'margin:24px;color:#222;background:#fff}'
      'h1{font-size:20px;margin:0 0 4px}'
      '.badge{display:inline-block;color:#fff;background:$badgeBg;'
      'padding:3px 10px;border-radius:4px;font-size:13px;font-weight:600}'
      '.meta{font-size:13px;color:#555;margin:10px 0}'
      '.meta td{padding:2px 12px 2px 0}'
      '.stats{font-size:13px;margin:10px 0 14px}'
      '.stats b{font-size:15px}'
      '.steps{border-collapse:collapse;width:100%;font-size:12.5px}'
      '.steps th{background:#f5f5f5;padding:6px 10px;border-bottom:2px solid #ccc;'
      'text-align:left;font-weight:600}'
      '.steps td{$bd}'
      '.pass{color:#2e7d32;font-weight:600}.fail{color:#c62828;font-weight:600}'
      '.skip{color:#b26a00;font-weight:600}'
      '.shot{max-height:260px;border:1px solid #999;border-radius:3px;'
      'margin:4px 0;display:block}'
      '.muted{color:#888}'
      'footer{margin-top:18px;font-size:12px;color:#888}'
      '</style></head><body>');
  sb.write('<h1>xb_ume 场景执行报告</h1>');
  sb.write('<div class="badge">$badge</div>');
  sb.write('<table class="meta">');
  sb.write('<tr><td>场景</td><td><b>${htmlEsc(r.name)}</b></td></tr>');
  sb.write('<tr><td>会话</td><td>${htmlEsc(r.uri)}</td></tr>');
  sb.write('<tr><td>开始</td><td>${r.startedAt.toIso8601String()}</td></tr>');
  sb.write('<tr><td>结束</td><td>${r.endedAt.toIso8601String()}'
      '（总耗时 ${(r.duration.inMilliseconds / 1000).toStringAsFixed(1)}s）</td></tr>');
  if (command.isNotEmpty) {
    sb.write('<tr><td>命令</td><td><code>${htmlEsc(command)}</code></td></tr>');
  }
  sb.write('<tr><td>失败策略</td><td>'
      '${r.continueOnFail ? '失败后继续执行' : '失败即停止（剩余步骤跳过）'}</td></tr>');
  sb.write('</table>');
  sb.write('<div class="stats">总步数 <b>${r.total}</b> · '
      '通过 <b class="pass">${r.passCount}</b> · '
      '失败 <b class="fail">${r.failCount}</b> · '
      '跳过 <b class="skip">${r.skipCount}</b></div>');
  sb.write('<table class="steps"><tr><th>#</th><th>类型</th><th>期望</th>'
      '<th>状态</th><th>耗时</th><th>实际 / 错误</th></tr>');
  for (final s in r.results) {
    final cls = s.isPass ? 'pass' : (s.isFail ? 'fail' : 'skip');
    final statusText = s.isPass ? 'pass' : (s.isFail ? 'fail' : 'skip');
    sb.write('<tr><td>${s.index + 1}</td><td>${htmlEsc(s.type)}</td>'
        '<td>${htmlEsc(s.expect)}</td>'
        '<td class="$cls">$statusText</td><td>${s.ms}ms</td>'
        '<td>${htmlEsc(s.actual)}'
        '${s.error.isEmpty ? '' : '<div class="fail">${htmlEsc(s.error)}</div>'}');
    if (s.shotFile != null && s.shotFile!.isNotEmpty) {
      sb.write('<div class="muted">截图：${htmlEsc(s.shotFile!)}</div>');
    }
    sb.write('</td></tr>');
    if (s.shotB64 != null && s.shotB64!.isNotEmpty) {
      sb.write('<tr><td colspan="6"><img class="shot" alt="step ${s.index + 1} 截图" '
          'src="data:image/png;base64,${s.shotB64}"></td></tr>');
    }
  }
  sb.write('</table>');
  sb.write('<footer>由 xb_ume${version.isEmpty ? '' : ' $version'} 命令行'
      '（dart run xb_ume:run）生成 · ${DateTime.now().toIso8601String()}</footer>');
  sb.write('</body></html>');
  return sb.toString();
}
