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

import '../device/bridge.dart';
import '../device/flutter_run.dart';
import '../device/registry.dart';
import '../paths.dart';
import '../scenario/expressions.dart';
import '../scenario/gestures.dart';
import '../scenario/inject.dart';
import '../scenario/vm_client.dart';
import 'debug_pool.dart';
import 'gui_bridge.dart';
import 'instances.dart';
import 'lease.dart';
import 'protocol.dart';
import 'scenario_service.dart';
import 'session_check.dart';
import 'session_registry.dart';

/// 工具分组（配合 --tool-groups 开关）。
class ToolGroup {
  static const String core = 'core';
  static const String diagnose = 'diagnose';
  static const String runSafe = 'run-safe';
  static const String inspect = 'inspect';
  static const String act = 'act';
  static const String deviceWrite = 'device-write';

  /// 调试器（断点 / 单步 / 栈 / 变量）—— 直连 VM，不依赖工具箱。
  static const String debug = 'debug';

  /// 数据类（Storage / SQLite / 沙盒 / 文件监听）—— 借工具箱的本机能力。
  static const String data = 'data';

  /// 环境类（IDE 跳转 / 守护进程 / 对比 / 网络重放 / 时间轴控制）。
  static const String env = 'env';
  static const String ai = 'ai';
  static const String ide = 'ide';

  /// 默认开启的扩展组（只读 / 安全阀）。
  static const Set<String> defaultExtra = <String>{diagnose, runSafe};

