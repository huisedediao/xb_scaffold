// xb_ume MCP 服务入口（stdio / Streamable HTTP）。
//
// 用法：
//   dart run xb_ume:mcp                 # stdio，供 Qoder / Cursor / Claude Code 接入
//   dart run xb_ume:mcp --http 46140    # 本机 HTTP，供远程或多客户端复用
//
// 选项：
//   --stdio                  stdio 传输（默认）
//   --http <port>            Streamable HTTP 传输（默认 46140；仅绑 127.0.0.1）
//   --name <name>            实例名（多个 AI 各跑一个进程时用来区分谁在驱动）
//   --pool-entry             池入口：听一个端口，按连接把请求分给池里的实例
//   --pool-max <n>           池上限（默认 5，1..9）
//   --slot <n>               池槽号（由池入口拉起时传入，只用于登记）
//   --uri <port|ws-url>      手工指定会话（跳过自动发现，可重复）
//   --tool-groups <list>     all 或逗号分隔的组名：inspect,act,device-write,
//                            debug,data,env（ai/ide 预留）
//   --no-tool-groups         只暴露核心工具（关掉默认开启的 diagnose / run-safe）
//   --allow-eval             启用 xbume_eval（默认关；可读/改 app 内运行时状态）
//   --gui-port <port>        工具箱端口（默认自动探测 46129-46138；data/env 组用）
//   --device-backend <list>  设备后端：auto（默认）/ adb,hdc,simctl,idevice / mobile-mcp
//   -h, --help               帮助
//   --version                版本
//
// stdout 只用于 MCP 协议（stdio 模式）；所有日志与提示走 stderr。
library;

import 'dart:async';
import 'dart:io';

import 'src/device/proxy_env.dart';
import 'src/device/registry.dart';
import 'src/mcp/bridge_tools.dart';
import 'src/mcp/debug_tools.dart';
import 'src/mcp/device_tools.dart';
import 'src/mcp/instances.dart';
import 'src/mcp/pool.dart';
import 'src/mcp/router.dart';
import 'src/mcp/scenario_service.dart';
import 'src/mcp/server.dart';
import 'src/mcp/session_registry.dart';
import 'src/mcp/toolbox_tools.dart';
import 'src/mcp/tools.dart';

const String _usage = '''
xb_ume MCP 服务

用法：
  dart run xb_ume:mcp [--stdio | --http <port>] [选项]

选项：
  --stdio                  stdio 传输（默认），供 Qoder / Cursor / Claude Code 接入
  --http <port>            Streamable HTTP（默认 46140，仅绑 127.0.0.1，需 token）
  --name <name>            实例名（默认 http 按端口 mcp-<port>，stdio 按 pid）。
                           多个 AI 并行时各跑一个进程、各取一个名字，租约里就能看出
                           是谁在驱动会话
  --uri <port|ws-url>      手工指定 VM service 会话（跳过自动发现，可重复）
  --pool-entry             池入口：客户端只连这一个端口，按连接自动分配实例
                           （空闲复用 / 没满新建 / 5 个都满则回「需要排队」）
  --pool-max <n>           池上限（默认 5，1..9）
  --slot <n>               池槽号（池入口拉起时自动传入，人工不用填）
  --tool-groups <list>     all 或逗号分隔：inspect,act,device-write,debug,data,env
  --no-tool-groups         只暴露核心工具
  --allow-eval             启用 xbume_eval（默认关；可读/改 app 内运行时状态）
  --gui-port <port>        工具箱端口（默认自动探测 46129-46138）
  --device-backend <list>  设备后端：auto / adb,hdc,simctl,idevice / mobile-mcp
  --log-file <path>        额外把启动与运日志追加写入文件（GUI 后台拉起时排障用）
  -h, --help               显示帮助
  --version                显示版本

默认工具 29 个（core 22 + diagnose 4 + run-safe 3）；有副作用的组需显式开启。
加 --allow-eval 多出 xbume_eval，加 --tool-groups all 多出调试 / 数据 / 观测类工具。
多个 AI 共用一个 app 时，写操作要拿会话租约：被占会报 busy，只读旁路随时可用。
多窗口 / 多 AI 想各自独占一个实例：用 --pool-entry 起一个入口，客户端只连它，
入口按连接分配池里的实例（最多 5 个），绑满就回「需要排队」。
HTTP 模式 token 首次运行生成在 \$XB_UME_HOME/mcp.token。
''';

