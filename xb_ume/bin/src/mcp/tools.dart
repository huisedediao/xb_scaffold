// MCP 工具注册表与核心工具实现（感知 / 操作 / 场景编排）。
//
// 设计约定：
//   - 每个工具只做「一次 VM 往返 + 结果整形」，不做隐式重试；
//   - 写操作统一走 ctx.sessions.serializeWrite，避免并发注入手势；
//   - 工具失败抛 McpToolException（带 hint），由 server 转 isError=true；
//   - 返回结构化 JSON，同时给一段可读 text 便于模型直读。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../device/flutter_run.dart';
import '../device/registry.dart';
import '../paths.dart';
import '../scenario/expressions.dart';
import '../scenario/gestures.dart';
import '../scenario/inject.dart';
import '../scenario/vm_client.dart';
import 'protocol.dart';
import 'scenario_service.dart';
import 'session_registry.dart';

/// 工具分组（配合 --tool-groups 开关）。
class ToolGroup {
  static const String core = 'core';
  static const String diagnose = 'diagnose';
  static const String runSafe = 'run-safe';
  static const String inspect = 'inspect';
  static const String act = 'act';
  static const String deviceWrite = 'device-write';
  static const String ai = 'ai';
  static const String ide = 'ide';

  /// 默认开启的扩展组（只读 / 安全阀）。
  static const Set<String> defaultExtra = <String>{diagnose, runSafe};

  /// 默认关闭、需显式开启的扩展组。
  static const Set<String> optIn = <String>{
    inspect,
    act,
    deviceWrite,
    ai,
    ide,
  };
}

/// 工具 handler：抛 McpToolException 表示可预期的失败。
typedef McpToolHandler = Future<McpToolResult> Function(
  McpToolContext ctx,
  Map<String, Object?> args,
);

class McpTool {
  McpTool({
    required this.name,
    required this.title,
    required this.description,
    required this.group,
    required this.inputSchema,
    required this.handler,
  });

  final String name;
  final String title;
  final String description;
  final String group;
  final Map<String, Object?> inputSchema;
  final McpToolHandler handler;

  Map<String, Object?> listing() => <String, Object?>{
        'name': name,
        'title': title,
        'description': description,
        'inputSchema': inputSchema,
      };
}

/// 工具运行上下文（由 server 持有单实例）。
class McpToolContext {
  McpToolContext({
    required this.sessions,
    required this.scenarios,
    DeviceRegistry? devices,
    FlutterRunLauncher? launcher,
    this.allowEval = false,
    this.deviceBackend = 'auto',
  })  : devices = devices ?? DeviceRegistry.fromSpec(deviceBackend),
        launcher = launcher ?? FlutterRunLauncher();

  final SessionRegistry sessions;
  final ScenarioService scenarios;

  /// 设备后端注册表（P2：adb/hdc/simctl/idevice）。
  final DeviceRegistry devices;

  /// flutter run 进程句柄（launch/terminate 用）。
  final FlutterRunLauncher launcher;

  /// xbume_eval 的二次开关（--allow-eval）。
  final bool allowEval;

  /// 设备后端选择：auto / adb,hdc / mobile-mcp（P2 接入）。
  final String deviceBackend;
}

// ── 公共辅助 ──

Map<String, Object?> _schema(
  Map<String, Object?> properties, [
  List<String>? required,
]) =>
    toolSchema(properties, required);

Map<String, Object?> _sessionIdProp() => prop(
      'string',
      '会话 id（如 s65296）；省略时用当前会话（xbume_use_session 或唯一会话）',
    );

/// 当前会话（含自动发现 + 友好报错）。
Future<McpSession> _session(
    McpToolContext ctx, Map<String, Object?> args) async {
  final id = optionalString(args, 'sessionId');
  if (id != null) return ctx.sessions.use(id);
  if (ctx.sessions.current == null) await ctx.sessions.refresh(force: true);
  try {
    return ctx.sessions.requireCurrent();
  } on StateError catch (e) {
    throw McpToolException(e.message, hint: '先调用 xbume_sessions 查看可用会话');
  }
}

/// 路由栈顶名（失败返回 null，不阻断主流程）。
Future<String?> _topRoute(VmClient vm) async {
  try {
    final s = await vm.evalStringOn(kLibNavigator, routesExpr);
    if (s == 'NO_ROOT' || s == 'NO_NAV') return null;
    final names = s.split(',').where((e) => e.isNotEmpty).toList();
    return names.isEmpty ? null : names.last;
  } catch (_) {
    return null;
  }
}

Map<String, Object?>? _parseBounds(String raw) {
  if (raw.isEmpty) return null;
  final p = raw.split(',');
  if (p.length < 4) return null;
  final v = p.map(int.tryParse).toList();
  if (v.any((e) => e == null)) return null;
  return <String, Object?>{
    'x': v[0],
    'y': v[1],
    'w': v[2],
    'h': v[3],
  };
}