  /// 默认关闭、需显式开启的扩展组。
  static const Set<String> optIn = <String>{
    inspect,
    act,
    deviceWrite,
    debug,
    data,
    env,
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
    this.instanceName = '',
    this.instancePort = 0,
    LeaseStore? leases,
    DebugSessionPool? debugPool,
    GuiBridge? guiBridge,
    this.guiPort,
  })  : devices = devices ?? DeviceRegistry.fromSpec(deviceBackend),
        launcher = launcher ?? FlutterRunLauncher(),
        leases = leases ??
            LeaseStore(
              instance: instanceName.isEmpty ? 'mcp-$pid' : instanceName,
              instancePid: pid,
              instancePort: instancePort,
            ) {
    // 调试池必须复用同一个 launcher：live 记录的认领（pidForPort）靠它，
    // 否则 MCP 拉起的会话在调试池里会被当成外部会话，热重载句柄丢掉。
    this.debugPool = debugPool ?? DebugSessionPool(launcher: this.launcher);
    this.guiBridge = guiBridge ?? GuiBridge(port: guiPort);
  }

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

  /// 本 MCP 实例名（`--name`；一 AI 一进程时用来区分「谁在驱动」）。
  final String instanceName;

  /// HTTP 实例的端口；stdio 实例为 0。
  final int instancePort;

  /// 会话 / 启动租约（跨实例互斥）。
  final LeaseStore leases;

  /// 工具箱端口（--gui-port）；为空时桥接层自己探测 46129..46138。
  final int? guiPort;

  /// 调试器会话池（每个 MCP 会话一个 DebugHub）。
  late final DebugSessionPool debugPool;

  /// 需要工具箱本机能力时用的 HTTP 桥。
  late final GuiBridge guiBridge;
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
/// 解析目标会话：显式 sessionId 优先，否则用当前选中会话。
Future<McpSession> resolveSession(
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

/// 会话租约 key（与 [LeaseStore.sessionKey] 同源）。
String sessionLeaseKey(McpSession s) => LeaseStore.sessionKey(s.id);

/// 启动租约 key：同设备 + 同项目目录会撞在一起（两个 AI 抢同一个 flutter run）。
String launchLeaseKey(String deviceId, String cwd) =>
    LeaseStore.launchKey(deviceId, cwd);

/// 拉起 / 停止 / force 重启前拿启动租约（同设备同目录）。
///
/// [steal] 只在显式 force 重启时传：那本身就是「顶掉对方会话」的语义，
/// 抢过来后把前持有者写进返回值，便于追。
Future<Lease> requireLaunchLease(
  McpToolContext ctx,
  String deviceId,
  String cwd,
  String op, {
  bool steal = false,
}) async {
  final key = launchLeaseKey(deviceId, cwd);
  final a = await ctx.leases.acquire(
    key,
    kind: 'launch',
    note: op,
    steal: steal,
  );
  final got = a.lease;
  if (got != null) return got;
  final h = a.holder!;
  throw McpToolException(
    '设备 $deviceId 上同一项目正由 ${ownerLabel(h.owner)} 拉起/调试'
    '（${h.note.isEmpty ? 'app_launch' : h.note}，${leaseAgo(h.renewedAt)}续期，'
    '约 ${leaseLeft(h)}后自动释放）',
    hint: '要复用它的会话：xbume_sessions → xbume_use_session，不用重启；'
        '确实要重启（会顶掉对方正在用的 app）传 force:true，会接管启动权；'
        '也可以先问对方释放（xbume_lease{"op":"release"}）。',
  );
}

/// 设备级写操作（按键 / 原生点击 / 装包）前的粗粒度检查：
/// 同设备上有别的实例正在驱动会话时拒掉（这些工具不绑会话，只能按设备比）。
void requireDeviceFree(McpToolContext ctx, String deviceId, String op) {
  for (final l in ctx.leases.list()) {
    if (l.owner == ctx.leases.me) continue;
    if (!l.key.startsWith('session-')) continue;
    final sid = l.key.substring('session-'.length);
    final s = ctx.sessions.byId(sid);
    if (s == null || s.deviceId != deviceId) continue;
    throw McpToolException(
      '设备 $deviceId 上的会话 $sid 正由 ${ownerLabel(l.owner)} 驱动，'
      '不能从外面注入 $op（会打乱对方的操作现场）',
      hint: '等对方释放（xbume_lease{"op":"status","sessionId":"$sid"} 看还剩多久），'
          '或确认后让对方自己执行；确实要接管用 xbume_lease{"op":"steal"}。',
    );
  }
}

/// 写操作前拿（或续期）会话租约。
///
/// 空闲 / 自己持有时静默拿到，AI 无感；被别人驱动时报「谁在占、还剩多久、
/// 三条出路」，并续上默认 10 分钟 TTL（每次写操作续期，崩了也不会锁死）。
Future<Lease> requireDriveLease(
  McpToolContext ctx,
  McpSession s,
  String op, {
  bool steal = false,
  String? note,
}) async {
  final a = await ctx.leases.acquire(
    sessionLeaseKey(s),
    note: note ?? op,
    steal: steal,
  );
  final got = a.lease;
  if (got != null) return got;
  throw busyLeaseError(ctx, s.id, a.holder!);
}

/// 解析会话 + 拿写租约（写工具统一入口）。
Future<McpSession> resolveDriveSession(
  McpToolContext ctx,
  Map<String, Object?> args,
  String op, {
  bool steal = false,
}) async {
  final s = await resolveSession(ctx, args);
  await requireDriveLease(ctx, s, op, steal: steal);
  return s;
}

/// 被别人驱动时的统一报错（写工具与 xbume_lease 共用）。
///
/// 同一个 MCP 实例里的另一条连接（同一助手开两个窗口都连一个进程）也会报 busy，
/// 且不会当成「自己续期」静默放行；这里多给一句提示。
McpToolException busyLeaseError(
  McpToolContext ctx,
  String sessionId,
  Lease h,
) {
  final sameInstance = h.owner.instance == ctx.leases.instance &&
      h.owner.pid == ctx.leases.instancePid;
  return McpToolException(
    '会话 $sessionId 正由 ${ownerLabel(h.owner)} 驱动'
    '（${h.note.isEmpty ? '写操作' : h.note}，${leaseAgo(h.renewedAt)}续期，'
    '约 ${leaseLeft(h)}后自动释放）',
    hint: sameInstance
        ? '这是同一个 MCP 实例的另一条连接（通常是同一助手的另一个窗口）：'
            '等它把这一步做完；确认它已停手后可 '
            'xbume_lease{"op":"steal","sessionId":"$sessionId"} 接管。'
            '只读排查（screenshot / find_widget / timeline / debug_state）随时可继续；'
            '同一个 AI 长期开多个会话时，让每个会话连各自的实例（--name）更省心。'
        : '只读排查可以继续：screenshot / find_widget / widget_tree / timeline / '
            'debug_state 都不需要租约；要接管先确认对方已停手，'
            '再 xbume_lease{"op":"steal","sessionId":"$sessionId"}；'
            '两个 AI 长期并行建议各自用独立 MCP 实例（xbume_clients 可看实例与占用）。',
  );
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

List<McpTool> coreTools({bool allowEval = false}) => <McpTool>[
      _sessionsTool(),
      _useSessionTool(),
      _sessionCheckTool(),
      _clientsTool(),
      _leaseTool(),
      _screenshotTool(),
      _findWidgetTool(),
      _tapTool(),
      _inputTool(),
      _swipeTool(),
      _navigateTool(),
      _routeStackTool(),
      _networkTool(),
      _networkDetailTool(),
      _consoleTool(),
      _exceptionsTool(),
      _timelineTool(),
      _hotReloadTool(),
      if (allowEval) _evalTool(),
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
          '返回会话 id、端口、app 名与当前选中项。带 launcher 标记的会话由 '
          'xb_ume/GUI 拉起，可直接复用（无需 app_launch 重跑）。'
          '任何其他工具报「未选择会话」时先调它。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'refresh':
            prop('boolean', '强制重新扫描（默认 3 秒内复用上次结果）', defaultValue: false),
      }),
      handler: (ctx, args) async {
        final force = optionalBool(args, 'refresh');
        final list = await ctx.sessions.refresh(force: force);
        final cur = ctx.sessions.currentId;
        // 租约（跨 MCP 实例可见）：标出每个会话当前由谁驱动。
        final leases = <String, Lease>{
          for (final l in ctx.leases.list()) l.key: l,
        };
        final now = DateTime.now();
        // 标注哪些会话是本服务/GUI 拉起的（可跨进程热重载），便于 AI 直接复用。
        // 判定与 hot_reload 同源（[reloadChannelOf]），不再只看“有没有 FIFO”：
        // FIFO 存在但 stdin 不是终端时，按键会被 flutter run 静默丢弃。
        final managed = <int, String>{};
        for (final h in ctx.launcher.live) {
          final port = Uri.tryParse(h.wsUri ?? '')?.port;
          if (port == null) continue;
          final channel = h.reloadChannel;
          managed[port] = '${h.owner}${h.adopted ? '认领' : '拉起'}'
              '${channel == ReloadChannel.none ? '·只读' : '·可热重载(${reloadChannelName(channel)})'}';
        }
        final items = list.map((s) {
          final json = s.toJson(current: s.id == cur);
          final tag = managed[s.port];
          if (tag != null) json['launcher'] = tag;
          final h = ctx.launcher.byPort(s.port);
          if (h != null) {
            json['reloadChannel'] =
                reloadChannelName(h.reloadChannel);
            json['flutterRunPid'] = h.pid;
          }
          final ls = leases[LeaseStore.sessionKey(s.id)];
          if (ls != null) {
            json['lease'] =
                ls.toJson(now: now, mine: ctx.leases.instance);
          }
          return json;
        }).toList(growable: false);
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
            final tag = (s['launcher'] ?? '').toString();
            final ls = leases[LeaseStore.sessionKey('${s['id']}')];
            final occupy = ls == null
                ? ''
                : ls.owner == ctx.leases.me
                    ? ' · 你持有'
                    : ' · 由 ${ls.owner.instance} 驱动（只读）';
            sb.write('${s['current'] == true ? '▶ ' : '  '}${s['id']}'
                '${app.isEmpty ? '' : ' · $app'}'
                ' · ${s['source']}${s['connected'] == true ? ' · 已连接' : ''}'
                '${tag.isEmpty ? '' : ' · $tag'}$occupy\n');
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
      description: '设定当前会话，并做一次连通性验证（读取路由栈）。'
          'mode=drive（默认）会尝试拿写租约：拿不到就降级只读旁观并说明谁在驱动；'
          'mode=observe 只读旁观、不占租约。换会话时自动释放本实例在旧会话上的租约。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': prop('string', '会话 id（xbume_sessions 返回的 id，如 s65296）'),
        'mode': prop('string', 'drive = 独占驱动（默认）；observe = 只读旁观（不占租约）',
            enumValues: <String>['drive', 'observe'], defaultValue: 'drive'),
        'note': prop('string', '租约备注（写进 xbume_clients，方便对方看懂你在干什么）'),
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
        // 换会话：先把本实例在旧会话上的租约放掉（避免幽灵占用）。
        await ctx.leases.releaseOthers(keep: sessionLeaseKey(s));
        final mode = (optionalString(args, 'mode') ?? 'drive').toLowerCase();
        final note = optionalString(args, 'note') ?? '';
        Lease? held;
        Lease? blocked;
        if (mode != 'observe') {
          final a = await ctx.leases.acquire(
            sessionLeaseKey(s),
            note: note.isEmpty ? 'use_session' : note,
          );
          held = a.lease;
          blocked = a.holder;
        }
        final route = await _topRoute(s.client);
        final app =
            (s.appName.isEmpty || s.appName == 'vm') ? '' : ' ${s.appName}';
        // 顺手附一行自检（不发重载）：选完就知道能看 / 能点 / 能不能重载。
        String tail;
        try {
          final c = await runSessionCheck(s, ctx.launcher, verifyReload: false);
          tail = '；自检 ${sessionVerdictName(c.verdict)}'
              '（重载通道 ${c.caps['reloadChannel']}）'
              '${c.judgement.usable ? '' : '；先看 xbume_session_check 的结论'}'
              '。完整能力用 xbume_session_check（默认会真发一次重载实测）';
        } catch (e) {
          tail = '；自检未完成：$e';
        }
        final leaseText = mode == 'observe'
            ? '；只读旁观（未占租约，写操作会被拒）'
            : held != null
                ? '；已独占（${leaseLeft(held)}后自动释放，验证完请 '
                    'xbume_lease{"op":"release"} 让出来）'
                : '；只读旁观：${blocked!.owner.instance} 正在驱动'
                    '（要接管用 xbume_lease{"op":"steal"}）';
        final leaseJson = (held ?? blocked)
            ?.toJson(now: DateTime.now(), mine: ctx.leases.instance);
        return McpToolResult.text(
          '已切换到 ${s.id}$app（端口 ${s.port}）'
          '${route == null ? '，路由栈读取失败（可能不是 Flutter 界面）' : '，当前路由 $route'}$tail$leaseText',
          structured: <String, Object?>{
            'sessionId': s.id,
            'wsUrl': s.wsUrl,
            'app': s.appName,
            'source': s.source,
            'route': route,
            'mode': mode == 'observe' ? 'observe' : 'drive',
            if (leaseJson != null) 'lease': leaseJson,
          },
        );
      },
    );

