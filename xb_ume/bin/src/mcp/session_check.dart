// 会话自检（xbume_session_check）：一次调用回答「这个会话能干什么」。
//
// 背景：AI 接上会话后最贵的两件事是——发一次热重载等 60s 才发现通道不通、
// 逐个工具试到失败才知道能力边界。这里把判定做在前面：
//
//   - VM 通不通：一次 getIsolate（顺带拿 extensionRPCs，判断 inspector /
//     性能扩展是否注册，不额外发 RPC）；
//   - 是不是我要的设备 / 项目：live 记录里的 pid / cwd / device 与期望比对；
//   - 能不能改代码并生效：热重载通道（signal / stdin / none，与
//     `xbume_sessions` 的标记同源）；
//   - 可选实测：verifyReload 真发一次重载。没有文件改动时 flutter run 只会
//     回 `No changes detected`，不改 app 状态；有改动则会真的重载（默认开）。
//
// 判定逻辑全是纯函数（[judgeSession]），单测不碰进程与网络。
library;

import '../device/flutter_run.dart';
import '../session/agent_client.dart';
import '../session/capability.dart';
import 'session_registry.dart';

/// 会话结论级别。
enum SessionVerdict {
  /// 能看、能点、能改代码并生效。
  ready,

  /// 能看能点，但改代码没法由本工具重载（IDE 拉起 / Windows 认领）。
  readyNoReload,

  /// 能用但能力不全（release 包没 inspector，或通道实测失败）。
  degraded,

  /// 设备不是期望的那台：立即停手。
  wrongDevice,

  /// 项目目录不是期望的那个。
  wrongProject,

  /// 端口还在但 VM 连不上（进程已退 / DDS 死了 / 转发断了）。
  stale,
}

String sessionVerdictName(SessionVerdict v) {
  switch (v) {
    case SessionVerdict.ready:
      return 'ready';
    case SessionVerdict.readyNoReload:
      return 'ready_no_reload';
    case SessionVerdict.degraded:
      return 'degraded';
    case SessionVerdict.wrongDevice:
      return 'wrong_device';
    case SessionVerdict.wrongProject:
      return 'wrong_project';
    case SessionVerdict.stale:
      return 'stale';
  }
}

/// 从 `adb:SERIAL#port:54110` 里取设备序列号；`port:54110` 这类来源返回 null。
///
/// 与 [McpSession.deviceId] 同一套前缀规则（adb / hdc / simctl / idevice）。
String? serialFromSource(String source) {
  final hash = source.indexOf('#');
  final head = hash > 0 ? source.substring(0, hash) : source;
  final colon = head.indexOf(':');
  if (colon <= 0) return null;
  const backends = <String>{'adb', 'hdc', 'simctl', 'idevice'};
  if (!backends.contains(head.substring(0, colon))) return null;
  final serial = head.substring(colon + 1).trim();
  return serial.isEmpty ? null : serial;
}

/// 判定输入：全部是探测结果 + live 记录，纯数据。
class SessionSignals {
  const SessionSignals({
    required this.source,
    required this.channel,
    this.expectDevice,
    this.expectCwd,
    this.launcherCwd,
    this.launcherDevice,
    this.launcherOwner,
    this.adopted = false,
    this.inspector = false,
    this.perf = false,
    this.evalOk = false,
    this.libraries,
    this.vmError,
    this.reloadVerified,
  });

  /// 会话来源（`adb:SERIAL#port:N` / `port:N`）。
  final String source;

  /// 热重载通道。
  final ReloadChannel channel;

  /// 调用方期望的设备序列号 / 项目根（不传就不校验）。
  final String? expectDevice;
  final String? expectCwd;

  /// live 记录里的启动目录与设备号（IDE 拉起、没有记录时为 null）。
  final String? launcherCwd;
  final String? launcherDevice;
  final String? launcherOwner;
  final bool adopted;

  /// 能力：inspector 扩展 / `ext.xbume.processStats` / 求值。
  final bool inspector;
  final bool perf;
  final bool evalOk;

  /// 已加载库数量（5397 之类的规模信号；读不到为 null）。
  final int? libraries;