/// 解析 findWidgetExpr 输出为结构化列表。
List<Map<String, Object?>> parseFindWidget(String raw) {
  if (raw == 'NO_ROOT' || raw == 'NOT_FOUND' || raw.isEmpty) {
    return const <Map<String, Object?>>[];
  }
  final out = <Map<String, Object?>>[];
  for (final row in raw.split('\u0003')) {
    if (row.isEmpty) continue;
    final f = row.split('\u0001');
    if (f.length < 7) continue;
    out.add(<String, Object?>{
      'ref': int.tryParse(f[0]),
      'depth': int.tryParse(f[1]),
      'type': f[2],
      'key': f[3],
      'bounds': _parseBounds(f[4]),
      'text': f[5],
      'source': f[6],
    });
  }
  return out;
}

/// 解析 screenInfoExpr 输出。
(int, int)? pngSize(Uint8List bytes) {
  if (bytes.length < 24) return null;
  if (bytes[0] != 0x89 || bytes[1] != 0x50) return null;
  final bd = ByteData.sublistView(bytes);
  return (bd.getUint32(16), bd.getUint32(20));
}

/// 输出路径白名单：XB_UME_HOME / 当前工作目录 / 系统临时目录 / 用户 HOME。
///
/// HOME 纳入白名单是因为 MCP 进程的 cwd 由宿主客户端决定（常为项目根），
/// 而截图常需落到项目目录；仍拒绝 `..` 与经符号链接逃出白名单的路径。
String resolveOutputPath(String raw) {
  final f = File(raw);
  final abs = f.isAbsolute ? f.path : '${Directory.current.path}/$raw';
  final norm = Uri.file(abs).normalizePath().toFilePath();
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  final roots = <String>[
    xbUmeHome(),
    Directory.current.path,
    Directory.systemTemp.path,
    if (home.isNotEmpty) home,
  ].map((e) => _realPath(e)).toList();
  final real = _realPath(norm);
  for (final r in roots) {
    if (real == r || real.startsWith('$r/')) return norm;
  }
  throw McpToolException(
    '输出路径不在允许范围：$norm',
    hint: '只允许写入 XB_UME_HOME、当前工作目录、系统临时目录或用户目录',
  );
}

/// 解析符号链接：对不存在的路径，解析最近的已存在祖先后拼回剩余部分。
String _realPath(String path) {
  var cur = path;
  final tail = <String>[];
  while (true) {
    try {
      final f = File(cur);
      final d = Directory(cur);
      if (f.existsSync()) {
        final real = f.resolveSymbolicLinksSync();
        return tail.isEmpty ? real : '$real/${tail.reversed.join('/')}';
      }
      if (d.existsSync()) {
        final real = d.resolveSymbolicLinksSync();
        return tail.isEmpty ? real : '$real/${tail.reversed.join('/')}';
      }
    } catch (_) {
      return path;
    }
    final parent = File(cur).parent.path;
    if (parent == cur || parent.isEmpty) return path;
    tail.add(cur.split(Platform.pathSeparator).last);
    cur = parent;
  }
}

// ── 核心工具 ──

List<McpTool> coreTools() => <McpTool>[
      _sessionsTool(),
      _useSessionTool(),
      _screenshotTool(),
      _findWidgetTool(),
      _tapTool(),
      _inputTool(),
      _swipeTool(),
      _navigateTool(),
      _routeStackTool(),
      _networkTool(),
      _consoleTool(),
      _scenarioRunTool(),
      _scenarioStatusTool(),
      _scenarioListTool(),
      _scenarioStopTool(),
      _reportTool(),
    ];

McpTool _sessionsTool() => McpTool(
      name: 'xbume_sessions',
      title: '列出 Flutter 调试会话',
      description: '扫描本机回环地址上的 Flutter VM service（含 adb/hdc 转发来源），'
          '返回会话 id、端口、app 名与当前选中项。任何其他工具报「未选择会话」时先调它。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'refresh':
            prop('boolean', '强制重新扫描（默认 3 秒内复用上次结果）', defaultValue: false),
      }),
      handler: (ctx, args) async {
        final force = optionalBool(args, 'refresh');
        final list = await ctx.sessions.refresh(force: force);
        final cur = ctx.sessions.currentId;
        final items = list
            .map((s) => s.toJson(current: s.id == cur))
            .toList(growable: false);
        final sb = StringBuffer();
        if (items.isEmpty) {
          sb.write('未发现调试会话。');
          if (ctx.sessions.lastError != null) {
            sb.write('\n扫描异常：${ctx.sessions.lastError}');
          }
          sb.write('\n提示：先在目标设备上以 debug 模式运行 app（flutter run -d <device>），'
              '或用 xbume_app_launch 启动。');
        } else {
          for (final s in items) {
            final app = (s['app'] ?? '').toString();
            sb.write('${s['current'] == true ? '▶ ' : '  '}${s['id']}'
                '${app.isEmpty ? '' : ' · $app'}'
                ' · ${s['source']}${s['connected'] == true ? ' · 已连接' : ''}\n');
          }
        }
        return McpToolResult.text(sb.toString().trimRight(),
            structured: <String, Object?>{
              'count': items.length,
              'current': cur,
              'sessions': items,
              if (ctx.sessions.lastError != null)
                'error': ctx.sessions.lastError,
            });
      },
    );