McpTool _sessionCheckTool() => McpTool(
      name: 'xbume_session_check',
      title: '会话可用性自检（能看 / 能点 / 能重载）',
      description: '接上会话后先调它：一次探清 VM 是否可连、是不是你要的设备/项目、'
          '截图与点按所需的 inspector / 求值是否可用、以及热重载走哪条通道。'
          '默认会真发一次热重载实测：没有文件改动时 flutter run 只回 '
          'No changes detected（不改 app 状态），已有改动则会真的重载。'
          '结论 verdict：ready / ready_no_reload / degraded / wrong_device / '
          'wrong_project / stale；warnings 与 next 直接告诉下一步该做什么。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'deviceId': prop('string',
            '期望设备号；不一致直接判 wrong_device（防止热重载打到另一台手机）'),
        'cwd': prop('string', '期望项目根；与 flutter run 的启动目录不一致判 wrong_project'),
        'verifyReload': prop('boolean',
            '真发一次热重载验证通道（默认 true；无改动时无副作用）',
            defaultValue: true),
        'timeoutMs': prop('integer', '实测等待完成标记的超时（毫秒，默认 20000）',
            defaultValue: 20000),
      }),
      handler: (ctx, args) async {
        final s = await resolveSession(ctx, args);
        final c = await runSessionCheck(
          s,
          ctx.launcher,
          expectDevice: optionalString(args, 'deviceId'),
          expectCwd: optionalString(args, 'cwd'),
          verifyReload: optionalBool(args, 'verifyReload', fallback: true),
          verifyTimeout: Duration(
              milliseconds: (optionalInt(args, 'timeoutMs') ?? 20000)
                  .clamp(5000, 180000)),
        );
        // 自检只读，但要把「谁在驱动」一并告知：否则 AI 会以为自己的写操作生效了。
        final held = ctx.leases.peek(sessionLeaseKey(s));
        final note = held == null
            ? ''
            : '\n占用：${held.owner == ctx.leases.me ? '你（可写）' : '${ownerLabel(held.owner)}（只读旁观；写操作会被拒）'}'
                '，${held.note.isEmpty ? '写操作' : held.note}，还有 ${leaseLeft(held)}';
        return McpToolResult.text(c.describe() + note, structured: {
          ...c.toJson(),
          if (held != null)
            'lease': held.toJson(now: DateTime.now(), mine: ctx.leases.instance),
        });
      },
    );

McpTool _clientsTool() => McpTool(
      name: 'xbume_clients',
      title: '本机 MCP 实例与会话占用',
      description: '一 AI 一个 MCP 进程时的总览：本机有哪些实例（名字 / 端口 / pid / 是否带 '
          'eval）、哪些会话正被谁驱动（租约跨实例可见）、本实例当前会话。'
          '多个 AI 并行干活前先看它，避免抢同一个 app。',
      group: ToolGroup.core,
      inputSchema: _schema(const <String, Object?>{}),
      handler: (ctx, args) async {
        final inst = listInstances();
        final leases = ctx.leases.list();
        // 取时间要在读完租约之后：提前取会让刚拿到的 10 分钟租约显示成「11 分钟」。
        final now = DateTime.now();
        final me = ctx.leases.instance;
        final sb = StringBuffer()
          ..writeln('本实例 $me（pid $pid'
              '${ctx.instancePort > 0 ? '，端口 ${ctx.instancePort}' : '，stdio'}）')
          ..writeln('会话：${ctx.sessions.currentId ?? '未选'}');
        // 同一个进程里可能有好几个 AI 会话（各自一个客户端连接），当前会话各记各的。
        final byClient = ctx.sessions.currentByClient;
        if (byClient.length > 1) {
          sb.writeln('客户端连接 ${byClient.length} 个（各记各的当前会话）：');
          for (final e in byClient.entries) {
            final k = e.key;
            final short = k.isEmpty
                ? '（未标识）'
                : (k.length <= 6 ? k : '…${k.substring(k.length - 6)}');
            sb.writeln('  · $short → ${e.value}');
          }
        }
        sb.writeln('MCP 实例 ${inst.length} 个：');
        if (inst.isEmpty) {
          sb.writeln('  （无登记；旧版本实例不写登记，用 xbume_sessions 看会话）');
        }
        for (final i in inst) {
          final name = '${i['name']}';
          final port = '${i['port'] ?? 0}';
          sb.writeln('  · $name${port == '0' ? ' · stdio' : ' :$port'}'
              ' · pid ${i['pid']} · ${i['transport'] ?? '?'}'
              '${i['hasEval'] == true ? ' · eval' : ''}'
              '${i['toolCount'] == null ? '' : ' · ${i['toolCount']} 工具'}'
              '${name == me ? ' ← 你' : ''}');
        }
        sb.writeln('租约 ${leases.length} 份：');
        if (leases.isEmpty) {
          sb.writeln('  （暂无：没有 AI 在驱动会话）');
        }
        for (final l in leases) {
          final mine = l.owner == ctx.leases.me;
          sb.writeln('  · ${l.key} ← ${mine ? '你' : ownerLabel(l.owner)}'
              ' · ${l.note.isEmpty ? '写操作' : l.note}'
              ' · ${leaseAgo(l.renewedAt, now: now)}续期'
              ' · 还有 ${leaseLeft(l, now: now)}');
        }
        return McpToolResult.text(sb.toString().trimRight(),
            structured: <String, Object?>{
              'instance': me,
              'pid': pid,
              'port': ctx.instancePort,
              'currentSession': ctx.sessions.currentId,
              'instances': inst,
              'leases': leases
                  .map((l) => l.toJson(now: now, mine: me))
                  .toList(growable: false),
            });
      },
    );

