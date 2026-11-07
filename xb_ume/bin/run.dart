// xb_ume 场景命令行执行器（无需 GUI / 浏览器，可直接用于 CI）。
//
// 用法：
//   dart run xb_ume:run <场景文件|场景名> --uri <ws-url|端口> [选项]
//
// 选项：
//   --uri <v>              VM service 地址（ws-url / host:port / 纯端口）或直连 http(s)://
//   --report <out.html>    报告输出路径（默认 $XB_UME_HOME/scenarios/reports/）
//   --continue-on-fail     失败后继续执行（默认失败即停止，剩余步骤跳过）
//   --shot-every-step      每步都截图（默认只截失败步骤）
//   --wait-after <ms>      步间稳定延迟（默认 700）
//   --shots-dir <dir>      额外把截图 PNG 落盘到目录
//   --list                 列出 $XB_UME_HOME/scenarios 下的场景
//   --json                 机器可读输出（stdout 仅一行 JSON）
//
// 退出码：0 全部通过（含 skip）；1 有失败步骤；2 参数/场景加载/连接错误。
//
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';

import 'src/scenario/runner.dart';
import 'src/scenario/scenario_file.dart';
import 'src/scenario/vm_client.dart';
import 'src/session/agent_client.dart';
import 'src/session/session_api.dart';

const String _usage = '''
xb_ume 场景命令行执行器

用法：
  dart run xb_ume:run <场景文件|场景名> --uri <ws-url|端口> [选项]

选项：
  --uri <v>              VM service 地址：完整 ws(s):// URL、host:port 或纯端口（如 65296）
  --report <out.html>    报告输出路径（默认 \$XB_UME_HOME/scenarios/reports/run-<场景>-<时间>.html）
  --continue-on-fail     失败后继续执行（默认失败即停止，剩余步骤跳过）
  --shot-every-step      每步都截图（默认只截失败步骤）
  --wait-after <ms>      步间稳定延迟（默认 700）
  --shots-dir <dir>      额外把截图 PNG 落盘到目录
  --list                 列出可用场景
  --json                 stdout 只输出一行 JSON（进度不打印）
  -h, --help             显示帮助

环境变量：
  XB_UME_HOME            数据目录（默认 \$HOME/.xb_ume_ide）

退出码：0 全部通过；1 有失败步骤；2 参数/场景加载错误。
''';

/// 包版本（从同目录 pubspec.yaml 读；全局 activate/AOT 取不到时为空）。
String _readVersion() {
  try {
    final f = File.fromUri(Platform.script.resolve('../pubspec.yaml'));
    if (!f.existsSync()) return '';
    final m = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(f.readAsStringSync());
    return m?.group(1) ?? '';
  } catch (_) {}
  return '';
}

class _Args {
  String scenario = '';
  String uri = '';
  String report = '';
  bool continueOnFail = false;
  bool shotEveryStep = false;
  int waitAfterMs = 700;
  String shotsDir = '';
  bool list = false;
  bool json = false;
  bool help = false;
}

/// 解析参数；无法识别的参数抛 FormatException（由 main 转成退出码 2）。
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
      case '--uri':
        a.uri = next('--uri');
        break;
      case '--report':
        a.report = next('--report');
        break;
      case '--continue-on-fail':
        a.continueOnFail = true;
        break;
      case '--shot-every-step':
        a.shotEveryStep = true;
        break;
      case '--wait-after':
        a.waitAfterMs = int.tryParse(next('--wait-after')) ??
            (throw const FormatException('--wait-after 需要整数毫秒'));
        break;
      case '--shots-dir':
        a.shotsDir = next('--shots-dir');
        break;
      case '--list':
        a.list = true;
        break;
      case '--json':
        a.json = true;
        break;
      default:
        if (s.startsWith('-')) throw FormatException('未知参数 $s');
        if (a.scenario.isNotEmpty) {
          throw FormatException('只能指定一个场景（已指定 ${a.scenario}）');
        }
        a.scenario = s;
    }
  }
  return a;
}

String _oneLine(String s, {int max = 120}) {
  var t = s.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
  if (t.length > max) t = '${t.substring(0, max)}…';
  return t;
}

String _fmtMs(int ms) => ms >= 10000 ? '${(ms / 1000).toStringAsFixed(1)}s' : '${ms}ms';