McpTool _useSessionTool() => McpTool(
      name: 'xbume_use_session',
      title: '选定后续工具使用的会话',
      description: '设定当前会话，并做一次连通性验证（读取路由栈）。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': prop('string', '会话 id（xbume_sessions 返回的 id，如 s65296）'),
      }, <String>[
        'sessionId'
      ]),
      handler: (ctx, args) async {
        final id =
            requireString(args, 'sessionId', hint: '先调用 xbume_sessions 获取 id');
        McpSession s;
        try {
          s = await ctx.sessions.use(id);
        } on StateError catch (e) {
          throw McpToolException(e.message);
        }
        final route = await _topRoute(s.client);
        final app =
            (s.appName.isEmpty || s.appName == 'vm') ? '' : ' ${s.appName}';
        return McpToolResult.text(
          '已切换到 ${s.id}$app（端口 ${s.port}）'
          '${route == null ? '，路由栈读取失败（可能不是 Flutter 界面）' : '，当前路由 $route'}',
          structured: <String, Object?>{
            'sessionId': s.id,
            'wsUrl': s.wsUrl,
            'app': s.appName,
            'source': s.source,
            'route': route,
          },
        );
      },
    );

McpTool _screenshotTool() => McpTool(
      name: 'xbume_screenshot',
      title: '截取当前界面',
      description: '返回 PNG 截图（image content，可直接看）+ 像素尺寸；'
          '可选 savePath 落盘。iOS 走 inspector 渲染路径兜底。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'savePath': prop('string', '落盘路径（限 XB_UME_HOME / 工作目录 / 临时目录）'),
      }),
      handler: (ctx, args) async {
        final s = await _session(ctx, args);
        String b64;
        try {
          b64 = await s.client.screenshotBase64();
        } catch (e) {
          throw McpToolException('截图失败：$e', hint: '确认会话仍在调试模式运行（图形界面已渲染首帧）');
        }
        if (b64.isEmpty) {
          throw McpToolException('截图返回空数据',
              hint: 'iOS 需真机 debug 模式；release/AOT 不提供 inspector');
        }
        final bytes = base64Decode(b64);
        final size = pngSize(bytes);
        String? saved;
        final savePath = optionalString(args, 'savePath');
        if (savePath != null) {
          final p = resolveOutputPath(savePath);
          final f = File(p);
          f.parent.createSync(recursive: true);
          f.writeAsBytesSync(bytes);
          saved = p;
        }
        final dims = size == null ? '尺寸未知' : '${size.$1}x${size.$2}';
        return McpToolResult.image(
          b64,
          caption: '截图 $dims · ${(bytes.length / 1024).toStringAsFixed(0)}KB'
              '${saved == null ? '' : ' · 已保存 $saved'}',
          structured: <String, Object?>{
            'sessionId': s.id,
            'width': size?.$1,
            'height': size?.$2,
            'bytes': bytes.length,
            'savedPath': saved,
          },
        );
      },
    );