McpTool _leaseTool() => McpTool(
      name: 'xbume_lease',
      title: '会话租约：查看 / 申请 / 释放 / 接管',
      description: '写操作（tap / input / swipe / navigate / eval / hot_reload / force 重启 / '
          '场景回放 / 断点写）需要会话租约：空闲就自动拿到，被别人驱动则报 busy。'
          'op=status 看谁在驱动；acquire 申请（可 waitMs 等对方释放）；'
          'release 用完立即让出来；steal 强制接管（只在确认对方已停手时用）。'
          '默认 10 分钟自动过期，每次写操作续期。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'op': prop('string', '操作',
            enumValues: <String>['status', 'acquire', 'release', 'steal']),
        'sessionId': _sessionIdProp(),
        'ttlMs': prop('integer', '租约有效期（毫秒，默认 600000 = 10 分钟，每次写操作续期）'),
        'waitMs': prop('integer', 'acquire 时最多等多久（毫秒，默认 0；上限 30000）'),
        'note': prop('string', '备注：你接下来要做什么（对方在 xbume_clients 里能看到）'),
      }, <String>['op']),
      handler: (ctx, args) async {
        final op = requireString(args, 'op', hint: 'status / acquire / release / steal').toLowerCase();
        final me = ctx.leases.instance;
        final now = DateTime.now();
        final sid = optionalString(args, 'sessionId') ?? ctx.sessions.currentId;
        if (sid == null || sid.isEmpty || sid == 'null') {
          if (op != 'status') {
            throw McpToolException('需要 sessionId（或先用 xbume_use_session 选定）',
                hint: '先 xbume_sessions 看有哪些会话');
          }
          final leases = ctx.leases.list();
          final sb = StringBuffer()..writeln('本实例 $me，租约 ${leases.length} 份：');
          if (leases.isEmpty) sb.writeln('  （暂无）');
          for (final l in leases) {
            sb.writeln('  · ${l.key} ← '
                '${l.owner == ctx.leases.me ? '你' : l.owner.instance}'
                ' · ${l.note.isEmpty ? '写操作' : l.note}'
                ' · 还有 ${leaseLeft(l, now: now)}');
          }
          return McpToolResult.text(sb.toString().trimRight(), structured: <String, Object?>{
            'instance': me,
            'leases': leases
                .map((l) => l.toJson(now: now, mine: me))
                .toList(growable: false),
          });
        }
        final key = LeaseStore.sessionKey(sid);
        switch (op) {
          case 'status':
            final l = ctx.leases.peek(key);
            if (l == null) {
              return McpToolResult.text('会话 $sid 空闲（没有租约，可以直接写）',
                  structured: <String, Object?>{'sessionId': sid, 'idle': true});
            }
            final mine = l.owner == ctx.leases.me;
            return McpToolResult.text(
              '会话 $sid 由 ${mine ? '你' : l.owner.instance} 持有'
              '（${l.note.isEmpty ? '写操作' : l.note}，${leaseAgo(l.renewedAt, now: now)}续期，'
              '还有 ${leaseLeft(l, now: now)}）',
              structured: <String, Object?>{
                'sessionId': sid,
                'idle': false,
                'lease': l.toJson(now: now, mine: me),
              },
            );
          case 'acquire':
          case 'steal':
            final ttl = Duration(
                milliseconds:
                    (optionalInt(args, 'ttlMs') ?? kDefaultLeaseTtl.inMilliseconds)
                        .clamp(60000, 3600000));
            final wait = Duration(
                milliseconds: (optionalInt(args, 'waitMs') ?? 0).clamp(0, 30000));
            final prev = ctx.leases.peek(key);
            final a = await ctx.leases.acquire(
              key,
              note: optionalString(args, 'note') ?? 'xbume_lease',
              ttl: ttl,
              steal: op == 'steal',
              wait: wait,
            );
            final l = a.lease;
            if (l == null) throw busyLeaseError(ctx, sid, a.holder!);
            final tookOver = op == 'steal' && prev != null && prev.owner != ctx.leases.me;
            return McpToolResult.text(
              '已持有会话 $sid 的租约（${leaseLeft(l)}后自动释放）'
              '${tookOver ? '；已从 ${prev.owner.instance} 接管' : ''}。'
              '写完 / 验证完请 xbume_lease{"op":"release"} 让出来。',
              structured: <String, Object?>{
                'sessionId': sid,
                'lease': l.toJson(now: now, mine: me),
                if (tookOver)
                  'stolenFrom': prev.owner.toJson(),
              },
            );
          case 'release':
            final l = ctx.leases.peek(key);
            if (l == null) {
              return McpToolResult.text('会话 $sid 本来就没有租约',
                  structured: <String, Object?>{'sessionId': sid, 'released': false});
            }
            final ok = await ctx.leases.release(key);
            if (!ok) throw busyLeaseError(ctx, sid, l);
            return McpToolResult.text('已释放会话 $sid 的租约',
                structured: <String, Object?>{'sessionId': sid, 'released': true});
          default:
            throw McpToolException('未知 op：$op',
                hint: '可用：status / acquire / release / steal');
        }
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
        final s = await resolveSession(ctx, args);
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
        final s = await resolveSession(ctx, args);
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
        final s = await resolveDriveSession(ctx, args, 'tap');
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
        final s = await resolveDriveSession(ctx, args, 'input');
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
        final s = await resolveDriveSession(ctx, args, 'swipe');
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
        final s = await resolveDriveSession(ctx, args, 'navigate');
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
        final s = await resolveSession(ctx, args);
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
        final s = await resolveSession(ctx, args);
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

/// 文本展示用的截断（结构化回包仍保留完整内容）。
String _short(String s, [int max = 400]) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

McpTool _networkDetailTool() => McpTool(
      name: 'xbume_network_detail',
      title: '查看网络请求详情',
      description: '按 id 或 URL 片段取完整请求/响应头、body 与发起点调用栈——'
          '回答「这个 500 到底返回了什么」。URL 优先用 xbume_network 返回的 id 精确定位；'
          'app 记录时已对 Authorization/Cookie 等敏感键做 `***` 脱敏。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'id': prop('string', '记录 id（xbume_network 返回的 id，精确匹配，优先于 urlContains）'),
        'urlContains': prop('string', 'URL 包含的子串（省略 id 时必填，取最新的匹配）'),
        'method': prop('string', 'HTTP 方法，进一步缩小范围（GET/POST…）'),
        'maxChars': prop('integer', '单个 body / 发起点栈最多返回多少字符（默认 2000）',
            defaultValue: 2000),
        'limit': prop('integer', '最多返回几条匹配记录（默认 1）', defaultValue: 1),
      }),
      handler: (ctx, args) async {
        final s = await resolveSession(ctx, args);
        final id = optionalString(args, 'id');
        final url = optionalString(args, 'urlContains');
        if ((id == null || id.isEmpty) && (url == null || url.isEmpty)) {
          throw McpToolException('需要 id 或 urlContains',
              hint: '先调 xbume_network 找到目标请求');
        }
        final maxChars =
            (optionalInt(args, 'maxChars') ?? 2000).clamp(200, 20000);
        final limit = (optionalInt(args, 'limit') ?? 1).clamp(1, 5);
        final raw = await s.client.evalStringOn(
          kLibXbUme,
          networkDetailExpr(
            id: id,
            urlContains: url,
            method: optionalString(args, 'method'),
            maxChars: maxChars,
            limit: limit,
          ),
        );
        if (raw == 'NOT_FOUND') {
          throw McpToolException('没有匹配的网络记录（id=$id urlContains=$url）',
              hint: '用 xbume_network 确认 URL/方法；app 需接入 Network 模块');
        }
        final items = <Map<String, Object?>>[];
        for (final row in raw.split('\u0003')) {
          if (row.isEmpty) continue;
          final f = row.split('\u0001');
          if (f.length < 17) continue;
          items.add(<String, Object?>{
            'id': f[0],
            'time': f[1],
            'method': f[2],
            'url': f[3],
            'statusCode': int.tryParse(f[4]),
            'status': f[5],
            'durationMs': int.tryParse(f[6]),
            'error': f[7],
            'requestHeaders': f[8],
            'requestBody': f[9],
            'responseHeaders': f[10],
            'responseBody': f[11],
            'initiator': f[12],
            'initiatorStack': f[13],
            'requestBodyChars': int.tryParse(f[14]),
            'responseBodyChars': int.tryParse(f[15]),
            'truncated': f[16] == '1',
          });
        }
        final sb = StringBuffer();
        for (final e in items) {
          sb.write('${e['method']} ${e['statusCode'] ?? '-'} '
              '${e['durationMs'] ?? '-'}ms ${e['url']}\n');
          sb.write('  时间: ${e['time']}\n');
          if ((e['initiator'] as String).isNotEmpty) {
            sb.write('  发起: ${e['initiator']}\n');
          }
          if ((e['initiatorStack'] as String).isNotEmpty) {
            final lines = (e['initiatorStack'] as String).split('\n');
            sb.write('  发起栈: ${_short(lines.first, 200)}\n');
          }
          if ((e['requestHeaders'] as String).isNotEmpty) {
            sb.write('  请求头: ${_short(e['requestHeaders'] as String)}\n');
          }
          if ((e['requestBody'] as String).isNotEmpty) {
            sb.write('  请求体: ${_short(e['requestBody'] as String)}\n');
          }
          if ((e['responseHeaders'] as String).isNotEmpty) {
            sb.write('  响应头: ${_short(e['responseHeaders'] as String)}\n');
          }
          if ((e['responseBody'] as String).isNotEmpty) {
            sb.write('  响应体: ${_short(e['responseBody'] as String)}\n');
          }
          if ((e['error'] as String).isNotEmpty) {
            sb.write('  错误: ${e['error']}\n');
          }
        }
        return McpToolResult.text(sb.toString().trimRight(),
            structured: <String, Object?>{
              'count': items.length,
              'items': items,
            });
      },
    );

