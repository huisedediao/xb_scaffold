part of 'runner.dart';

// P3 复合步骤与设备步骤（借鉴 MobAI 的 DSL 形状）。
//
// 为什么用 part：条件判断必须复用 runner 里已验证的 visible / text / route
// 表达式与注入守卫；另起一个 library 会把这些细节复制成第二套实现，
// 两边一改就漂移。
//
// 语义约定：
//   - 复合步骤在报告里只占一行，内部子步骤不单列（retry / if）；
//   - 条件支持 4 种写法：visible / text / route / request / expr，
//     省略 kind 时按字段自动推断（见 [_conditionOf]）；
//   - 设备步骤统一走 DeviceRegistry，能力不支持时给可读错误，不假装支持。

/// 条件归一化：显式 kind 优先，否则按字段推断（widget→visible、contains→text…）。
Map<String, dynamic> _conditionOf(Map<String, dynamic> raw) {
  final m = Map<String, dynamic>.from(raw);
  if ((m['kind'] ?? '').toString().isNotEmpty) return m;
  if (m['widget'] != null) {
    m['kind'] = 'visible';
  } else if (m['contains'] != null || m['notContains'] != null) {
    m['kind'] = 'text';
  } else if (m['urlContains'] != null) {
    m['kind'] = 'request';
  } else if (m['expr'] != null) {
    m['kind'] = 'expr';
  } else if (m['name'] != null) {
    m['kind'] = 'route';
  }
  return m;
}

extension _P3Steps on ScenarioRunner {
  /// 条件求值：返回（是否满足, 可读说明）；配置错误直接抛字符串。
  Future<(bool, String)> _checkCondition(Map<String, dynamic> cond) async {
    final kind = (cond['kind'] ?? '').toString();
    switch (kind) {
      case 'visible':
        final t = (cond['widget'] ?? '').toString().trim();
        if (t.isEmpty) throw 'visible 条件需要 widget（组件类名）';
        final s = await api.assertVisibleRaw(t);
        return (s == 'FOUND', s == 'FOUND' ? '树中存在可见的 $t' : '树中不存在可见的 $t');
      case 'text':
        final contains = (cond['contains'] ?? '').toString();
        final notContains = (cond['notContains'] ?? '').toString();
        if (contains.isEmpty && notContains.isEmpty) {
          throw 'text 条件需要 contains 或 notContains';
        }
        final s = await api.pageTextRaw();
        final texts = s.split('\u0002').where((e) => e.isNotEmpty).toList();
        if (contains.isNotEmpty) {
          final hit = texts.any((e) => e.contains(contains));
          return (hit, hit ? '页面文本命中「$contains」' : '页面文本未出现「$contains」');
        }
        final bad = texts.any((e) => e.contains(notContains));
        return (!bad, bad ? '页面文本仍含「$notContains」' : '页面文本未出现「$notContains」');
      case 'route':
        final name = (cond['name'] ?? '').toString();
        final names = await _routes();
        if (names.isEmpty) return (false, '无路由栈');
        final top = names.last;
        final ok = name.isEmpty || top.contains(name);
        return (ok, ok ? '栈顶路由 $top' : '栈顶路由 $top 不匹配 $name');
      case 'request':
        final url = (cond['urlContains'] ?? '').toString().trim();
        if (url.isEmpty) throw 'request 条件需要 urlContains';
        final method = (cond['method'] ?? '').toString().trim().toUpperCase();
        final within = ((cond['withinLastMs'] as num?)?.toInt() ?? 300000)
            .clamp(0, 86400000);
        final since = DateTime.now().subtract(Duration(milliseconds: within));
        final recs = await _netRecords(since: since, limit: 100);
        final hit = recs
            .where((e) =>
                e['url']!.contains(url) &&
                (method.isEmpty || e['method']!.toUpperCase() == method))
            .toList();
        return (
          hit.isNotEmpty,
          hit.isEmpty
              ? '近 ${within ~/ 1000}s 无匹配请求 $url'
              : '命中 ${hit.length} 条请求'
        );
      case 'expr':
        final expr = (cond['expr'] ?? '').toString();
        if (expr.isEmpty) throw 'expr 条件需要 expr';
        final expect = (cond['expect'] ?? '').toString();
        final String s;
        try {
          s = await api.evalRaw('package:flutter/src/widgets/binding.dart', expr);
        } on SessionApiUnsupported catch (e) {
          throw '$e';
        }
        final ok = expect.isEmpty || s.contains(expect);
        return (ok, ok ? '表达式结果「$s」' : '表达式结果「$s」不含「$expect」');
      case 'log':
        throw 'CLI 无日志订阅上下文，log 条件请在 GUI 场景中使用';
      default:
        throw '未知条件类型 $kind（visible/text/route/request/expr）';
    }
  }