  /// VM service 探测失败原因（null = 通）。
  final String? vmError;

  /// 热重载通道是否实测过：null = 没测，true/false = 测过。
  final bool? reloadVerified;
}

/// 判定结论。
class SessionJudgement {
  const SessionJudgement({
    required this.verdict,
    required this.usable,
    this.warnings = const <String>[],
    this.next = const <String>[],
  });

  final SessionVerdict verdict;
  final bool usable;
  final List<String> warnings;
  final List<String> next;
}

/// 纯判定：按「能不能连 → 是不是我要的 → 能不能改」三段决定结论。
///
/// 顺序有意固定：设备和项目不对时先停手，不要再去评估能力（否则会拿到一份
/// 「能热重载」的结论去操作另一台手机）。
SessionJudgement judgeSession(SessionSignals s) {
  final warnings = <String>[];
  final next = <String>[];
  // 来源里没有设备前缀（GUI 拉的会话只有 `port:54110`）时，用 live 记录里的
  // 设备号兜底——否则 AI 带着 deviceId 来校验，设备不对也发现不了。
  final serial = serialFromSource(s.source) ?? s.launcherDevice;

  if (s.vmError != null) {
    return SessionJudgement(
      verdict: SessionVerdict.stale,
      usable: false,
      warnings: <String>['VM service 连不上：${s.vmError}'],
      next: <String>[
        'xbume_sessions{"refresh":true} 重新扫描',
        '仍失败就重新启动 app（本服务用 app_launch，IDE 那侧重跑）',
      ],
    );
  }

  if (s.expectDevice != null &&
      serial != null &&
      serial != s.expectDevice!.trim()) {
    return SessionJudgement(
      verdict: SessionVerdict.wrongDevice,
      usable: false,
      warnings: <String>['会话在设备 $serial 上，期望 ${s.expectDevice}'],
      next: <String>[
        '不要继续操作这个会话（热重载会打错包）',
        '切到目标设备的会话，或 app_launch{deviceId:"${s.expectDevice}"}',
      ],
    );
  }

  if (s.expectCwd != null && s.launcherCwd != null) {
    final a = resolvePathForCompare(s.expectCwd!);
    final b = resolvePathForCompare(s.launcherCwd!);
    if (a != b) {
      return SessionJudgement(
        verdict: SessionVerdict.wrongProject,
        usable: false,
        warnings: <String>['会话的启动目录是 ${s.launcherCwd}，期望 ${s.expectCwd}'],
        next: <String>['用目标项目的会话，或按 cwd 重新 app_launch'],
      );
    }
  }

  if (!s.evalOk) {
    warnings.add('求值不可用：点按（坐标）/ 读运行时状态会失败（release 包或 isolate 未就绪）');
  }
  if (!s.inspector) {
    warnings.add('inspector 未注册：截图 / find_widget / widget_tree 不可用（release 包常见）');
  }

  if (s.channel == ReloadChannel.none) {
    warnings.add('没有热重载通道：进程由 IDE/终端拉起（拿不到句柄），或 Windows 认领会话');
    next.add('改完代码只能让拉起方自己按 r，或 app_launch{"force":true} 由本服务重装重启');
    return SessionJudgement(
      verdict: SessionVerdict.readyNoReload,
      usable: true,
      warnings: warnings,
      next: next,
    );
  }

  if (s.reloadVerified == false) {
    warnings.add('热重载通道实测失败（见 probe.message）：先别用 hot_reload 下结论');
    next.add('可重试一次；仍失败就 app_launch{"force":true} 重装重启后再验');
    return SessionJudgement(
      verdict: SessionVerdict.degraded,
      usable: true,
      warnings: warnings,
      next: next,
    );
  }

  if (!s.inspector || !s.evalOk) {
    next.add('只做只读排查（日志 / 路由 / 异常）；别承诺「改完已生效」');
    return SessionJudgement(
      verdict: SessionVerdict.degraded,
      usable: true,
      warnings: warnings,
      next: next,
    );
  }

  next.add('改完代码 → hot_reload{"mode":"reload"}（约 2s）；'
      'initState / 单例 / 路由表 / main 初始化顺序用 "restart"');
  return SessionJudgement(
    verdict: SessionVerdict.ready,
    usable: true,
    warnings: warnings,
    next: next,
  );
}