class _Args {
  bool http = false;
  int httpPort = 46140;
  String name = '';
  bool poolEntry = false;
  int? poolMax;
  int? slot;
  bool noToolGroups = false;
  String toolGroups = '';
  bool allowEval = false;
  String deviceBackend = 'auto';
  String logFile = '';
  int? guiPort;
  final List<String> uris = <String>[];
  bool help = false;
  bool version = false;
}

_Args _parseArgs(List<String> argv) {
  final a = _Args();
  for (var i = 0; i < argv.length; i++) {
    final s = argv[i];
    String next(String name) {
      if (i + 1 >= argv.length) throw FormatException('$name 缺少参数值');
      return argv[++i];
    }

    switch (s) {
      case '-h':
      case '--help':
        a.help = true;
        break;
      case '--version':
        a.version = true;
        break;
      case '--stdio':
        a.http = false;
        break;
      case '--http':
        a.http = true;
        final v = _httpPort(next('--http'));
        if (v == null) throw const FormatException('--http 需要 1-65535 的端口');
        a.httpPort = v;
        break;
      case '--name':
        a.name = next('--name');
        break;
      case '--pool-entry':
        a.poolEntry = true;
        break;
      case '--pool-max':
        a.poolMax = int.tryParse(next('--pool-max'));
        break;
      case '--slot':
        a.slot = int.tryParse(next('--slot'));
        break;
      case '--uri':
        a.uris.add(next('--uri'));
        break;
      case '--log-file':
        a.logFile = next('--log-file');
        break;
      case '--tool-groups':
        a.toolGroups = next('--tool-groups');
        break;
      case '--no-tool-groups':
        a.noToolGroups = true;
        break;
      case '--allow-eval':
        a.allowEval = true;
        break;
      case '--device-backend':
        a.deviceBackend = next('--device-backend');
        break;
      case '--gui-port':
        final v = _httpPort(next('--gui-port'));
        if (v == null) throw const FormatException('--gui-port 需要 1-65535 的端口');
        a.guiPort = v;
        break;
      default:
        if (s.startsWith('-')) throw FormatException('未知参数 $s');
        throw FormatException('多余的位置参数 $s');
    }
  }
  return a;
}

int? _httpPort(String raw) {
  final v = int.tryParse(raw);
  if (v == null || v <= 0 || v > 65535) return null;
  return v;
}

/// 包版本（从同目录 pubspec.yaml 读；全局 activate / AOT 取不到时为空）。
String _readVersion() {
  try {
    final f = File.fromUri(Platform.script.resolve('../pubspec.yaml'));
    if (f.existsSync()) {
      final m = RegExp(r'^version:\s*(\S+)', multiLine: true)
          .firstMatch(f.readAsStringSync());
      if (m != null) return m.group(1)!;
    }
  } catch (_) {}
  // 部署副本（~/.xb_ume_ide/mcp.dart）旁边没有 pubspec.yaml，读安装时写好的
  // version.txt（--install 生成）。
  try {
    final f = File.fromUri(Platform.script.resolve('version.txt'));
    if (f.existsSync()) {
      final v = f.readAsStringSync().trim();
      if (v.isNotEmpty) return v;
    }
  } catch (_) {}
  return '0.0.0';
}

/// 解析 --tool-groups，返回启用的组集合。
Set<String> _resolveGroups(_Args a) {
  if (a.noToolGroups) return <String>{ToolGroup.core};
  final groups = <String>{ToolGroup.core, ...ToolGroup.defaultExtra};
  final raw = a.toolGroups.trim();
  if (raw.isEmpty) return groups;
  final items = raw
      .split(',')
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();
  if (items.contains('all')) {
    return <String>{
      ToolGroup.core,
      ToolGroup.diagnose,
      ToolGroup.runSafe,
      ...ToolGroup.optIn,
    };
  }
  for (final g in items) {
    if (g == ToolGroup.core) continue;
    if (!ToolGroup.optIn.contains(g) && !ToolGroup.defaultExtra.contains(g)) {
      throw FormatException('未知工具组 $g（可用：${ToolGroup.optIn.join(',')}，或 all）');
    }
    groups.add(g);
  }
  return groups;
}

/// 日志额外落盘的文件（GUI 以 detached 子进程拉起时 stderr 看不到）。
File? _logSink;