McpTool _consoleTool() => McpTool(
      name: 'xbume_console',
      title: '读取 app 日志',
      description:
          '读取 app 内 XBUme 日志（debug/info/warn/error/fatal），支持级别、关键字、时间窗过滤。'
          '默认取最新 limit 条（tail=true）；做验收/回归时把上一轮返回的 nextSinceMs '
          '传给 sinceMs，就只拿新增日志（游标式增量，不会重复也不漏）。'
          '返回的 logFilePath 是 app 端落盘的同内容日志文件（enableLogFile），'
          'AI 可用 xbume_sandbox(action: "read", path: logFilePath, offset, max) 按字节分页读完，'
          '不受内存 2000 条限制，也不怕 app 重启。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'level': prop('string', '最低级别',
            enumValues: <String>['debug', 'info', 'warn', 'error', 'fatal']),
        'keyword': prop('string', '消息或 tag 包含的关键字'),
        'sinceMs': prop('integer', '只看该时间戳（毫秒）之后的记录'),
        'limit': prop('integer', '最多返回条数（默认 50）', defaultValue: 50),
        'offset': prop('integer', 'tail=false 时从第几条开始取（默认 0）',
            defaultValue: 0),
        'tail': prop('boolean', '取最新 limit 条（默认 true）；false 则从 offset 往后取',
            defaultValue: true),
        'maxChars': prop('integer', '单条消息最多多少字符（默认 500）',
            defaultValue: 500),
      }),
      handler: (ctx, args) async {
        final s = await resolveSession(ctx, args);
        final limit = (optionalInt(args, 'limit') ?? 50).clamp(1, 500);
        final raw = await s.client.evalStringOn(
          kLibXbUme,
          consoleExpr(
            level: optionalString(args, 'level'),
            keyword: optionalString(args, 'keyword'),
            sinceMs: optionalInt(args, 'sinceMs'),
            limit: limit,
            offset: (optionalInt(args, 'offset') ?? 0).clamp(0, 100000),
            tail: optionalBool(args, 'tail', fallback: true),
            maxChars: (optionalInt(args, 'maxChars') ?? 500).clamp(50, 4000),
            withPath: true,
          ),
        );
        final items = <Map<String, Object?>>[];
        String? logFilePath;
        for (final row in raw.split('\u0003')) {
          if (row.isEmpty) continue;
          if (row.startsWith('#path\u0001')) {
            final p = row.substring(6).trim();
            if (p.isNotEmpty) logFilePath = p;
            continue;
          }
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
        // 游标：最后一条的时间 +1ms，下次作为 sinceMs 传回来就只拿新增。
        var nextSinceMs = optionalInt(args, 'sinceMs') ?? 0;
        for (final e in items) {
          final t = DateTime.tryParse('${e['time']}');
          if (t == null) continue;
          final ms = t.millisecondsSinceEpoch + 1;
          if (ms > nextSinceMs) nextSinceMs = ms;
        }
        return McpToolResult.text(sb.toString().trimRight(),
            structured: <String, Object?>{
              'count': items.length,
              'items': items,
              'nextSinceMs': nextSinceMs,
              if (logFilePath != null) 'logFilePath': logFilePath,
            });
      },
    );