void main(List<String> argv) async {
  _Args args;
  try {
    args = _parseArgs(argv);
  } on FormatException catch (e) {
    stderr.writeln('参数错误：${e.message}');
    stderr.writeln(_usage);
    exit(2);
  }
  if (args.help) {
    stdout.writeln(_usage);
    return;
  }
  if (args.list) {
    final dir = Directory('${xbUmeHome()}/scenarios');
    final files = dir.existsSync()
        ? dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
        : <File>[];
    files.sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) {
      stdout.writeln('${dir.path} 下没有场景（先在 GUI「自动化」Tab 保存场景）');
    } else {
      for (final f in files) {
        stdout.writeln(f.uri.pathSegments.last.replaceAll(RegExp(r'\.json$'), ''));
      }
    }
    return;
  }
  if (args.scenario.isEmpty) {
    stderr.writeln('缺少场景参数（场景文件路径或场景名，见 --list）');
    stderr.writeln(_usage);
    exit(2);
  }
  if (args.uri.isEmpty) {
    stderr.writeln('缺少 --uri（VM service 地址或端口）');
    stderr.writeln(_usage);
    exit(2);
  }
  final file = resolveScenarioFile(args.scenario);
  if (file == null) {
    stderr.writeln('找不到场景：${args.scenario}'
        '（不是存在的文件，也不在 ${xbUmeHome()}/scenarios 下）');
    exit(2);
  }
  String name;
  List<Map<String, dynamic>> steps;
  try {
    (name, steps) = loadScenario(file);
  } catch (e) {
    stderr.writeln('场景解析失败：$e');
    exit(2);
  }

  final version = _readVersion();
  // http(s):// 是 app 内直连；其余按 VM service 归一。
  final isAgent = isAgentBaseUrl(args.uri);
  final api = connectSessionApi(
      isAgent ? normalizeAgentBaseUrl(args.uri) : normalizeVmUri(args.uri));
  final uri = api.uri;
  final progress = !args.json;
  if (progress) {
    stdout.writeln('xb_ume run${version.isEmpty ? '' : ' $version'}');
    stdout.writeln('场景 $name（${steps.length} 步）→ $uri');
  }
  final runner = ScenarioRunner.fromApi(
    api,
    continueOnFail: args.continueOnFail,
    shotEveryStep: args.shotEveryStep,
    waitAfterMs: args.waitAfterMs,
    shotsDir: args.shotsDir.isEmpty ? null : args.shotsDir,
    shotPrefix: name.replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]'), '_'),
    onStep: progress
        ? (r) {
            final mark = r.isPass ? '✓' : (r.isFail ? '✗' : '-');
            final detail = r.error.isNotEmpty
                ? _oneLine(r.error)
                : (r.actual.isNotEmpty ? _oneLine(r.actual) : '');
            stdout.writeln('[${r.index + 1}/${steps.length}] '
                '${r.type.padRight(14)} $mark ${_fmtMs(r.ms).padLeft(6)}'
                '${detail.isEmpty ? '' : '  $detail'}');
          }
        : null,
  );
  ScenarioRunReport report;
  try {
    report = await runner.run(name, steps);
  } catch (e) {
    stderr.writeln('执行失败：$e');
    await api.close();
    exit(2);
  }
  await api.close();

  // 报告路径：--report 显式指定；否则落到数据目录 scenarios/reports 下。
  String reportPath;
  if (args.report.isNotEmpty) {
    reportPath = File(args.report).absolute.path;
  } else {
    final ts = report.startedAt
        .toIso8601String()
        .replaceAll(RegExp(r'[-:]'), '')
        .replaceAll('T', '-')
        .split('.')
        .first;
    final safe = name.replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]'), '_');
    reportPath = '${xbUmeHome()}/scenarios/reports/run-$safe-$ts.html';
  }
  final command = 'dart run xb_ume:run ${args.scenario} --uri ${args.uri}'
      '${args.continueOnFail ? ' --continue-on-fail' : ''}'
      '${args.shotEveryStep ? ' --shot-every-step' : ''}'
      '${args.report.isEmpty ? '' : ' --report ${args.report}'}';
  var reportSaved = false;
  try {
    final html =
        buildScenarioReportHtml(report, version: version, command: command);
    final f = File(reportPath);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(html);
    reportSaved = true;
  } catch (e) {
    stderr.writeln('报告写入失败：$e');
  }

  final secs = (report.duration.inMilliseconds / 1000).toStringAsFixed(1);
  if (args.json) {
    stdout.writeln(jsonEncode(<String, Object?>{
      'ok': report.ok,
      'scenario': name,
      'uri': uri,
      'total': report.total,
      'pass': report.passCount,
      'fail': report.failCount,
      'skip': report.skipCount,
      'durationMs': report.duration.inMilliseconds,
      'report': reportSaved ? reportPath : '',
      'results': report.results
          .map((r) => <String, Object?>{
                'index': r.index + 1,
                'type': r.type,
                'status': r.status,
                'expect': r.expect,
                'actual': r.actual,
                'error': r.error,
                'ms': r.ms,
              })
          .toList(),
    }));
  } else {
    stdout.writeln('结果：${report.passCount} pass · ${report.failCount} fail · '
        '${report.skipCount} skip · 用时 ${secs}s'
        '${report.ok ? ' · 全部通过' : ''}');
    if (reportSaved) {
      stdout.writeln('报告：$reportPath');
    }
  }
  exit(report.ok ? 0 : 1);
}