void _log(String s) {
  stderr.writeln(s);
  final sink = _logSink;
  if (sink == null) return;
  try {
    sink.writeAsStringSync('${DateTime.now().toIso8601String()} $s\n',
        mode: FileMode.append, flush: true);
  } catch (_) {
    // 写不了文件不影响服务本身。
  }
}

/// 池入口：不干活（不碰 VM / 设备），只按连接把请求分给池里的实例。
///
/// 入口自己也要答 initialize / tools/list（GUI 健康检查、AI 开窗看工具），所以
/// 工具清单在入口进程里也建一份；真正的 tools/call 全部转发给后端。
Future<void> _runPoolEntry(
  _Args args,
  String version,
  List<McpTool> enabled,
  Set<String> groups,
) async {
  final entry = PoolEntry(
    port: args.httpPort,
    version: version,
    token: ensureToken(),
    tools: enabled,
    toolGroups: groups.join(','),
    allowEval: args.allowEval,
    guiPort: args.guiPort,
    deviceBackend: args.deviceBackend,
    log: _log,
    max: args.poolMax,
  );
  HttpServer hs;
  try {
    hs = await entry.serve();
  } on SocketException catch (e) {
    _log('端口 ${args.httpPort} 无法监听：${e.message}');
    _log('换一个端口：dart run xb_ume:mcp --http 46141 --pool-entry');
    exit(2);
  }
  final rec = entry.register();
  _log('xb_ume MCP 池入口 $version · http://127.0.0.1:${args.httpPort}/mcp'
      ' · 池 ${rec['poolMax']} 个槽'
      ' · 绑定 ${kPoolBindingTtl.inMinutes} 分钟不续期就回池');
  _log('token：${entry.token}（文件 ${tokenFile().path}）');
  _log('工具 ${enabled.length} 个（入口只答清单，实际调用分给后端实例）');
  _log('配置片段：');
  _log(mcpConfigSnippet(httpUrl: 'http://127.0.0.1:${args.httpPort}/mcp'));
  final done = Completer<void>();
  Future<void> shutdown() async {
    if (done.isCompleted) return;
    entry.unregister();
    await hs.close(force: true);
    entry.dispose();
    done.complete();
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown());
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => shutdown());
  }
  await done.future;
  exit(0);
}