McpTool _findWidgetTool() => McpTool(
      name: 'xbume_find_widget',
      title: '按条件查找组件',
      description:
          '在 Element 树中按类型/Key/文本/Semantics 查找，返回 ref（供 xbume_tap 精确点击）、'
          'bounds（逻辑像素）与源码位置。比让模型估坐标可靠。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'by': prop('string', '匹配维度',
            enumValues: <String>['type', 'key', 'text', 'semantics']),
        'value': prop('string', '匹配值（默认包含匹配，exact=true 时全等）'),
        'exact': prop('boolean', '全等匹配（默认 false）', defaultValue: false),
        'limit': prop('integer', '最多返回条数（默认 20）', defaultValue: 20),
      }, <String>[
        'by',
        'value'
      ]),
      handler: (ctx, args) async {
        final s = await _session(ctx, args);
        final by = requireString(args, 'by').toLowerCase();
        const dims = <String>['type', 'key', 'text', 'semantics'];
        if (!dims.contains(by)) {
          throw McpToolException('by 必须是 ${dims.join('/')}');
        }
        final value = requireString(args, 'value');
        final limit = (optionalInt(args, 'limit') ?? 20).clamp(1, 200);
        final raw = await s.client.evalStringOn(
          kLibBinding,
          findWidgetExpr(
            by: by,
            value: value,
            exact: optionalBool(args, 'exact'),
            limit: limit,
          ),
        );
        final items = parseFindWidget(raw);
        final sb = StringBuffer();
        if (items.isEmpty) {
          sb.write('未找到匹配（by=$by value=$value）。');
          if (raw == 'NO_ROOT') sb.write(' app 尚未渲染首帧。');
        } else {
          for (final it in items) {
            final b = it['bounds'] as Map<String, Object?>?;
            sb.write('ref=${it['ref']} ${it['type']}'
                '${(it['key'] as String).isEmpty ? '' : ' key=${it['key']}'}'
                '${(it['text'] as String).isEmpty ? '' : ' text="${it['text']}"'}'
                '${b == null ? '' : ' @(${b['x']},${b['y']} ${b['w']}x${b['h']})'}'
                '${(it['source'] as String).isEmpty ? '' : ' ← ${it['source']}'}\n');
          }
        }
        return McpToolResult.text(sb.toString().trimRight(),
            structured: <String, Object?>{
              'count': items.length,
              'by': by,
              'value': value,
              'items': items,
            });
      },
    );

McpTool _tapTool() => McpTool(
      name: 'xbume_tap',
      title: '点击组件或坐标',
      description: '三种定位方式：ref（xbume_find_widget 返回）、by+value、x+y 坐标。'
          '优先用 ref；坐标是最后手段。点击后返回最新栈顶路由。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'ref': prop('integer', 'xbume_find_widget 返回的 ref'),
        'by': prop('string', '匹配维度',
            enumValues: <String>['type', 'key', 'text', 'semantics']),
        'value': prop('string', '匹配值（配合 by）'),
        'x': prop('number', '逻辑像素 x'),
        'y': prop('number', '逻辑像素 y'),
        'phys': prop('boolean', 'x/y 是否为截图物理像素', defaultValue: false),
        'waitMs': prop('integer', '点击后等待动画/导航的毫秒数', defaultValue: 350),
      }),
      handler: (ctx, args) async {
        final s = await _session(ctx, args);
        final ref = optionalInt(args, 'ref');
        final x = optionalDouble(args, 'x');
        final y = optionalDouble(args, 'y');
        final by = optionalString(args, 'by');
        final value = optionalString(args, 'value');
        final waitMs = (optionalInt(args, 'waitMs') ?? 350).clamp(0, 5000);
        final actual = await ctx.sessions.serializeWrite<String>(() async {
          if (ref != null) {
            return evalInject(s.client, kLibBinding,
                tapElementExpr(ref, pointer: nextPointerId()));
          }
          if (by != null && value != null) {
            final raw = await s.client.evalStringOn(
                kLibBinding, findWidgetExpr(by: by, value: value, limit: 1));
            final items = parseFindWidget(raw);
            if (items.isEmpty) return 'NOT_FOUND';
            final idx = items.first['ref'];
            if (idx is! int) return 'NOT_FOUND';
            return evalInject(s.client, kLibBinding,
                tapElementExpr(idx, pointer: nextPointerId()));
          }
          if (x != null && y != null) {
            return evalInject(
              s.client,
              kLibBinding,
              tapExpr(x.toString(), y.toString(),
                  phys: optionalBool(args, 'phys'), pointer: nextPointerId()),
            );
          }
          return 'NO_TARGET';
        });
        if (actual == 'NO_TARGET') {
          throw McpToolException('缺少点击目标', hint: '传 ref，或 by+value，或 x+y');
        }
        if (actual == 'NOT_FOUND') {
          throw McpToolException('未找到匹配组件（by=$by value=$value）',
              hint: '先用 xbume_find_widget 确认 ref');
        }
        final ok = actual == 'OK' || actual.startsWith('OK:');
        if (!ok) {
          throw McpToolException(
            '点击注入失败：${actual.startsWith('ERR:') ? actual.substring(4) : actual}',
            hint: actual == 'NO_BOX' ? '该组件没有可点击的渲染盒，换父级 ref' : null,
          );
        }
        if (waitMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: waitMs));
        }
        final route = await _topRoute(s.client);
        return McpToolResult.text(
          '点击成功${actual.startsWith('OK:') ? ' @${actual.substring(3)}' : ''}'
          '${route == null ? '' : '，当前路由 $route'}',
          structured: <String, Object?>{
            'ok': true,
            'actual': actual,
            'route': route,
            'target': ref == null ? (by == null ? 'xy' : 'by') : 'ref',
          },
        );
      },
    );

