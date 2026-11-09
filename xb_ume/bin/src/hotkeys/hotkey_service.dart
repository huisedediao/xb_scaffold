// 全局快捷键子进程管理（GUI 侧）。
//
// 真正的系统级热键注册在 hotkey_listener.dart 里（macOS 用 Carbon、Windows 用
// user32 RegisterHotKey，各自堵在自己的原生事件循环上），这里只负责：读 / 写
// hotkeys.json、按精确 pid 拉起 / 停掉监听器、把运行状态（是否在跑、注册成功没、
// 最近一次触发结果）整理给 /api/hotkeys。
//
// 配置变了不做热更：停掉旧进程再拉起新进程，避免「注销 - 重注册」中间态把
// 用户的热键短暂让给别人。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hotkey_config.dart';
import '../control/svc_control.dart' show bundledExe, kBundledHotkeyExe;

/// 监听器脚本路径：部署副本与源码目录都是 <ide_gui.dart 所在目录>/src/hotkeys。
String defaultHotkeyScriptPath() {
  final dir = File(Platform.script.toFilePath()).parent.path;
  return '$dir${Platform.pathSeparator}src${Platform.pathSeparator}hotkeys'
      '${Platform.pathSeparator}hotkey_listener.dart';
}

/// 全局快捷键服务（GUI 单实例一个）。
class HotkeyService {
  HotkeyService({
    required this.home,
    required this.port,
    this.token = '',
    String? scriptPath,
  }) : _scriptPath = scriptPath ?? defaultHotkeyScriptPath();

  final String home;
  final int port;
  final String token;
  final String _scriptPath;

  Process? _proc;
  int? _pid;
  bool _alive = false;
  String _message = '';
  final List<String> _tail = <String>[];

  bool get supported => Platform.isMacOS || Platform.isWindows;

  /// 实际使用的入口：分发版是 GUI 同目录的 `xbume-hotkey`，源码部署是
  /// `hotkey_listener.dart` 脚本。状态页用这个字段，别把 AOT 下推断出的
  /// 脚本路径（并不存在）显示给用户。
  String get scriptPath => bundledExe(kBundledHotkeyExe) ?? _scriptPath;

  String get _pidFile =>
      '${xbumeIdeDir(home)}${Platform.pathSeparator}$kHotkeysPidFileName';

  /// GUI 启动时调用：有启用配置就拉起监听器（已在跑则保持）。
  Future<void> start() async {
    if (!supported) {
      _message = '全局快捷键目前只支持 macOS / Windows';
      return;
    }
    final cfg = readHotkeysConfig(home);
    if (!cfg.active) {
      _message = cfg.enabled ? '已启用，但还没设置任何快捷键' : '未启用';
      return;
    }
    final bad = cfg.validate();
    if (bad != null) {
      _message = '配置不合法：$bad';
      return;
    }
    if (_alive && _proc != null) return;
    await _killStale();
    await _spawn();
  }

  /// 保存配置：校验 → 落盘 → 重启监听器。
  Future<Map<String, Object?>> save(Map<String, Object?> raw) async {
    if (!supported) {
      return <String, Object?>{
        ...status(),
        'ok': false,
        'error': '全局快捷键目前只支持 macOS / Windows（其他平台可在页面内用按钮 / 调试页操作）',
      };
    }
    final cfg = XbHotkeysConfig.fromJson(raw);
    final bad = cfg.validate();
    if (bad != null) {
      return <String, Object?>{...status(), 'ok': false, 'error': bad};
    }
    final werr = writeHotkeysConfig(home, cfg);
    if (werr != null) {
      return <String, Object?>{...status(), 'ok': false, 'error': werr};
    }
    await stop(keepMessage: true);
    if (!cfg.active) {
      _message = cfg.enabled ? '已保存：还没设置快捷键，未注册' : '已保存：已关闭全局快捷键';
      return <String, Object?>{...status(), 'ok': true, 'message': _message};
    }
    await _spawn();
    return <String, Object?>{
      ...status(),
      'ok': true,
      'message': '已保存，监听器已启动（约 1 秒后生效）',
    };
  }

  /// 运行状态快照（/api/hotkeys 的响应体）。
  Map<String, Object?> status() {
    final cfg = readHotkeysConfig(home);
    final helper = readHotkeysStatus(home);
    List<Object?> listOf(Object? v) =>
        v is List ? List<Object?>.of(v) : const <Object?>[];
    return <String, Object?>{
      'ok': true,
      'supported': supported,
      'platform': Platform.operatingSystem,
      'enabled': cfg.enabled,
      'active': cfg.active,
      'config': cfg.toJson(),
      'configError': cfg.validate(),
      'running': _alive,
      'pid': _pid,
      'message': _message,
      'script': scriptPath,
      'logPath': hotkeysLogPath(home),
      'statusFile': hotkeysStatusPath(home),
      'registered': listOf(helper?['registered']),
      'errors': listOf(helper?['errors']),
      'helperPid': helper?['pid'],
      'lastAction': helper?['lastAction'],
      'lastResult': helper?['lastResult'],
      'lastAt': helper?['lastAt'],
      'tail': List<String>.of(_tail),
    };
  }

