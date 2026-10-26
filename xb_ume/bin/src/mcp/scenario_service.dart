// MCP 侧场景运行服务：异步执行、状态查询、停止、报告落盘。
//
// 复用 bin/src/scenario/runner.dart（与 CLI 同一套步骤语义），因此 GUI 保存
// 的场景文件在 MCP 里直接可跑。约束：同一时刻只允许一个运行实例，避免多个
// 场景同时注入手势把 app 状态打乱。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../device/registry.dart';
import '../scenario/runner.dart';
import '../scenario/scenario_file.dart';
import 'session_registry.dart';

/// 场景名安全校验：与 GUI 保存规则一致，同时阻止 `..` 路径逃逸。
final RegExp _kNameRe = RegExp(r'^[\w\u4e00-\u9fff-]{1,64}$');

/// 一次运行的完整状态。
class ScenarioRun {
  ScenarioRun({
    required this.runId,
    required this.name,
    required this.sessionId,
    required this.continueOnFail,
    required this.shotEveryStep,
  }) : startedAt = DateTime.now();

  final String runId;
  final String name;
  final String sessionId;
  final bool continueOnFail;
  final bool shotEveryStep;
  final DateTime startedAt;

  DateTime? finishedAt;
  String? error;
  String? reportPath;
  ScenarioRunReport? report;
  List<ScenarioStepResult> results = <ScenarioStepResult>[];
  bool stopRequested = false;
  bool done = false;

  int get total => results.length;
  int get passCount => results.where((r) => r.isPass).length;
  int get failCount => results.where((r) => r.isFail).length;
  int get skipCount => results.where((r) => r.isSkip).length;

  Map<String, Object?> toJson() => <String, Object?>{
        'runId': runId,
        'name': name,
        'sessionId': sessionId,
        'running': !done,
        'stopRequested': stopRequested,
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
        'total': total,
        'pass': passCount,
        'fail': failCount,
        'skip': skipCount,
        'ok': done && failCount == 0,
        'reportPath': reportPath,
        'error': error,
        'results': results
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
      };
}

class ScenarioService {
  ScenarioService(this.sessions, {this.devices});

  final SessionRegistry sessions;

  /// 与 MCP 工具层共用同一份设备后端（--device-backend 生效）。
  final DeviceRegistry? devices;

  final Map<String, ScenarioRun> _runs = <String, ScenarioRun>{};
  String? _activeRunId;
  int _seq = 0;

  ScenarioRun? byId(String runId) => _runs[runId];
  ScenarioRun? get active => _activeRunId == null ? null : _runs[_activeRunId!];

  String get scenariosDir => '${xbUmeHome()}/scenarios';
  String get reportsDir => '$scenariosDir/reports';