McpTool _exceptionsTool() => McpTool(
      name: 'xbume_exceptions',
      title: '读取结构化异常',
      description: '读取 app 内 FlutterError / PlatformError 的结构化缓冲：类型、摘要、库、'
          '上下文、栈与重复次数。比 xbume_console(level:"error") 多出类型/库/首帧/合并计数，'
          '适合回答「这个报错是什么、在哪抛的、发生几次」。渲染 / build 类错误（如布局溢出）'
          '还会给出出错的 widget、业务源码 file:line:column 与前后两行片段，可直接定位到代码。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'kind': prop('string', '异常来源',
            enumValues: <String>['flutter', 'platform', 'app', 'all']),
        'typeContains': prop('string', '异常类型包含（如 TypeError / Exception）'),
        'keyword': prop('string', '摘要/上下文/栈包含的关键字'),
        'sinceMs': prop('integer', '只看该时间戳（毫秒）之后的记录'),
        'limit': prop('integer', '最多返回条数（默认 20，取最新）', defaultValue: 20),
      }),
      handler: (ctx, args) async {
        final s = await resolveSession(ctx, args);
        final limit = (optionalInt(args, 'limit') ?? 20).clamp(1, 100);
        String raw;
        try {
          raw = await s.client.evalStringOn(
            kLibXbUme,
            exceptionsExpr(
              kind: optionalString(args, 'kind'),
              typeContains: optionalString(args, 'typeContains'),
              keyword: optionalString(args, 'keyword'),
              sinceMs: optionalInt(args, 'sinceMs'),
              limit: limit,
            ),
          );
        } catch (e) {
          final m = e.toString();
          if (m.contains('exceptions') || m.contains('NoSuchMethod')) {
            throw McpToolException('当前 app 的 xb_ume 还没有异常缓冲（版本较旧）',
                hint: '升级 xb_ume 到带 XBUmeExceptionItem 的版本后重启 app（热重载可能不生效）');
          }
          throw McpToolException('读取异常失败：$m');
        }
        final items = <Map<String, Object?>>[];
        for (final row in raw.split('\u0003')) {
          if (row.isEmpty) continue;
          final f = row.split('\u0001');
          if (f.length < 9) continue;
          // 后四段（widget 定位）是新增字段，旧 app 只回 9 段。
          final widget = f.length > 9 ? f[9].trim() : '';
          final file = f.length > 10 ? f[10].trim() : '';
          final line = f.length > 11 ? int.tryParse(f[11].trim()) : null;
          final column = f.length > 12 ? int.tryParse(f[12].trim()) : null;
          final snippet = _readSourceSnippet(file, line);
          items.add(<String, Object?>{
            'time': f[0],
            'timestampMs': int.tryParse(f[1]),
            'kind': f[2],
            'type': f[3],
            'count': int.tryParse(f[4]),
            'message': f[5],
            'library': f[6],
            'context': f[7],
            'stack': f[8],
            if (widget.isNotEmpty) 'widget': widget,
            if (file.isNotEmpty)
              'source': <String, Object?>{
                'file': file,
                if (line != null) 'line': line,
                if (column != null) 'column': column,
                if (snippet != null) 'snippet': snippet,
              },
          });
        }
        final sb = StringBuffer();
        if (items.isEmpty) {
          sb.write('没有匹配的异常记录。');
        } else {
          for (final e in items) {
            final times = (e['count'] as int?) ?? 1;
            sb.write('[${e['time']}] ${e['kind']} ${e['type']}'
                '${times > 1 ? ' ×$times' : ''}: ${e['message']}\n');
            if ((e['context'] as String).isNotEmpty) {
              sb.write('  上下文: ${_short(e['context'] as String, 200)}\n');
            }
            if ((e['library'] as String).isNotEmpty) {
              sb.write('  库: ${e['library']}\n');
            }
            final src = e['source'] as Map<String, Object?>?;
            if (src != null) {
              final at = src['line'] == null
                  ? ''
                  : ':${src['line']}${src['column'] == null ? '' : ':${src['column']}'}';
              sb.write('  位置: ${e['widget'] ?? '?'} @ ${src['file']}$at\n');
              final snippet = src['snippet'] as String?;
              if (snippet != null && snippet.isNotEmpty) {
                sb.write('$snippet\n');
              }
            }
            if ((e['stack'] as String).isNotEmpty) {
              final frame = (e['stack'] as String).split('\n').first;
              sb.write('  首帧: ${_short(frame, 200)}\n');
            }
          }
        }
        return McpToolResult.text(sb.toString().trimRight(),
            structured: <String, Object?>{
              'count': items.length,
              'items': items,
            });
      },
    );

/// 读异常定位行的上下文（±2 行），让 AI 不用再单独读文件。
///
/// 路径来自 app 进程，是宿主机的绝对路径：真机调试时这台机器上通常没有源码
/// （返回 null），桌面 / 模拟器下才有。超过 512KB 的文件直接跳过，避免一次
/// 异常读取把 MCP 响应拖慢。
String? _readSourceSnippet(String file, int? line) {
  if (file.isEmpty || line == null || line <= 0) return null;
  try {
    final f = File(file);
    if (!f.existsSync() || f.lengthSync() > 512 * 1024) return null;
    final lines = f.readAsLinesSync();
    if (line > lines.length) return null;
    final from = line - 2 < 1 ? 1 : line - 2;
    final to = line + 2 > lines.length ? lines.length : line + 2;
    final sb = StringBuffer();
    for (var i = from; i <= to; i++) {
      sb.writeln('${i == line ? '>' : ' '} $i | ${lines[i - 1]}');
    }
    return sb.toString().trimRight();
  } catch (_) {
    return null;
  }
}

/// 时间轴的文本时间戳：ISO 串截到毫秒（不依赖本地时区转换）。
String _timeShort(Object? iso) {
  final s = (iso ?? '').toString();
  return s.length >= 23 ? s.substring(11, 23) : s;
}