/// 一次热重载实测的结果。
class ReloadProbe {
  const ReloadProbe({
    required this.ok,
    required this.message,
    required this.elapsedMs,
    required this.channel,
  });

  final bool ok;
  final String message;
  final int elapsedMs;
  final String channel;

  Map<String, Object?> toJson() => <String, Object?>{
        'ok': ok,
        'message': message,
        'elapsedMs': elapsedMs,
        'channel': channel,
      };
}

/// 自检的完整结果（文本 + 结构化都给）。
class SessionCheckResult {
  SessionCheckResult({
    required this.sessionId,
    required this.port,
    required this.source,
    required this.app,
    required this.judgement,
    this.caps = const <String, Object?>{},
    this.launcher = const <String, Object?>{},
    this.libraries,
    this.vmError,
    this.probe,
  });

  final String sessionId;
  final int port;
  final String source;
  final String app;
  final SessionJudgement judgement;
  final Map<String, Object?> caps;
  final Map<String, Object?> launcher;
  final int? libraries;
  final String? vmError;
  final ReloadProbe? probe;

  SessionVerdict get verdict => judgement.verdict;

  Map<String, Object?> toJson() => <String, Object?>{
        'ok': true,
        'sessionId': sessionId,
        'port': port,
        'source': source,
        'app': app.isEmpty ? null : app,
        'verdict': sessionVerdictName(judgement.verdict),
        'usable': judgement.usable,
        'caps': caps,
        'launcher': launcher,
        if (libraries != null) 'libraries': libraries,
        if (vmError != null) 'vmError': vmError,
        if (probe != null) 'reloadProbe': probe!.toJson(),
        'warnings': judgement.warnings,
        'next': judgement.next,
      };

  /// 给 AI 直读的短文本：结论 + 四项能力 + 下一步。
  String describe() {
    final tag = launcher['label']?.toString() ?? '';
    final head = StringBuffer('会话 $sessionId')
      ..write(app.isEmpty ? '' : ' · $app')
      ..write(' · $source')
      ..write(tag.isEmpty ? '' : ' · $tag');

    final ch = probe?.channel ?? caps['reloadChannel']?.toString() ?? 'none';
    final v = sessionVerdictName(judgement.verdict);
    final use = judgement.usable ? '' : '（不可用）';
    final probeText = probe == null
        ? '未实测'
        : (probe!.ok
            ? '实测 ✓ ${probe!.elapsedMs}ms'
            : '实测 ✗ ${probe!.message}');
    head
      ..write('\n结论 $v$use：')
      ..write(judgement.usable ? '' : '先处理上面的问题；')
      ..write('可看${caps['inspector'] == true ? '' : ' ✗'}')
      ..write(' / 可点${(caps['act'] ?? caps['eval']) == true ? '' : ' ✗'}')
      ..write(' / 可重载${ch == 'none' ? ' ✗' : '（$ch，$probeText）'}');

    final lines = <String>[];
    if (caps['transport'] == kTransportAgent) {
      lines.add('直连 ✓ ${caps['agentUrl'] ?? ''}'
          '${caps['agentVersion'] == null ? '' : '（v${caps['agentVersion']}）'}'
          ' · 能力 ${capLabelsText((caps['agentCaps'] as List?)?.cast<String>() ?? const <String>[])}');
    }
    if (libraries != null) {
      lines.add('VM ✓ isolate main（$libraries 库）');
    } else if (vmError != null) {
      lines.add('VM ✗ $vmError');
    }
    lines.add(<String>[
      'inspector ${caps['inspector'] == true ? '✓' : '✗'}',
      '截图 ${caps['screenshot'] == true ? '✓' : '✗'}',
      '组件树 ${caps['widgetTree'] == true ? '✓' : '✗'}',
      '性能 ${caps['perf'] == true ? '✓' : '✗（ext.xbume.processStats 未注册）'}',
    ].join(' · '));
    final pid = launcher['pid'];
    if (pid != null) {
      lines.add('进程 pid $pid'
          '${launcher['owner'] == null ? '' : ' · ${launcher['owner']} 拉起'}'
          '${launcher['adopted'] == true ? '（认领）' : ''}'
          '${launcher['config'] == null ? '' : ' · 配置 ${launcher['config']}'}');
    } else {
      lines.add('进程：没有 live 记录（IDE 拉起，拿不到句柄）');
    }
    for (final w in judgement.warnings) {
      lines.add('! $w');
    }
    for (final n in judgement.next) {
      lines.add('→ $n');
    }
    head.write('\n- ${lines.join('\n- ')}');
    return head.toString();
  }
}