  /// 可用场景列表（GUI 保存的 json 目录）。
  List<Map<String, Object?>> listScenarios() {
    final dir = Directory(scenariosDir);
    if (!dir.existsSync()) return const <Map<String, Object?>>[];
    final out = <Map<String, Object?>>[];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final name = f.uri.pathSegments.last.replaceAll(RegExp(r'\.json$'), '');
      var steps = 0;
      try {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is List) {
          steps = raw.length;
        } else if (raw is Map && raw['steps'] is List) {
          steps = (raw['steps'] as List).length;
        }
      } catch (_) {
        // 坏文件仍列出，stepCount 为 -1 提示不可用。
        steps = -1;
      }
      out.add(<String, Object?>{
        'name': name,
        'path': f.path,
        'stepCount': steps,
        'modifiedAt': f.statSync().modified.toIso8601String(),
      });
    }
    return out;
  }

  /// 启动一次运行（立即返回 runId，执行在后台）。
  ScenarioRun start({
    String? name,
    List<Map<String, dynamic>>? steps,
    String? sessionId,
    bool continueOnFail = false,
    bool shotEveryStep = false,
  }) {
    final running = active;
    if (running != null && !running.done) {
      throw StateError('已有场景在运行（$running.runId ${running.name}），先停止或等待完成');
    }
    if ((name == null || name.trim().isEmpty) &&
        (steps == null || steps.isEmpty)) {
      throw ArgumentError('需要 name（场景名）或 steps（步骤数组）');
    }
    var runName = (name ?? 'inline').trim();
    List<Map<String, dynamic>> list;
    if (steps != null && steps.isNotEmpty) {
      list = steps;
    } else {
      if (!_kNameRe.hasMatch(runName)) {
        throw ArgumentError('场景名非法：只允许中文/字母/数字/下划线/横线，长度 1-64');
      }
      final f = resolveScenarioFile(runName);
      if (f == null) {
        throw StateError('找不到场景 $runName（目录 $scenariosDir）');
      }
      final (loadedName, loadedSteps) = loadScenario(f);
      runName = loadedName;
      list = loadedSteps;
    }
    final session = sessions.requireCurrent(sessionId);
    final runId = 'r${DateTime.now().millisecondsSinceEpoch}-${_seq++}';
    final run = ScenarioRun(
      runId: runId,
      name: runName,
      sessionId: session.id,
      continueOnFail: continueOnFail,
      shotEveryStep: shotEveryStep,
    );
    _runs[runId] = run;
    _activeRunId = runId;
    // 仅保留最近 20 次运行的状态，避免长驻进程内存增长。
    if (_runs.length > 20) {
      final stale = _runs.keys
          .where((k) => k != runId && (_runs[k]?.done ?? true))
          .take(_runs.length - 20)
          .toList();
      for (final k in stale) {
        _runs.remove(k);
      }
    }
    unawaited(_execute(run, list));
    return run;
  }

  Future<void> _execute(
      ScenarioRun run, List<Map<String, dynamic>> steps) async {
    final vm = sessions.requireCurrent(run.sessionId).client;
    final runner = ScenarioRunner(
      vm,
      continueOnFail: run.continueOnFail,
      shotEveryStep: run.shotEveryStep,
      devices: devices,
      shotsDir: '$reportsDir/shots',
      shotPrefix: 'mcp-${_safe(run.name)}-${run.runId}',
      shouldStop: () => run.stopRequested,
      onStep: (r) {
        // 每步追加一次，让 status 查询能拿到中间进度（最终以 report 为准）。
        run.results = <ScenarioStepResult>[...run.results, r];
      },
    );
    try {
      final report = await runner.run(run.name, steps);
      run.report = report;
      run.results = report.results;
      try {
        final ts = report.startedAt
            .toIso8601String()
            .replaceAll(RegExp(r'[-:]'), '')
            .replaceAll('T', '-')
            .split('.')
            .first;
        final path = '$reportsDir/mcp-${_safe(run.name)}-$ts.html';
        final f = File(path);
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(buildScenarioReportHtml(
          report,
          version: '',
          command: 'xb_ume MCP · ${run.runId}',
        ));
        run.reportPath = path;
      } catch (e) {
        run.error = '报告写入失败：$e';
      }
    } catch (e) {
      run.error = e.toString();
    } finally {
      run.finishedAt = DateTime.now();
      run.done = true;
      if (_activeRunId == run.runId) _activeRunId = null;
    }
  }

  /// 请求停止；返回是否命中运行中的场景。
  bool stop(String runId) {
    final run = _runs[runId];
    if (run == null || run.done) return false;
    run.stopRequested = true;
    return true;
  }

  /// 报告 HTML 内容（未生成时返回 null）。
  String? reportHtml(String runId) {
    final path = _runs[runId]?.reportPath;
    if (path == null) return null;
    final f = File(path);
    if (!f.existsSync()) return null;
    return f.readAsStringSync();
  }

  String _safe(String s) => s.replaceAll(RegExp(r'[^\w\u4e00-\u9fff-]'), '_');
}