McpTool _timelineTool() => McpTool(
      name: 'xbume_timeline',
      title: '按时间合并诊断事件',
      description: '把路由、网络、日志、异常四类事件按时间合并成一条流（app 侧缓冲各取最近若干条），'
          '用来回答「用户点了一下之后紧接着发生了什么」。可先用 xbume_timeline 定位异常时间点，'
          '再用 xbume_exceptions / xbume_network_detail 看细节。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'kinds': arrayProp('事件类型过滤（route/net/log/exception，省略=全部）', 'string'),
        'keyword': prop('string', '关键字（匹配 URL、路由名、日志文本、异常摘要）'),
        'sinceMs': prop('integer', '只看该时间戳（毫秒）之后的记录'),
        'limit': prop('integer', '最多返回条数（默认 60）', defaultValue: 60),
      }),
      handler: (ctx, args) async {
        final s = await resolveSession(ctx, args);
        final limit = (optionalInt(args, 'limit') ?? 60).clamp(1, 300);
        const allowed = <String>{'route', 'net', 'log', 'exception'};
        final kinds = <String>{};
        final rawKinds = args['kinds'];
        if (rawKinds is List) {
          for (final k in rawKinds) {
            final v = k.toString().trim().toLowerCase();
            if (v.isEmpty || v == 'all') continue;
            if (!allowed.contains(v)) {
              throw McpToolException('kinds 只支持 route/net/log/exception 或 all');
            }
            kinds.add(v);
          }
        }
        final raw = await s.client.evalStringOn(
          kLibXbUme,
          timelineExpr(sinceMs: optionalInt(args, 'sinceMs'), limit: limit),
        );
        final events = <Map<String, Object?>>[];
        for (final row in raw.split('\u0003')) {
          if (row.isEmpty) continue;
          final f = row.split('\u0001');
          if (f.length < 6) continue;
          final ts = int.tryParse(f[1]) ?? 0;
          final t = f[0];
          if (kinds.isNotEmpty && !kinds.contains(t)) continue;
          final Map<String, Object?> item;
          switch (t) {
            case 'route' when f.length >= 7:
              item = <String, Object?>{
                't': t,
                'ts': ts,
                'time': f[2],
                'action': f[3],
                'name': f[4],
                'prev': f[5],
                'phase': f[6],
              };
            case 'net' when f.length >= 9:
              item = <String, Object?>{
                't': t,
                'ts': ts,
                'time': f[2],
                'method': f[3],
                'statusCode': int.tryParse(f[4]),
                'durationMs': int.tryParse(f[5]),
                'status': f[6],
                'url': f[7],
                'error': f[8],
              };
            case 'log' when f.length >= 6:
              item = <String, Object?>{
                't': t,
                'ts': ts,
                'time': f[2],
                'level': f[3],
                'tag': f[4],
                'message': f[5],
              };
            case 'exception' when f.length >= 7:
              item = <String, Object?>{
                't': t,
                'ts': ts,
                'time': f[2],
                'kind': f[3],
                'type': f[4],
                'count': int.tryParse(f[5]),
                'message': f[6],
              };
            default:
              continue;
          }
          events.add(item);
        }
        final keyword = optionalString(args, 'keyword');
        var filtered = keyword == null || keyword.isEmpty
            ? events
            : events
                .where((e) => jsonEncode(e).contains(keyword))
                .toList(growable: false);
        filtered.sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
        final capped = filtered.length > limit
            ? filtered.sublist(filtered.length - limit)
            : filtered;
        final sb = StringBuffer();
        if (capped.isEmpty) {
          sb.write('没有匹配的事件。');
        } else {
          for (final e in capped) {
            final at = _timeShort(e['time']);
            switch (e['t']) {
              case 'route':
                final prev = e['prev'] as String;
                sb.write('$at route ${e['action']} ${e['name']}'
                    '${prev.isEmpty ? '' : ' ← $prev'}\n');
              case 'net':
                sb.write('$at net   ${e['statusCode'] ?? '-'} '
                    '${e['durationMs'] ?? '-'}ms ${e['method']} ${e['url']}'
                    '${(e['error'] as String).isEmpty ? '' : ' ⚠ ${e['error']}'}\n');
              case 'log':
                sb.write('$at log   ${e['level']} [${e['tag']}] ${e['message']}\n');
              case 'exception':
                final times = (e['count'] as int?) ?? 1;
                sb.write('$at exc   ${e['kind']} ${e['type']}'
                    '${times > 1 ? ' ×$times' : ''}: ${e['message']}\n');
            }
          }
        }
        return McpToolResult.text(sb.toString().trimRight(),
            structured: <String, Object?>{
              'count': capped.length,
              'items': capped,
            });
      },
    );

/// 解析 eval 的库上下文：完整 uri 直用；否则按 uri 子串匹配（业务库优先）。
Future<String> _resolveEvalLib(VmClient vm, String? wanted) async {
  final w = (wanted ?? '').trim();
  if (w.isNotEmpty) {
    if (w.startsWith('package:') || w.startsWith('dart:') || w.contains('://')) {
      return w;
    }
    final iso = await vm.rawRpc(
        'getIsolate', <String, Object?>{'isolateId': await vm.isolateId()});
    final uris = <String>[];
    for (final lib in (iso['libraries'] as List? ?? const <Object?>[])) {
      if (lib is Map && lib['uri'] != null) uris.add(lib['uri'].toString());
    }
    final hit = uris.where((u) => u.contains(w)).toList()
      ..sort((a, b) => _libRank(a).compareTo(_libRank(b)));
    if (hit.isEmpty) {
      throw McpToolException('没有匹配「$w」的库',
          hint: '可用库示例：${uris.take(10).join('、')}');
    }
    return hit.first;
  }
  // 默认：xb_ume core（业务工具都在这个上下文），不可用时退到 dart:io。
  for (final c in <String>[kLibXbUme, 'dart:io']) {
    try {
      await vm.libraryId(c);
      return c;
    } catch (_) {}
  }
  throw McpToolException('找不到可用的求值库上下文',
      hint: 'app 未加载 xb_ume 或 dart:io；用 lib 参数指定业务库（如 main.dart）');
}

/// 业务库 0 < dart: 1 < Flutter / pub-cache 2。
int _libRank(String uri) {
  if (uri.startsWith('dart:')) return 1;
  if (uri.startsWith('package:flutter/') || uri.contains('/.pub-cache/')) {
    return 2;
  }
  return 0;
}

/// VM 内部类名归一化（模型更容易认）。
String _displayClass(String name) {
  const map = <String, String>{
    '_Smi': 'int',
    '_Mint': 'int',
    '_BigIntImpl': 'BigInt',
    '_Double': 'double',
    '_OneByteString': 'String',
    '_TwoByteString': 'String',
    '_GrowableList': 'List',
    '_List': 'List',
    '_LinkedHashMap': 'Map',
    '_Map': 'Map',
    '_HashSet': 'Set',
  };
  return map[name] ?? name;
}

