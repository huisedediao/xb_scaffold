// xb_ume MCP 服务入口（stdio / Streamable HTTP）。
//
// 用法：
//   dart run xb_ume:mcp                 # stdio，供 Qoder / Cursor / Claude Code 接入
//   dart run xb_ume:mcp --http 46140    # 本机 HTTP，供远程或多客户端复用
//
// 选项：
//   --stdio                  stdio 传输（默认）
//   --http <port>            Streamable HTTP 传输（默认 46140；仅绑 127.0.0.1）
//   --uri <port|ws-url>      手工指定会话（跳过自动发现，可重复）
//   --tool-groups <list>     all 或逗号分隔的组名：act,device-write（其余组为预留）
//   --no-tool-groups         只暴露核心工具（关掉默认开启的 diagnose / run-safe）
//   --allow-eval             预留开关：eval 类工具尚未提供（见 MCP_GUIDE 已知缺口）
//   --device-backend <list>  设备后端：auto（默认）/ adb,hdc,simctl,idevice / mobile-mcp
//   -h, --help               帮助
//   --version                版本
//
// stdout 只用于 MCP 协议（stdio 模式）；所有日志与提示走 stderr。
library;

import 'dart:async';
import 'dart:io';

import 'src/device/registry.dart';
import 'src/mcp/device_tools.dart';
import 'src/mcp/scenario_service.dart';
import 'src/mcp/server.dart';
import 'src/mcp/session_registry.dart';
import 'src/mcp/tools.dart';

const String _usage = '''
xb_ume MCP 服务

用法：
  dart run xb_ume:mcp [--stdio | --http <port>] [选项]

选项：
  --stdio                  stdio 传输（默认），供 Qoder / Cursor / Claude Code 接入
  --http <port>            Streamable HTTP（默认 46140，仅绑 127.0.0.1，需 token）
  --uri <port|ws-url>      手工指定 VM service 会话（跳过自动发现，可重复）
  --tool-groups <list>     all 或逗号分隔：act,device-write（inspect/ai/ide 预留）
  --no-tool-groups         只暴露核心工具
  --allow-eval             预留开关：eval 类工具尚未提供
  --device-backend <list>  设备后端：auto / adb,hdc,simctl,idevice / mobile-mcp
  --log-file <path>        额外把启动与运日志追加写入文件（GUI 后台拉起时排障用）
  -h, --help               显示帮助
  --version                显示版本

默认工具 20 个（core 14 + diagnose 3 + run-safe 3）；有副作用的组需显式开启。
HTTP 模式 token 首次运行生成在 \$XB_UME_HOME/mcp.token。
''';

class _Args {
  bool http = false;
  int httpPort = 46140;
  bool noToolGroups = false;
  String toolGroups = '';
  bool allowEval = false;
  String deviceBackend = 'auto';
  String logFile = '';
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

Future<void> main(List<String> argv) async {
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

  final registry = SessionRegistry(
    skipPorts: <int>{if (args.http) args.httpPort},
  );
  for (final u in args.uris) {
    registry.addManual(u);
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
  );
  final all = <McpTool>[...coreTools(), ...deviceTools()];
  final enabled = all.where((t) => groups.contains(t.group)).toList();
  final server = McpServer(
    ctx: ctx,
    version: version,
    tools: enabled,
    token: args.http ? ensureToken() : '',
  )..init();

  final names = enabled.map((t) => t.name).join(', ');
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
    _log('xb_ume MCP $version · HTTP http://127.0.0.1:${args.httpPort}/mcp');
    _log('token：$token（文件 ${tokenFile().path}）');
    _log('工具 ${enabled.length} 个：$names');
    _log('配置片段：');
    _log(mcpConfigSnippet(httpUrl: 'http://127.0.0.1:${args.httpPort}/mcp'));
    final done = Completer<void>();
    Future<void> shutdown() async {
      if (done.isCompleted) return;
      await hs.close(force: true);
      await server.close();
      done.complete();
    }

    ProcessSignal.sigint.watch().listen((_) => shutdown());
    if (!Platform.isWindows) {
      ProcessSignal.sigterm.watch().listen((_) => shutdown());
    }
    await done.future;
    exit(0);
  }

  _log('xb_ume MCP $version · stdio · 工具 ${enabled.length} 个');
  try {
    await server.serveStdio();
  } finally {
    await server.close();
  }
  // stdin EOF 后显式退出：残留的 WebSocket/审计文件句柄会拖住事件循环。
  exit(0);
}