McpTool _inputTool() => McpTool(
      name: 'xbume_input',
      title: '向焦点输入框写文本',
      description: '通过 TextInputConnection 整体替换当前焦点输入框内容。'
          '需先 xbume_tap 输入框建立连接，否则返回 NO_CONN。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'text': prop('string', '要写入的文本（整体替换现有内容）'),
      }, <String>[
        'text'
      ]),
      handler: (ctx, args) async {
        final s = await _session(ctx, args);
        final text = (args['text'] ?? '').toString();
        final r = await ctx.sessions.serializeWrite<String>(
          () => s.client.evalStringOn(kLibTextInput, inputExpr(text)),
        );
        if (r == 'NO_CONN') {
          throw McpToolException('没有活跃的输入连接',
              hint: '先用 xbume_tap 点击输入框（ref 定位）再调用');
        }
        if (r != 'OK') {
          throw McpToolException('文本注入失败：$r');
        }
        return McpToolResult.text('已写入 ${text.length} 个字符',
            structured: <String, Object?>{
              'ok': true,
              'length': text.length,
            });
      },
    );

McpTool _swipeTool() => McpTool(
      name: 'xbume_swipe',
      title: '滑动/拖拽',
      description: '三种方式：from+to 坐标、direction（up/down/left/right，按屏幕比例）、'
          'ref（滑该组件，常见于轮播/列表项）。内部按 8 段注入带 delta 与非零时间戳的移动事件。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'direction': prop('string', '方向',
            enumValues: <String>['up', 'down', 'left', 'right']),
        'distance': prop('number', '滑动距离（逻辑像素，默认屏高/宽 76%）'),
        'durationMs': prop('integer', '滑动时长（默认 300ms）', defaultValue: 300),
        'from': objectProp('起点 {x, y}（逻辑像素）'),
        'to': objectProp('终点 {x, y}（逻辑像素）'),
        'ref': prop('integer', '对指定组件中心滑动（配合 direction 使用）'),
      }),
      handler: (ctx, args) async {
        final s = await _session(ctx, args);
        final durationMs =
            (optionalInt(args, 'durationMs') ?? 300).clamp(40, 5000);
        final from = args['from'];
        final to = args['to'];
        final direction = optionalString(args, 'direction');
        final ref = optionalInt(args, 'ref');
        final result =
            await ctx.sessions.serializeWrite<(String, String)>(() async {
          if (from is Map && to is Map) {
            final x1 = _numOf(from['x']);
            final y1 = _numOf(from['y']);
            final x2 = _numOf(to['x']);
            final y2 = _numOf(to['y']);
            if (x1 == null || y1 == null || x2 == null || y2 == null) {
              return ('', 'from/to 需要数字 x、y');
            }
            return swipeSequence(s.client,
                x1: x1, y1: y1, x2: x2, y2: y2, durationMs: durationMs);
          }
          if (direction == null) {
            return ('', '需要 direction 或 from+to');
          }
          if (ref != null) {
            final c = await s.client
                .evalStringOn(kLibBinding, elementCenterExpr(ref));
            final p = c.split(',');
            if (p.length < 2) return ('', 'ref=$ref 无法定位：$c');
            final cx = double.tryParse(p[0]);
            final cy = double.tryParse(p[1]);
            if (cx == null || cy == null) return ('', 'ref=$ref 坐标解析失败：$c');
            final info = await screenInfo(s.client);
            if (info == null) return ('', '无法读取屏幕尺寸');
            final (w, h, _) = info;
            final vertical = direction == 'up' || direction == 'down';
            final len = (vertical ? h : w) * 0.3;
            final dx =
                direction == 'left' ? -len : (direction == 'right' ? len : 0.0);
            final dy =
                direction == 'up' ? -len : (direction == 'down' ? len : 0.0);
            return swipeSequence(s.client,
                x1: cx,
                y1: cy,
                x2: cx + dx,
                y2: cy + dy,
                durationMs: durationMs);
          }
          return swipeByDirection(s.client, direction,
              distance: optionalDouble(args, 'distance'),
              durationMs: durationMs);
        });
        final (actual, err) = result;
        if (err.isNotEmpty) throw McpToolException(err);
        return McpToolResult.text(actual, structured: <String, Object?>{
          'ok': true,
          'actual': actual,
        });
      },
    );