  /// waitFor：轮询直到条件满足或超时。
  Future<(String, String, bool)> _waitForStep(Map<String, dynamic> st) async {
    final raw = st['until'];
    final cond = _conditionOf(raw is Map
        ? Map<String, dynamic>.from(raw)
        : Map<String, dynamic>.from(st));
    final timeout =
        ((st['timeoutMs'] as num?)?.toInt() ?? 5000).clamp(0, 600000);
    final interval =
        ((st['intervalMs'] as num?)?.toInt() ?? 250).clamp(20, 5000);
    final sw = Stopwatch()..start();
    var last = '条件未满足';
    while (true) {
      try {
        final (ok, detail) = await _checkCondition(cond);
        last = detail;
        if (ok) return ('满足（${sw.elapsedMilliseconds}ms）', '', false);
      } catch (e) {
        last = '$e';
      }
      if (sw.elapsedMilliseconds >= timeout) break;
      await Future<void>.delayed(Duration(milliseconds: interval));
    }
    return ('', '等待超时（${timeout}ms）：$last', false);
  }

  /// retry：把子步骤整体重试，全部通过才算通过（子步骤 skip 不阻断）。
  Future<(String, String, bool)> _retryStep(Map<String, dynamic> st) async {
    final inner = _subSteps(st['steps']);
    if (inner.isEmpty) return ('', 'retry 需要非空 steps 数组', false);
    final max = ((st['max'] as num?)?.toInt() ?? 3).clamp(1, 20);
    final interval =
        ((st['intervalMs'] as num?)?.toInt() ?? 300).clamp(0, 60000);
    var lastErr = '';
    for (var attempt = 1; attempt <= max; attempt++) {
      lastErr = '';
      for (final sub in inner) {
        final err = await _runSubStep(sub);
        if (err.isNotEmpty) {
          lastErr = err;
          break;
        }
      }
      if (lastErr.isEmpty) return ('第 $attempt 次尝试通过', '', false);
      if (attempt < max && interval > 0) {
        await Future<void>.delayed(Duration(milliseconds: interval));
      }
    }
    return ('', '重试 $max 次仍失败：$lastErr', false);
  }

  /// if：条件成立跑 then，否则跑 else（可缺省）。
  Future<(String, String, bool)> _ifStep(Map<String, dynamic> st) async {
    final raw = st['condition'];
    if (raw is! Map) return ('', 'if 需要 condition 对象', false);
    final cond = _conditionOf(Map<String, dynamic>.from(raw));
    bool ok;
    String detail;
    try {
      (ok, detail) = await _checkCondition(cond);
    } catch (e) {
      return ('', '条件求值失败：$e', false);
    }
    final branch = _subSteps(ok ? st['then'] : st['else']);
    final tag = ok ? 'then' : 'else';
    if (branch.isEmpty) {
      return ('条件${ok ? '成立' : '不成立'}（$detail），无 $tag 分支', '', false);
    }
    for (final sub in branch) {
      final err = await _runSubStep(sub);
      if (err.isNotEmpty) {
        return ('', '条件${ok ? '成立' : '不成立'}，$tag 分支失败：$err', false);
      }
    }
    return (
      '条件${ok ? '成立' : '不成立'}（$detail），执行 $tag ${branch.length} 步',
      '',
      false
    );
  }