McpTool _evalTool() => McpTool(
      name: 'xbume_eval',
      title: '在 app 内求值一条表达式',
      description: '在 app 的指定库上下文执行一条 Dart 表达式，返回类型、类名与值。'
          '用于读私有字段/单例状态、调方法或改状态（如 XBUme.controller.clearExceptions()），'
          '补上「看事件」看不到的运行时状态。需要 MCP 服务以 --allow-eval 启动；'
          '只支持单条表达式，不能是语句块。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'expr': prop('string', 'Dart 表达式（单条；如 XBUme.controller.routes.length）'),
        'expression': prop('string', 'expr 的别名（两个名字任选其一）'),
        'lib': prop('string',
            '求值所用库：完整 uri 或子串（如 main.dart）；省略时用 xb_ume core，失败回退 dart:io'),
        'maxChars': prop('integer', '返回值的最大字符数（默认 4000）',
            defaultValue: 4000),
      }),
      handler: (ctx, args) async {
        if (!ctx.allowEval) {
          throw McpToolException('xbume_eval 未启用',
              hint: '启动 MCP 时加 --allow-eval（GUI 托管的服务需在启动参数里加）');
        }
        // expr / expression 两个名字都收：不同模型的习惯不一样，
        // 只因为参数名不同就失败太不值。
        final rawExpr =
            optionalString(args, 'expr') ?? optionalString(args, 'expression');
        final expr = rawExpr?.trim() ?? '';
        if (expr.isEmpty) {
          throw McpToolException('缺少参数 expr',
              hint: '例如 XBUme.controller.logs.length（也可用 expression）');
        }
        if (expr.length > 4000) {
          throw McpToolException('表达式过长（${expr.length} 字符，上限 4000）');
        }
        final s = await resolveDriveSession(ctx, args, 'eval');
        final vm = s.client;
        final wantedLib = optionalString(args, 'lib');
        var uri = await _resolveEvalLib(vm, wantedLib);
        final iso = await vm.isolateId();
        Future<Map<String, Object?>> ev(String libUri) async {
          final target = await vm.libraryId(libUri);
          return vm.rawRpc('evaluate', <String, Object?>{
            'isolateId': iso,
            'targetId': target,
            'expression': expr,
          });
        }
        Map<String, Object?> r;
        try {
          r = await ev(uri);
        } catch (e) {
          final m = e.toString();
          if (m.contains('ompilation')) {
            throw McpToolException('表达式无法编译：$m',
                hint: '确认是单条表达式且符号在 $uri 上下文可见；鸿蒙 Flutter 引擎不支持表达式求值');
          }
          throw McpToolException('求值失败：$m');
        }
        // 默认上下文编译不过（如用了 Directory / File 这类 dart:io 符号）
        // 时自动退到 dart:io 再试一次；显式指定 lib 的不猜。
        if ((wantedLib ?? '').trim().isEmpty &&
            (r['type'] == 'Error' || r['type'] == '@Error') &&
            (r['message'] ?? '').toString().startsWith('error:') &&
            uri != 'dart:io') {
          try {
            uri = 'dart:io';
            r = await ev(uri);
          } catch (_) {
            // 回退失败就保留原来的编译错误。
          }
        }
        final type = (r['type'] ?? '').toString();
        final rawClass = r['class'] is Map
            ? ((r['class'] as Map)['name'] ?? '').toString()
            : '';
        final cls = _displayClass(rawClass);
        if (type == 'Error' || type == '@Error') {
          final message =
              (r['message'] ?? r['valueAsString'] ?? '未知错误').toString();
          final compile = message.startsWith('error:');
          return McpToolResult.text(
              '${compile ? '表达式编译失败' : '求值抛出异常'}：$message',
              structured: <String, Object?>{
                'ok': false,
                'expression': expr,
                'library': uri,
                'kind': compile ? 'compile' : 'runtime',
                'error': message,
              });
        }
        final rawValue = (r['valueAsString'] ?? '').toString();
        final maxChars =
            (optionalInt(args, 'maxChars') ?? 4000).clamp(200, 20000);
        final cut = rawValue.length > maxChars;
        final shown = cut ? '${rawValue.substring(0, maxChars)}…' : rawValue;
        final total = r['length'] is int ? r['length'] as int : rawValue.length;
        final vmTruncated = r['valueAsStringIsTruncated'] == true;
        final kind = cls.isEmpty ? type : '$type($cls)';
        final sb = StringBuffer()
          ..write('`$expr` = ${shown.isEmpty ? '(空)' : shown}\n')
          ..write('库 $uri · $kind');
        if (vmTruncated || cut) sb.write(' · 已截断，完整长度 $total');
        if (vmTruncated) {
          sb.write('\n值被 VM 截断，建议缩小表达式（如 .length 或 .substring(0,500)）');
        }
        return McpToolResult.text(sb.toString(),
            structured: <String, Object?>{
              'ok': true,
              'expression': expr,
              'library': uri,
              'type': type,
              'className': cls,
              'value': shown,
              'truncated': vmTruncated || cut,
              'length': total,
            });
      },
    );

McpTool _hotReloadTool() => McpTool(
      name: 'xbume_hot_reload',
      title: '触发热重载 / 热重启',
      description: '向本服务/GUI 拉起的 flutter run 触发重载并等完成标记后返回；'
          'POSIX 上发 SIGUSR1（热重载）/ SIGUSR2（热重启）——这类会话的 stdin '
          '是管道，写 r 键会被 flutter run 静默丢弃，所以不再走按键。'
          '没有可用通道时立即报错，不会干等超时；编译错误原样带回。'
          '热重启后 isolate 会更换，工具会自动清掉 isolate 缓存。',
      group: ToolGroup.core,
      inputSchema: _schema(<String, Object?>{
        'sessionId': _sessionIdProp(),
        'pid': prop('integer', 'flutter run 进程号（多会话时指定；默认按会话端口反查）'),
        'mode': prop('string', 'reload（热重载，默认）或 restart（热重启）',
            enumValues: <String>['reload', 'restart']),
        'timeoutMs': prop('integer', '等待完成标记的超时（毫秒，默认 60000）',
            defaultValue: 60000),
      }),
      handler: (ctx, args) async {
        final restart =
            (optionalString(args, 'mode') ?? 'reload').toLowerCase() == 'restart';
        final timeout = Duration(
            milliseconds:
                (optionalInt(args, 'timeoutMs') ?? 60000).clamp(5000, 300000));
        var pid = optionalInt(args, 'pid');
        final s = await resolveDriveSession(ctx, args, 'hot_reload');
        if (pid == null) {
          pid = ctx.launcher.pidForPort(s.port);
          if (pid == null) {
            throw McpToolException('当前会话不是由本服务拉起的 flutter run，无法发送热重载',
                hint: '用 xbume_app_launch(via:"flutter-run") 启动会话，或传 pid=<flutter run 进程号>；'
                    '也可在 flutter run 窗口手动按 r');
          }
        } else {
          // 显式 pid 也要跟当前会话端口对上：热重载会直接打进 app，
          // 不能把 r 发到用户另一台设备的会话上。
          final h = ctx.launcher.byPid(pid);
          final p = h?.wsUri == null ? null : Uri.tryParse(h!.wsUri!)?.port;
          if (p != null && p != s.port) {
            throw McpToolException('pid $pid 属于端口 $p 的会话，当前会话是 ${s.port}',
                hint: '先 xbume_use_session 切到对应会话，避免热重载打到别的 app');
          }
        }
        final HotReloadResult r;
        try {
          r = await ctx.launcher.hotReload(pid, restart: restart, timeout: timeout);
        } on DeviceCommandError catch (e) {
          throw McpToolException(e.message, hint: '命令：${e.command}');
        }
        if (r.ok && restart) {
          // 热重启换了 isolate：不清缓存的话后续 eval / 路由会拿着旧 isolateId 报错。
          final ws = ctx.launcher.byPid(pid)?.wsUri;
          final port = ws == null ? null : Uri.tryParse(ws)?.port;
          if (port != null) {
            for (final s in ctx.sessions.all) {
              if (s.port == port) s.client.resetIsolateCache();
            }
          }
        }
        final modeName = restart ? '热重启' : '热重载';
        final channel = reloadChannelName(r.channel);
        final tail = r.lines.isEmpty
            ? ''
            : '\n最近输出：\n${r.lines.take(20).join('\n')}';
        final text = r.ok
            ? '$modeName完成（pid ${r.pid}，通道 $channel，${r.elapsedMs}ms）：${r.message}'
            : '$modeName未完成（pid ${r.pid}，通道 $channel，${r.elapsedMs}ms）：${r.message}$tail';
        return McpToolResult.text(text,
            structured: <String, Object?>{
              'ok': r.ok,
              'mode': restart ? 'restart' : 'reload',
              'pid': r.pid,
              'channel': channel,
              'elapsedMs': r.elapsedMs,
              'marker': r.message,
              'lines': r.lines,
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
        // 场景运行会注入手势、改 app 状态：必须持会话租约（跨实例互斥）。
        final target = await resolveDriveSession(ctx, args, 'scenario_run');
        try {
          final run = ctx.scenarios.start(
            name: name,
            steps: steps.isEmpty ? null : steps,
            sessionId: target.id,
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