double? _numOf(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

McpTool _navigateTool() => McpTool(
      name: 'xbume_navigate',
      title: '路由前进/返回',
      description:
          'back=true 时 pop 当前页；否则按 routeName pushNamed（需 app 有 onGenerateRoute）。'
          '返回操作结果与最新路由栈。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'routeName': prop('string', '目标路由名（pushNamed）'),
        'back': prop('boolean', 'true 时执行返回上一页', defaultValue: false),
      }),
      handler: (ctx, args) async {
        final s = await _session(ctx, args);
        final back = optionalBool(args, 'back');
        final name = optionalString(args, 'routeName');
        if (!back && name == null) {
          throw McpToolException('需要 routeName 或 back=true');
        }
        final op = await ctx.sessions.serializeWrite<String>(() => evalInject(
            s.client,
            kLibNavigator,
            routeOpExpr(back ? 'pop' : 'push', name: name ?? '')));
        final ok = op == 'OK';
        if (!ok) {
          final hint = switch (op) {
            'LAST_ROUTE' => '已在根路由，无法再返回',
            'BUSY' => busyHint,
            'NO_NAV' => '界面没有 Navigator',
            'NO_ROUTE_TABLE' => 'app 未配置 onGenerateRoute，无法按名字跳转',
            'UNKNOWN' => '路由表中没有该名字：$name',
            _
                when op.startsWith(
                    'ERR:FlutterError:Could not find a generator') =>
              '应用没有注册名为 $name 的命名路由（页面可能是用 MaterialPageRoute(settings:) '
                  '直接 push 的），改用 xbume_tap 点入口按钮进入',
            _ => null,
          };
          throw McpToolException('导航失败：$op', hint: hint);
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final stack = await _routeNames(s.client);
        return McpToolResult.text(
          '${back ? '返回' : '跳转 $name'}成功，路由栈：${stack.isEmpty ? 'N/A' : stack.join(' > ')}',
          structured: <String, Object?>{
            'ok': true,
            'action': back ? 'pop' : 'push',
            'routeName': name,
            'stack': stack,
          },
        );
      },
    );

Future<List<String>> _routeNames(VmClient vm) async {
  try {
    final s = await vm.evalStringOn(kLibNavigator, routesExpr);
    if (s == 'NO_ROOT' || s == 'NO_NAV') return const <String>[];
    return s.split(',').where((e) => e.isNotEmpty).toList();
  } catch (_) {
    return const <String>[];
  }
}

McpTool _routeStackTool() => McpTool(
      name: 'xbume_route_stack',
      title: '读取路由栈详情',
      description: '返回从底到顶的路由名、Route 类型、参数类型与是否可见（isPresent）。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
      }),
      handler: (ctx, args) async {
        final s = await _session(ctx, args);
        final raw = await s.client.evalStringOn(kLibNavigator, routeStackExpr);
        if (raw == 'NO_ROOT') throw McpToolException('app 尚未渲染首帧');
        if (raw == 'NO_NAV') throw McpToolException('界面没有 Navigator（可能是自定义路由）');
        final items = <Map<String, Object?>>[];
        for (final row in raw.split('\u0003')) {
          if (row.isEmpty) continue;
          final f = row.split('\u0001');
          if (f.length < 4) continue;
          items.add(<String, Object?>{
            'name': f[0],
            'routeType': f[1],
            'argumentsType': f[2],
            'present': f[3] == '1',
          });
        }
        final names = items.map((e) => e['name']).join(' > ');
        return McpToolResult.text('路由栈：$names', structured: <String, Object?>{
          'count': items.length,
          'top': items.isEmpty ? null : items.last['name'],
          'items': items,
        });
      },
    );

McpTool _networkTool() => McpTool(
      name: 'xbume_network',
      title: '读取网络请求记录',
      description: '读取 app 内 xb_ume 网络拦截记录（需 app 接入 Network 模块），'
          '支持按 URL 片段/方法/状态码/时间窗过滤。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'urlContains': prop('string', 'URL 包含的子串'),
        'method': prop('string', 'HTTP 方法（GET/POST…）'),
        'minStatus': prop('integer', '最小状态码（如 400 只看失败）'),
        'withinLastMs': prop('integer', '只看最近多少毫秒内的记录'),
        'limit': prop('integer', '最多返回条数（默认 30）', defaultValue: 30),
      }),
      handler: (ctx, args) async {
        final s = await _session(ctx, args);
        final within = optionalInt(args, 'withinLastMs');
        final sinceMs = within == null
            ? null
            : DateTime.now()
                .subtract(Duration(milliseconds: within.clamp(0, 86400000)))
                .millisecondsSinceEpoch;
        final limit = (optionalInt(args, 'limit') ?? 30).clamp(1, 300);
        final raw = await s.client.evalStringOn(
            kLibXbUme, networkExpr(sinceMs: sinceMs, limit: limit * 3));
        final urlFilter = optionalString(args, 'urlContains');
        final method = optionalString(args, 'method')?.toUpperCase();
        final minStatus = optionalInt(args, 'minStatus');
        final items = <Map<String, Object?>>[];
        for (final row in raw.split('\u0003')) {
          if (row.isEmpty) continue;
          final f = row.split('\u0001');
          if (f.length < 7) continue;
          final url = f[1];
          final m = f[0].toUpperCase();
          final code = int.tryParse(f[2]);
          if (urlFilter != null && !url.contains(urlFilter)) continue;
          if (method != null && m != method) continue;
          if (minStatus != null && (code ?? 0) < minStatus) continue;
          items.add(<String, Object?>{
            'method': f[0],
            'url': url,
            'statusCode': code,
            'status': f[3],
            'durationMs': int.tryParse(f[4]),
            'time': f[5],
            'error': f[6],
          });
        }
        final capped =
            items.length > limit ? items.sublist(items.length - limit) : items;
        final sb = StringBuffer();
        if (capped.isEmpty) {
          sb.write('没有匹配的网络记录。');
        } else {
          for (final e in capped) {
            sb.write('${e['method']} ${e['statusCode'] ?? '-'} '
                '${e['durationMs'] ?? '-'}ms ${e['url']}'
                '${(e['error'] as String).isEmpty ? '' : ' ⚠ ${e['error']}'}\n');
          }
        }
        return McpToolResult.text(sb.toString().trimRight(),
            structured: <String, Object?>{
              'count': capped.length,
              'items': capped,
            });
      },
    );