  /// observe：把当前状态快照进报告（text/routes/network/tree/shot）。
  Future<(String, String, bool)> _observeStep(Map<String, dynamic> st) async {
    final raw = st['include'];
    final include = raw is List
        ? raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toSet()
        : <String>{'text', 'routes', 'network'};
    final parts = <String>[];
    if (include.contains('routes')) {
      try {
        final names = await _routes();
        parts.add('routes=${names.isEmpty ? 'N/A' : names.join(' > ')}');
      } catch (_) {
        parts.add('routes=N/A');
      }
    }
    if (include.contains('text')) {
      try {
        final s = await api.pageTextRaw();
        final n = s.split('\u0002').where((e) => e.isNotEmpty).length;
        parts.add('text=$n 条');
      } catch (_) {
        parts.add('text=N/A');
      }
    }
    if (include.contains('network')) {
      try {
        parts.add('network=${(await _netRecords(limit: 20)).length} 条');
      } catch (_) {
        parts.add('network=N/A');
      }
    }
    if (include.contains('tree')) {
      parts.add(await _observeTree());
    }
    if (include.contains('shot')) {
      try {
        final b64 = await api.screenshotBase64();
        if (b64.isEmpty) {
          parts.add('shot=N/A');
        } else {
          _pendingShotB64 = b64;
          parts.add('shot=已附');
        }
      } catch (_) {
        parts.add('shot=N/A');
      }
    }
    return ('快照：${parts.join(' · ')}', '', false);
  }