/// 探测一个会话并给出结论。
///
/// [verifyReload] 默认 true：真发一次热重载。没有文件改动时 flutter run 只会
/// 回 `No changes detected`（不改 app 状态）；有改动就会真的重载，所以 AI 应当
/// 在「还没动手改代码」时先跑一次自检。
Future<SessionCheckResult> runSessionCheck(
  McpSession s,
  FlutterRunLauncher launcher, {
  String? expectDevice,
  String? expectCwd,
  bool verifyReload = true,
  Duration verifyTimeout = const Duration(seconds: 20),
}) async {
  // 直连会话没有 VM 通道：探 /v1/hello 与能力清单，不跑 VM 那套自检。
  if (!s.hasVm) return _runAgentSessionCheck(s, verifyTimeout: verifyTimeout);
  Map<String, Object?>? isolate;
  String? vmError;
  var evalOk = false;
  int? libraries;
  try {
    final id = await s.client.isolateId();
    final iso = await s.client.rawRpc(
        'getIsolate', <String, Object?>{'isolateId': id});
    isolate = iso;
    final libs = iso['libraries'];
    libraries = libs is List ? libs.length : null;
  } catch (e) {
    vmError = '$e';
  }

  if (vmError == null) {
    // 一次最便宜的求值：点按（坐标）与读运行时状态都走这条路。
    try {
      evalOk = (await s.client.evalString('1 + 1')).trim() == '2';
    } catch (_) {
      evalOk = false;
    }
  }

  final exts = <String>{
    for (final e in (isolate?['extensionRPCs'] as List? ?? const <Object?>[]))
      '$e',
  };
  // 本进程可能还没认领过任何进程（启动后没调过 launch）：先读一遍磁盘清单。
  // 不补这一步，GUI 上次拉起的 flutter run 会被误判成「没有通道」的只读会话，
  // 明明一条 SIGUSR1 就能重载。adoptRecords 只校验 pid 存活 + 命令行。
  var handle = launcher.byPort(s.port);
  if (handle == null) {
    try {
      launcher.adoptRecords();
    } catch (_) {
      // 清单损坏不影响自检：当作没有 live 记录处理。
    }
    handle = launcher.byPort(s.port);
  }
  final channel = handle?.reloadChannel ?? ReloadChannel.none;

  ReloadProbe? probe;
  if (verifyReload &&
      handle != null &&
      channel != ReloadChannel.none &&
      vmError == null) {
    try {
      final r =
          await launcher.hotReload(handle.pid, timeout: verifyTimeout);
      probe = ReloadProbe(
        ok: r.ok,
        message: r.message,
        elapsedMs: r.elapsedMs,
        channel: reloadChannelName(r.channel),
      );
    } catch (e) {
      probe = ReloadProbe(
        ok: false,
        message: '$e',
        elapsedMs: 0,
        channel: reloadChannelName(channel),
      );
    }
  }

  final signals = SessionSignals(
    source: s.source,
    channel: channel,
    expectDevice: expectDevice,
    expectCwd: expectCwd,
    launcherCwd: handle?.cwd,
    launcherDevice: handle?.device,
    launcherOwner: handle?.owner,
    adopted: handle?.adopted ?? false,
    inspector: exts.any((e) => e.startsWith('ext.flutter.inspector.')),
    perf: exts.contains('ext.xbume.processStats'),
    evalOk: evalOk,
    libraries: libraries,
    vmError: vmError,
    reloadVerified: probe?.ok,
  );
  final judgement = judgeSession(signals);

  final app = (s.appName.isEmpty || s.appName == 'vm') ? '' : s.appName;
  return SessionCheckResult(
    sessionId: s.id,
    port: s.port,
    source: s.source,
    app: app,
    judgement: judgement,
    caps: <String, Object?>{
      'eval': evalOk,
      'act': evalOk,
      'inspector': exts.any((e) => e.startsWith('ext.flutter.inspector.')),
      'screenshot': exts.contains('ext.flutter.inspector.screenshot'),
      'widgetTree':
          exts.contains('ext.flutter.inspector.getRootWidgetSummaryTree'),
      'perf': exts.contains('ext.xbume.processStats'),
      'reloadChannel': reloadChannelName(channel),
    },
    launcher: <String, Object?>{
      if (handle != null) ...<String, Object?>{
        'pid': handle.pid,
        'cwd': handle.cwd,
        'device': handle.device,
        'target': handle.target,
        'config': handle.config,
        'owner': handle.owner,
        'adopted': handle.adopted,
        'label': '${handle.owner}${handle.adopted ? '认领' : '拉起'}'
            '${channel == ReloadChannel.none ? '·只读' : '·可热重载(${reloadChannelName(channel)})'}',
      },
    },
    libraries: libraries,
    vmError: vmError,
    probe: probe,
  );
}