Future<void> main(List<String> argv) async {
  // 必须在任何 WebSocket / HttpClient 之前：本机回环直连（MCP 调 GUI 的
  // /api/* 也是回环），避免继承了 http_proxy 时被发给代理而卡住。
  bypassProxyForLoopback();
  _Args args;
  try {
    args = _parseArgs(argv);
  } on FormatException catch (e) {
    _log('参数错误：${e.message}');
    _log(_usage);
    exit(2);
  }
  if (args.help) {
    stdout.writeln(_usage);
    return;
  }
  if (args.logFile.isNotEmpty) {
    try {
      final f = File(args.logFile);
      f.parent.createSync(recursive: true);
      _logSink = f;
    } catch (_) {
      // 路径不可写就只走 stderr。
    }
  }
  final proxyHint = proxyEnvHint();
  if (proxyHint != null) {
    _log('[xbume-mcp] 检测到代理环境（$proxyHint）：本机回环连接已自动绕过代理。');
  }
  final version = _readVersion();
  if (args.version) {
    stdout.writeln('xb_ume mcp $version');
    return;
  }

  Set<String> groups;
  try {
    groups = _resolveGroups(args);
  } on FormatException catch (e) {
    _log(e.message);
    exit(2);
  }

  // 工具清单先建：池入口本地也要答 tools/list（和 worker 用同一份，避免两边不一致）。
  final all = <McpTool>[
    ...coreTools(allowEval: args.allowEval),
    ...deviceTools(),
    ...debugTools(),
    ...bridgeTools(),
    ...toolboxTools(),
  ];
  final enabled = all.where((t) => groups.contains(t.group)).toList();

  if (args.poolEntry) {
    await _runPoolEntry(args, version, enabled, groups);
    return;
  }

  final registry = SessionRegistry(
    skipPorts: <int>{if (args.http) args.httpPort},
  );
  for (final u in args.uris) {
    registry.addManual(u);
  }
  // 实例名：显式 --name 优先，否则 http 按端口 / stdio 按 pid。
  // 一 AI 一进程时，租约里写的就是这个名字，谁在驱动一眼能看出来。
  final instanceName = args.name.trim().isEmpty
      ? defaultInstanceName(http: args.http, port: args.httpPort)
      : sanitizeInstanceName(args.name);
  if (instanceName.isEmpty) {
    _log('--name 不能为空（只允许字母、数字、下划线、点、横线与中文）');
    exit(2);
  }
  final conflict = instanceNameConflict(instanceName);
  if (conflict != null) {
    final cport = int.tryParse('${conflict['port'] ?? 0}') ?? 0;
    _log('实例名 $instanceName 已被 pid ${conflict['pid']} 占用'
        '${cport > 0 ? '（端口 $cport）' : ''}');
    _log('换一个名字：dart run xb_ume:mcp --http ${args.httpPort} '
        '--name $instanceName-2');
    exit(2);
  }
  // 设备后端只建一份：工具层与场景层共用，避免各自 fromSpec 出现两份进程。
  final devices = DeviceRegistry.fromSpec(args.deviceBackend);
  final scenarios = ScenarioService(registry, devices: devices);
  final ctx = McpToolContext(
    sessions: registry,
    scenarios: scenarios,
    allowEval: args.allowEval,
    devices: devices,
    deviceBackend: args.deviceBackend,
    guiPort: args.guiPort,
    instanceName: instanceName,
    instancePort: args.http ? args.httpPort : 0,
  );
  final server = McpServer(
    ctx: ctx,
    version: version,
    tools: enabled,
    token: args.http ? ensureToken() : '',
  )..init();

  final names = enabled.map((t) => t.name).join(', ');
  void registerInstance() => writeInstance(<String, Object?>{
        'name': instanceName,
        'transport': args.http ? 'http' : 'stdio',
        'port': args.http ? args.httpPort : 0,
        'pid': pid,
        'version': version,
        'hasEval': args.allowEval,
        'toolCount': enabled.length,
        'groups': groups.toList()..sort(),
        if (args.slot != null) 'poolSlot': args.slot,
        'startedAt': DateTime.now().toIso8601String(),
      });
  void unregisterInstance() => removeInstance(instanceName, onlyPid: pid);
  if (args.http) {
    HttpServer hs;
    try {
      hs = await server.serveHttp(args.httpPort);
    } on SocketException catch (e) {
      _log('端口 ${args.httpPort} 无法监听：${e.message}');
      _log('换一个端口：dart run xb_ume:mcp --http 46141');
      await server.close();
      exit(2);
    }
    final token = server.token;
    registerInstance();
    // 池成员：告诉入口「我这里有没有场景在跑」。入口的回收扫描看到 running
    // 就只续期不收，避免把跑到一半的自动化腰斩；场景结束后自动回到可回收。
    Timer? poolReporter;
    if (args.slot != null) {
      // max 取池的上限（9）：入口可能用 --pool-max 开到 9，而这里只做
      // “这个槽号存不存在”的范围校验。
      final store = PoolStore(max: 9);
      Future<void> report() async {
        try {
          await store.markRunning(args.slot!, scenarios.active?.done == false);
        } catch (_) {
          // 池目录写不了不该影响 MCP 服务。
        }
      }

      unawaited(report());
      poolReporter =
          Timer.periodic(const Duration(seconds: 5), (_) => unawaited(report()));
    }
    _log('xb_ume MCP $version · HTTP http://127.0.0.1:${args.httpPort}/mcp'
        ' · 实例 $instanceName');
    _log('token：$token（文件 ${tokenFile().path}）');
    _log('工具 ${enabled.length} 个：$names');
    _log('配置片段：');
    _log(mcpConfigSnippet(httpUrl: 'http://127.0.0.1:${args.httpPort}/mcp'));
    final done = Completer<void>();
    Future<void> shutdown() async {
      if (done.isCompleted) return;
      poolReporter?.cancel();
      unregisterInstance();
      await hs.close(force: true);
      await server.close();
      await ctx.debugPool.disposeAll();
      done.complete();
    }

    ProcessSignal.sigint.watch().listen((_) => shutdown());
    if (!Platform.isWindows) {
      ProcessSignal.sigterm.watch().listen((_) => shutdown());
    }
    await done.future;
    exit(0);
  }

  registerInstance();
  _log('xb_ume MCP $version · stdio · 实例 $instanceName · 工具 ${enabled.length} 个');
  try {
    await server.serveStdio();
  } finally {
    unregisterInstance();
    await server.close();
    await ctx.debugPool.disposeAll();
  }
  // stdin EOF 后显式退出：残留的 WebSocket/审计文件句柄会拖住事件循环。
  exit(0);
}