  /// scrollUntil：按方向滚动直到条件满足或达到次数上限。
  Future<(String, String, bool)> _scrollUntilStep(
      Map<String, dynamic> st) async {
    final raw = st['condition'];
    if (raw is! Map) return ('', 'scrollUntil 需要 condition 对象', false);
    final cond = _conditionOf(Map<String, dynamic>.from(raw));
    final max = ((st['max'] as num?)?.toInt() ?? 6).clamp(1, 30);
    final dir = (st['direction'] ?? 'up').toString().toLowerCase();
    final amount = ((st['amount'] as num?)?.toDouble() ?? 0.5).clamp(0.05, 0.9);
    final ms = ((st['ms'] as num?)?.toInt() ?? 300).clamp(50, 3000);
    final (w, h) = await _screenSize();
    var last = '条件未满足';
    for (var attempt = 0; attempt <= max; attempt++) {
      try {
        final (ok, detail) = await _checkCondition(cond);
        last = detail;
        if (ok) return ('第 $attempt 次检查命中（$detail）', '', false);
      } catch (e) {
        last = '$e';
      }
      if (attempt == max) break;
      final (x1, y1, x2, y2) = _swipeVector(dir, w, h, amount);
      final (actual, err) = await api.swipe(
          x1: x1, y1: y1, x2: x2, y2: y2, durationMs: ms);
      if (err.isNotEmpty) return (actual, '滚动失败：$err', false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return ('', '滚动 $max 次仍未满足：$last', false);
  }

  // ── 设备步骤 ──

  Future<(String, String, bool)> _installStep(Map<String, dynamic> st) async {
    final artifact = (st['artifact'] ?? st['path'] ?? '').toString();
    if (artifact.isEmpty) return ('', 'install 需要 artifact（apk/app 路径）', false);
    try {
      final (bridge, device) = await _deviceOf(st);
      await bridge.install(device.id, artifact);
      return ('已安装 $artifact → ${device.id}', '', false);
    } catch (e) {
      return ('', '$e', false);
    }
  }

  Future<(String, String, bool)> _uninstallStep(Map<String, dynamic> st) async {
    if (st['confirm'] != true) {
      return ('', 'uninstall 是高危操作，需显式写 confirm: true', false);
    }
    final pkg = (st['packageId'] ?? '').toString().trim();
    if (pkg.isEmpty) return ('', 'uninstall 需要 packageId', false);
    try {
      final (bridge, device) = await _deviceOf(st);
      await bridge.uninstall(device.id, pkg);
      return ('已从 ${device.id} 卸载 $pkg', '', false);
    } catch (e) {
      return ('', '$e', false);
    }
  }

  /// launchApp：只启动「已安装」的包；场景已绑定 VM，不用它拉起 flutter run。
  Future<(String, String, bool)> _launchAppStep(Map<String, dynamic> st) async {
    final pkg = (st['packageId'] ?? '').toString().trim();
    if (pkg.isEmpty) return ('', 'launchApp 需要 packageId', false);
    try {
      final (bridge, device) = await _deviceOf(st);
      final note = await bridge.launch(device.id, pkg);
      return (note, '', false);
    } catch (e) {
      return ('', '$e', false);
    }
  }

  Future<(String, String, bool)> _pressKeyStep(Map<String, dynamic> st) async {
    final key = parseDeviceKey((st['key'] ?? '').toString());
    if (key == null) {
      return ('', '未知按键「${st['key']}」（back/home/enter/delete/…）', false);
    }
    try {
      final (bridge, device) = await _deviceOf(st);
      await bridge.pressKey(device.id, key);
      return ('${device.id} 按下 ${key.name}', '', false);
    } catch (e) {
      return ('', '$e', false);
    }
  }

  Future<(String, String, bool)> _nativeTapStep(Map<String, dynamic> st) async {
    final x = (st['x'] as num?)?.toDouble();
    final y = (st['y'] as num?)?.toDouble();
    if (x == null || y == null) return ('', 'nativeTap 需要 x/y 坐标', false);
    try {
      final (bridge, device) = await _deviceOf(st);
      await bridge.tapNative(device.id, x.round(), y.round());
      return ('${device.id} 原生点击 (${x.round()}, ${y.round()})', '', false);
    } catch (e) {
      return ('', '$e', false);
    }
  }

  /// assertNoCrash：近 N 分钟内没有该设备的崩溃记录。
  Future<(String, String, bool)> _assertNoCrashStep(
      Map<String, dynamic> st) async {
    final pkg = (st['packageId'] ?? '').toString().trim();
    final within =
        ((st['withinLastMs'] as num?)?.toInt() ?? 600000).clamp(0, 86400000);
    try {
      final (bridge, device) = await _deviceOf(st);
      final list = await bridge.crashList(
        device.id,
        packageId: pkg.isEmpty ? null : pkg,
        limit: 20,
      );
      final cutoff = DateTime.now().subtract(Duration(milliseconds: within));
      final recent = list
          .where((c) => c.time == null || c.time!.isAfter(cutoff))
          .toList(growable: false);
      if (recent.isEmpty) return ('近 ${within ~/ 1000}s 无崩溃', '', false);
      final titles = recent.take(3).map((c) => c.title).join(' / ');
      return ('', '近 ${within ~/ 1000}s 有 ${recent.length} 条崩溃：$titles', false);
    } catch (e) {
      return ('', '$e', false);
    }
  }

  // ── 内部辅助 ──

  Future<(DeviceBridge, DeviceInfo)> _deviceOf(Map<String, dynamic> st) async {
    final id = (st['deviceId'] ?? '').toString().trim();
    if (id.isEmpty) throw '需要 deviceId（xbume_devices 查看可用设备）';
    final hit = await devices.resolve(id);
    if (hit == null) throw '设备 $id 未找到（xbume_devices 查看）';
    return hit;
  }

  List<Map<String, dynamic>> _subSteps(Object? raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }

  /// 执行子步骤并归并为一条错误（空串 = 成功/skip）。
  Future<String> _runSubStep(Map<String, dynamic> sub) async {
    try {
      final (_, err, skip) = await _exec(sub);
      return skip ? '' : err;
    } catch (e) {
      return '$e';
    }
  }

  Future<(double, double)> _screenSize() async {
    final info = await api.screenInfo();
    if (info == null) throw '无法读取屏幕尺寸（会话可能已断开）';
    final (w, h, _) = info;
    if (w <= 0 || h <= 0) throw '屏幕尺寸异常：$w x $h';
    return (w, h);
  }

  /// 手指起点/终点：up = 手指上移，露出下方内容。
  (double, double, double, double) _swipeVector(
      String dir, double w, double h, double f) {
    final cx = w / 2, cy = h / 2;
    final dx = w * f / 2, dy = h * f / 2;
    switch (dir) {
      case 'down':
        return (cx, cy - dy, cx, cy + dy);
      case 'left':
        return (cx + dx, cy, cx - dx, cy);
      case 'right':
        return (cx - dx, cy, cx + dx, cy);
      case 'up':
      default:
        return (cx, cy + dy, cx, cy - dy);
    }
  }

  Future<String> _observeTree() async {
    const group = 'xb_scene_observe';
    final vm = api.vmClient;
    if (vm == null) return 'tree=N/A';
    try {
      final iso = await vm.isolateId();
      final r = await vm.rawRpc(
          'ext.flutter.inspector.getRootWidgetSummaryTree',
          <String, Object?>{'isolateId': iso, 'objectGroup': group});
      final s = '${r['result'] ?? ''}';
      try {
        await vm.rawRpc('ext.flutter.inspector.disposeGroup',
            <String, Object?>{'isolateId': iso, 'objectGroup': group});
      } catch (_) {}
      return 'tree=${s.length}B';
    } catch (_) {
      return 'tree=N/A';
    }
  }
}