McpTool _consoleTool() => McpTool(
      name: 'xbume_console',
      title: '读取 app 日志',
      description:
          '读取 app 内 XBUme 日志（debug/info/warn/error/fatal），支持级别、关键字、时间窗过滤。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'level': prop('string', '最低级别',
            enumValues: <String>['debug', 'info', 'warn', 'error', 'fatal']),
        'keyword': prop('string', '消息或 tag 包含的关键字'),
        'sinceMs': prop('integer', '只看该时间戳（毫秒）之后的记录'),
        'limit': prop('integer', '最多返回条数（默认 50）', defaultValue: 50),
      }),
      handler: (ctx, args) async {
        final s = await _session(ctx, args);
        final limit = (optionalInt(args, 'limit') ?? 50).clamp(1, 500);
        final raw = await s.client.evalStringOn(
          kLibXbUme,
          consoleExpr(
            level: optionalString(args, 'level'),
            keyword: optionalString(args, 'keyword'),
            sinceMs: optionalInt(args, 'sinceMs'),
            limit: limit,
          ),
        );
        final items = <Map<String, Object?>>[];
        for (final row in raw.split('\u0003')) {
          if (row.isEmpty) continue;
          final f = row.split('\u0001');
          if (f.length < 4) continue;
          items.add(<String, Object?>{
            'level': f[0],
            'tag': f[1],
            'message': f[2],
            'time': f[3],
          });
        }
        final sb = StringBuffer();
        if (items.isEmpty) {
          sb.write('没有匹配的日志。');
        } else {
          for (final e in items) {
            sb.write('[${e['level']}] ${e['tag']}: ${e['message']}\n');
          }
        }
        return McpToolResult.text(sb.toString().trimRight(),
            structured: <String, Object?>{
              'count': items.length,
              'items': items,
            });
      },
    );

McpTool _scenarioRunTool() => McpTool(
      name: 'xbume_scenario_run',
      title: '运行场景',
      description: '异步运行 GUI 保存的场景（name）或内联步骤（steps），立即返回 runId；'
          '用 xbume_scenario_status 查进度。同一时间只允许一个运行实例。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'name': prop('string', r'场景名（$XB_UME_HOME/scenarios 下的 json）'),
        'steps': arrayProp('内联步骤数组（与 GUI 场景格式一致）', 'object'),
        'continueOnFail': prop('boolean', '失败后继续执行', defaultValue: false),
        'shotEveryStep': prop('boolean', '每步都截图（默认只截失败步）', defaultValue: false),
      }),
      handler: (ctx, args) async {
        final name = optionalString(args, 'name');
        final rawSteps = args['steps'];
        var steps = <Map<String, dynamic>>[];
        if (rawSteps is List) {
          for (final s in rawSteps) {
            if (s is Map) steps.add(Map<String, dynamic>.from(s));
          }
        }
        try {
          final run = ctx.scenarios.start(
            name: name,
            steps: steps.isEmpty ? null : steps,
            sessionId: optionalString(args, 'sessionId'),
            continueOnFail: optionalBool(args, 'continueOnFail'),
            shotEveryStep: optionalBool(args, 'shotEveryStep'),
          );
          return McpToolResult.text(
            '已启动 ${run.runId}（${run.name}）。用 xbume_scenario_status 查询进度。',
            structured: <String, Object?>{
              'runId': run.runId,
              'name': run.name,
              'sessionId': run.sessionId,
              'startedAt': run.startedAt.toIso8601String(),
            },
          );
        } on StateError catch (e) {
          throw McpToolException(e.message);
        } on ArgumentError catch (e) {
          throw McpToolException('${e.message}');
        } on FormatException catch (e) {
          throw McpToolException('场景解析失败：${e.message}');
        }
      },
    );