  /// 停掉监听器（GUI 退出 / 配置关闭）。[keepMessage] 保留上一条提示。
  Future<void> stop({bool keepMessage = false}) async {
    final proc = _proc;
    _proc = null;
    _alive = false;
    _pid = null;
    if (proc != null) {
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
      try {
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }
    // 没有句柄但 pid 文件还在（GUI 重启上任留下的）：也一并收掉，避免旧监听
    // 器继续占着热键，导致新监听器注册失败。
    await _killStale();
    if (!keepMessage) _message = '监听器已停止';
    if (!keepMessage) {
      try {
        File(_pidFile).deleteSync();
      } catch (_) {}
    }
  }

  Future<void> dispose() => stop(keepMessage: true);

  // ---------------------------------------------------------------- 进程

  Future<void> _spawn() async {
    // 分发版：监听器是和 GUI 同目录的 xbume-hotkey；源码部署：跑 .dart 脚本。
    final exe = bundledExe(kBundledHotkeyExe);
    final script = exe == null ? File(_scriptPath) : null;
    if (exe == null && !script!.existsSync()) {
      _message = '缺少 $_scriptPath：重新部署 GUI（dart run xb_ume:ide --install）后可用';
      return;
    }
    try {
      final args = <String>[
        if (script != null) script.path,
        '--home',
        home,
        '--port',
        '$port',
        if (token.isNotEmpty) ...<String>['--token', token],
      ];
      final proc = await Process.start(exe ?? Platform.resolvedExecutable, args);
      _proc = proc;
      _pid = proc.pid;
      _alive = true;
      _message = '监听中（pid ${proc.pid}）';
      try {
        final dir = Directory(xbumeIdeDir(home));
        if (!dir.existsSync()) dir.createSync(recursive: true);
        File(_pidFile).writeAsStringSync('${proc.pid}\n');
      } catch (_) {}
      const utf8Lenient = Utf8Codec(allowMalformed: true);
      void eat(Stream<List<int>> s) {
        s.transform(utf8Lenient.decoder).transform(const LineSplitter()).listen(
          (line) {
            final t = line.trim();
            if (t.isEmpty) return;
            _tail.add(t);
            if (_tail.length > 50) _tail.removeAt(0);
          },
          onError: (_) {},
        );
      }

      eat(proc.stdout);
      eat(proc.stderr);
      unawaited(proc.exitCode.then((code) {
        if (!identical(_proc, proc)) return;
        _alive = false;
        _pid = null;
        _message = code == 0
            ? '监听器已退出'
            : '监听器异常退出（code $code），原因见 ${hotkeysLogPath(home)}';
      }));
    } catch (e) {
      _alive = false;
      _message = '拉起监听器失败：$e';
    }
  }

  /// 按 pid 文件精确收掉「上一任 GUI 留下的」监听器。
  ///
  /// 只认命令行里带 hotkey_listener.dart 的进程：绝不按名字模糊杀，
  /// 避免误伤用户同机的其他 dart 进程。
  Future<void> _killStale() async {
    int? stale;
    try {
      final f = File(_pidFile);
      if (f.existsSync()) stale = int.tryParse(f.readAsStringSync().trim());
    } catch (_) {}
    if (stale == null || stale <= 0 || stale == pid) {
      try {
        File(_pidFile).deleteSync();
      } catch (_) {}
      return;
    }
    if (!_looksLikeListener(stale)) {
      try {
        File(_pidFile).deleteSync();
      } catch (_) {}
      return;
    }
    try {
      Process.killPid(stale, ProcessSignal.sigterm);
    } catch (_) {}
    for (var i = 0; i < 10; i++) {
      if (!_pidAlive(stale)) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_pidAlive(stale)) {
      try {
        Process.killPid(stale, ProcessSignal.sigkill);
      } catch (_) {}
    }
    try {
      File(_pidFile).deleteSync();
    } catch (_) {}
  }

  bool _looksLikeListener(int pid) {
    try {
      if (Platform.isWindows) {
        // wmic 在新系统上已弃用，用 CIM 查命令行；参数直传，不经 shell。
        final r = Process.runSync('powershell', <String>[
          '-NoProfile',
          '-Command',
          '(Get-CimInstance Win32_Process -Filter "ProcessId=$pid").CommandLine',
        ]);
        return '${r.stdout}'.contains('hotkey_listener.dart');
      }
      final r = Process.runSync('ps', <String>['-o', 'command=', '-p', '$pid']);
      return r.exitCode == 0 &&
          '${r.stdout}'.contains('hotkey_listener.dart');
    } catch (_) {
      return false;
    }
  }

  bool _pidAlive(int p) {
    if (p <= 0) return false;
    // Windows 没有 kill -0：用 tasklist 按 PID 过滤，什么都不输出就是没了。
    if (Platform.isWindows) {
      try {
        final r =
            Process.runSync('tasklist', <String>['/FI', 'PID eq $p', '/NH']);
        return r.exitCode == 0 && RegExp('\\b$p\\b').hasMatch('${r.stdout}');
      } catch (_) {
        return false;
      }
    }
    try {
      return Process.runSync('kill', <String>['-0', '$p']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