/// 直连会话自检：探 `/v1/hello` + `/v1/state`，能力取 app 自报 ∩ 理论上限。
///
/// 直连没有 isolate / 热重载 / 求值，所以不跑 VM 那套探测；结论统一是
/// `ready_no_reload`（能看能点、改代码需拉起方重启），服务不可达时是 `stale`。
Future<SessionCheckResult> _runAgentSessionCheck(
  McpSession s, {
  Duration verifyTimeout = const Duration(seconds: 5),
}) async {
  final base = s.agentBaseUrl ?? '';
  final app = (s.appName.isEmpty || s.appName == 'vm') ? '' : s.appName;
  final caps = s.caps;
  String? err;
  var hello = const <String, Object?>{};
  try {
    final http = AgentClient(base, timeout: verifyTimeout);
    hello = await http.hello();
    await http.state();
  } catch (e) {
    err = '$e';
  }
  final missing = missingCaps(
    caps,
    const <String>[Cap.debug, Cap.hot, Cap.srclocateExact],
  );
  final warnings = <String>[
    '直连会话（release 包没有 VM 调试服务）：${capLabelsText(missing)}不可用',
    if (!caps.contains(Cap.routeStack))
      '路由栈详情读不到（Navigator 历史是私有字段），只看时间轴里的路由事件流',
    if (err != null) '直连服务不可达：$err',
  ];
  final judgement = SessionJudgement(
    verdict: err == null ? SessionVerdict.readyNoReload : SessionVerdict.stale,
    usable: err == null,
    warnings: warnings,
    next: err == null
        ? const <String>['数据面 / 动作面可直接用；改代码需由拉起方重启 app']
        : const <String>[
            '确认 app 已开直连服务（--dart-define 打开 XBUmeAgent）',
            'xbume_sessions{"refresh":true} 重新扫描',
          ],
  );
  return SessionCheckResult(
    sessionId: s.id,
    port: s.port,
    source: s.source,
    app: app,
    judgement: judgement,
    caps: <String, Object?>{
      'transport': kTransportAgent,
      'eval': false,
      'act': caps.contains(Cap.act),
      'inspector': caps.contains(Cap.widgets),
      'screenshot': caps.contains(Cap.shot),
      'widgetTree': caps.contains(Cap.widgets),
      'perf': caps.contains(Cap.perf),
      'reloadChannel': 'none',
      'agentUrl': base,
      'agentVersion': hello['version'],
      'agentCaps': caps.toList()..sort(),
      'missing': missing,
    },
    launcher: const <String, Object?>{},
  );
}