McpTool _scenarioStatusTool() => McpTool(
      name: 'xbume_scenario_status',
      title: '查询场景运行状态',
      description: '按 runId 返回逐步骤 pass/fail/skip、错误与耗时；runId 省略时返回当前/最近一次运行。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'runId': prop('string', 'xbume_scenario_run 返回的 runId'),
      }),
      handler: (ctx, args) async {
        final id = optionalString(args, 'runId');
        ScenarioRun? run =
            id == null ? ctx.scenarios.active : ctx.scenarios.byId(id);
        if (run == null) {
          final all = ctx.scenarios.active;
          run = all;
        }
        if (run == null) {
          throw McpToolException('没有可查询的运行记录', hint: '先调用 xbume_scenario_run');
        }
        final json = run.toJson();
        final sb = StringBuffer();
        sb.write('${run.name} · ${run.done ? '已结束' : '运行中'}'
            ' · ${run.passCount} pass / ${run.failCount} fail / ${run.skipCount} skip'
            '${run.error == null ? '' : ' · ${run.error}'}\n');
        for (final r in run.results) {
          sb.write('${r.index + 1}. ${r.type} ${r.status.toUpperCase()}'
              '${r.error.isEmpty ? '' : ' · ${r.error}'}\n');
        }
        if (run.reportPath != null) sb.write('报告：${run.reportPath}');
        return McpToolResult.text(sb.toString().trimRight(), structured: json);
      },
    );

McpTool _scenarioListTool() => McpTool(
      name: 'xbume_scenario_list',
      title: '列出可用场景',
      description: r'列出 $XB_UME_HOME/scenarios 下 GUI 保存的场景与步骤数。',
      group: ToolGroup.runSafe,
      inputSchema: _schema(const <String, Object?>{}),
      handler: (ctx, args) async {
        final items = ctx.scenarios.listScenarios();
        final sb = StringBuffer();
        if (items.isEmpty) {
          sb.write('没有场景（目录 ${ctx.scenarios.scenariosDir}）。先在 GUI「自动化」Tab 保存。');
        } else {
          for (final e in items) {
            sb.write('${e['name']} · ${e['stepCount']} 步\n');
          }
        }
        return McpToolResult.text(sb.toString().trimRight(),
            structured: <String, Object?>{
              'count': items.length,
              'dir': ctx.scenarios.scenariosDir,
              'scenarios': items,
            });
      },
    );

McpTool _scenarioStopTool() => McpTool(
      name: 'xbume_scenario_stop',
      title: '停止场景运行',
      description: '请求停止指定运行（或当前运行）；已执行步骤结果保留，剩余步骤标 skip。',
      group: ToolGroup.runSafe,
      inputSchema: _schema(<String, Object?>{
        'runId': prop('string', '要停止的 runId（省略则停当前运行）'),
      }),
      handler: (ctx, args) async {
        final id = optionalString(args, 'runId') ?? ctx.scenarios.active?.runId;
        if (id == null) {
          throw McpToolException('没有运行中的场景');
        }
        final ok = ctx.scenarios.stop(id);
        if (!ok) throw McpToolException('$id 不在运行中（可能已完成）');
        return McpToolResult.text('已发送停止信号：$id',
            structured: <String, Object?>{'runId': id, 'stopRequested': true});
      },
    );

McpTool _reportTool() => McpTool(
      name: 'xbume_report',
      title: '取场景报告',
      description: '返回运行报告 HTML 的路径与大小（可用浏览器打开）；无报告时说明原因。',
      group: ToolGroup.runSafe,
      inputSchema: _schema(<String, Object?>{
        'runId': prop('string', '运行 id（省略取最近完成的）'),
      }),
      handler: (ctx, args) async {
        final id = optionalString(args, 'runId');
        final run = id == null ? ctx.scenarios.active : ctx.scenarios.byId(id);
        if (run == null) {
          throw McpToolException('没有运行记录');
        }
        if (!run.done) {
          throw McpToolException('${run.runId} 仍在运行，结束后才有报告');
        }
        final path = run.reportPath;
        if (path == null) {
          throw McpToolException('报告未生成：${run.error ?? '未知原因'}');
        }
        final f = File(path);
        if (!f.existsSync()) {
          throw McpToolException('报告文件不存在：$path');
        }
        return McpToolResult.text('报告：$path（${f.lengthSync()} 字节）',
            structured: <String, Object?>{
              'runId': run.runId,
              'path': path,
              'bytes': f.lengthSync(),
            });
      },
    );
