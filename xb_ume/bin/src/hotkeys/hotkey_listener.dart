// 全局快捷键监听器（macOS 系统级热键）。
//
// 由 GUI（ide_gui.dart）作为子进程拉起，配置来自 ~/.xb_ume_ide/hotkeys.json：
//   热重载 / 热重启 两条组合 → 按下时 POST /api/hotkey/action 给 GUI，
//   由 GUI 的调试中枢对「当前 flutter run 会话」发 SIGUSR1 / SIGUSR2。
//
// 为什么必须单独一个进程 + Carbon：
//   macOS 的系统级热键最省事的是 Carbon 的 RegisterEventHotKey（不需要
//   「辅助功能」授权）。它要求进程跑在 Carbon 事件循环（RunApplicationEventLoop）
//   里，而 Dart 的事件循环不是 CFRunLoop，所以本进程的主 isolate 直接阻塞在
//   CFRunLoop 上，把「按键 → HTTP」丢给后台 isolate；主线程只做同步回调。
//
// 配置变化不热更：GUI 保存后按精确 pid 停掉本进程再拉起（见 hotkey_service.dart）。
//
// 用法（GUI 内部使用）：
//   dart hotkey_listener.dart --home <HOME> --port <GUI端口> [--token <GUI令牌>]
// ignore_for_file: avoid_print
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'hotkey_config.dart';

// ---------------------------------------------------------------------------
// Carbon / HIToolbox 的 FFI 声明
// ---------------------------------------------------------------------------

/// kEventClassKeyboard（'keyb'）。
const int _kEventClassKeyboard = 0x6b657962;

/// kEventHotKeyPressed。
const int _kEventHotKeyPressed = 5;

/// kEventParamDirectObject（'----'），热键事件里带 EventHotKeyID。
const int _kEventParamDirectObject = 0x2d2d2d2d;

/// typeEventHotKeyID（'hkid'）。
const int _typeEventHotKeyID = 0x686b6964;

/// 本工具的签名（'XBum'），避免和别的进程的 EventHotKeyID 撞上。
const int _kSignature = 0x5842756d;

/// 热重载 / 热重启的 EventHotKeyID.id。
const int _kIdReload = 1;
const int _kIdRestart = 2;

final class _EventTypeSpec extends Struct {
  @Uint32()
  external int eventClass;

  @Uint32()
  external int eventKind;
}

final class _EventHotKeyID extends Struct {
  @Uint32()
  external int signature;

  @Uint32()
  external int id;
}

typedef _EventHandlerC = Int32 Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>);

const int _kErr = -1;

// ---------------------------------------------------------------------------
// 运行时状态
// ---------------------------------------------------------------------------

/// 日志 / 状态文件所在的 home。后台 isolate 是单独一份静态变量，
/// 必须在 _workerMain 里重新赋值（否则 _log 直接抛 LateInitializationError）。
late String _home;
late final int _guiPort;
String? _tokenArg;

/// 后台 isolate 的接收端口（主 isolate 阻塞在事件循环里，只能单向发）。
SendPort? _actionPort;

/// 当前的注册结果，状态文件 / 日志用。
final List<String> _registered = <String>[];
final List<String> _errors = <String>[];

String _lastAction = '';
String _lastResult = '';
String _lastAt = '';

void main(List<String> args) {
  _home = _argValue(args, '--home') ??
      Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '.';
  _guiPort = int.tryParse(_argValue(args, '--port') ?? '') ?? 0;
  _tokenArg = _argValue(args, '--token');

  if (!Platform.isMacOS) {
    _log('全局快捷键只支持 macOS，本进程退出');
    exit(0);
  }

  final cfg = readHotkeysConfig(_home);
  if (!cfg.active) {
    _log('配置未启用或没有设置快捷键，监听器退出');
    _writeStatus();
    exit(0);
  }
  final bad = cfg.validate();
  if (bad != null) {
    _log('配置不合法（$bad），监听器退出');
    _errors.add(bad);
    _writeStatus();
    exit(1);
  }

  // 退出信号在后台 isolate 里监听（见 _workerMain）：主 isolate 随后会阻塞在
  // Carbon 的 RunApplicationEventLoop 里，Dart 的异步信号消息根本轮不到它处理，
  // 实测 SIGTERM 打不进来只能 kill -9。
  unawaited(_run(cfg));
}

Future<void> _run(XbHotkeysConfig cfg) async {
  // 1) 后台 isolate：负责异步 HTTP（主 isolate 之后会被 CFRunLoop 占住）。
  final reply = ReceivePort();
  await Isolate.spawn(_workerMain, <Object?>[
    reply.sendPort,
    _guiPort,
    _tokenArg,
    _home,
  ]);
  _actionPort = await reply.first as SendPort;
  reply.close();

  // 2) 注册热键。任何一步失败都写日志 + 状态文件，退出让 GUI 显示原因。
  try {
    _installCarbon(cfg);
  } catch (e) {
    _errors.add('注册失败：$e');
    _log('注册全局快捷键失败：$e');
    _writeStatus();
    exit(1);
  }

  _writeStatus();
  _log('监听中：${_registered.join(' / ')}');
  // 3) 阻塞在 Carbon 事件循环：热键事件由 _onHotKey 同步回调。
  _runApplicationEventLoop();
  _log('事件循环结束');
  _writeStatus();
  exit(0);
}

// ---------------------------------------------------------------------------
// Carbon 注册
// ---------------------------------------------------------------------------

void _installCarbon(XbHotkeysConfig cfg) {
  final carbon = DynamicLibrary.open(
      '/System/Library/Frameworks/Carbon.framework/Carbon');

  final getAppTarget = carbon.lookupFunction<Pointer<Void> Function(),
      Pointer<Void> Function()>('GetApplicationEventTarget');
  final installHandler = carbon.lookupFunction<
      Int32 Function(
          Pointer<Void>,
          Pointer<NativeFunction<_EventHandlerC>>,
          Uint32,
          Pointer<_EventTypeSpec>,
          Pointer<Void>,
          Pointer<Pointer<Void>>),
      int Function(
          Pointer<Void>,
          Pointer<NativeFunction<_EventHandlerC>>,
          int,
          Pointer<_EventTypeSpec>,
          Pointer<Void>,
          Pointer<Pointer<Void>>)>('InstallEventHandler');
  final registerHotKey = carbon.lookupFunction<
      Int32 Function(Uint32, Uint32, _EventHotKeyID, Pointer<Void>, Uint32,
          Pointer<Pointer<Void>>),
      int Function(int, int, _EventHotKeyID, Pointer<Void>, int,
          Pointer<Pointer<Void>>)>('RegisterEventHotKey');
  _runApplicationEventLoop = carbon.lookupFunction<Void Function(),
      void Function()>('RunApplicationEventLoop');

  final target = getAppTarget();

  // 事件回调：取 EventHotKeyID.id → 转给后台 isolate。
  final handler = NativeCallable<_EventHandlerC>.isolateLocal(
    (Pointer<Void> call, Pointer<Void> event, Pointer<Void> userData) {
      final id = _malloc(sizeOf<_EventHotKeyID>()).cast<_EventHotKeyID>();
      _getEventParameter(
        event,
        _kEventParamDirectObject,
        _typeEventHotKeyID,
        nullptr,
        sizeOf<_EventHotKeyID>(),
        nullptr,
        id.cast(),
      );
      final hotkeyId = id.ref.id;
      _free(id.cast());
      _actionPort?.send(hotkeyId);
      return 0;
    },
    exceptionalReturn: _kErr,
  );

  final spec = _malloc(sizeOf<_EventTypeSpec>()).cast<_EventTypeSpec>();
  spec.ref.eventClass = _kEventClassKeyboard;
  spec.ref.eventKind = _kEventHotKeyPressed;
  final handlerRef = _malloc(sizeOf<Pointer<Void>>()).cast<Pointer<Void>>();
  final install = installHandler(
      target, handler.nativeFunction, 1, spec, nullptr, handlerRef);
  if (install != 0) {
    _errors.add('InstallEventHandler 失败（OSStatus $install）');
  }

  void register(int id, XbHotkeyBinding? b, String label) {
    if (b == null || b.isEmpty) return;
    final keyCode = b.macKeyCode;
    if (keyCode == null) {
      _errors.add('$label：不支持的按键 ${b.key}');
      return;
    }
    final hotKeyId = _malloc(sizeOf<_EventHotKeyID>()).cast<_EventHotKeyID>();
    hotKeyId.ref.signature = _kSignature;
    hotKeyId.ref.id = id;
    final refOut = _malloc(sizeOf<Pointer<Void>>()).cast<Pointer<Void>>();
    final st = registerHotKey(
        keyCode, b.carbonModifiers, hotKeyId.ref, target, 0, refOut);
    if (st == 0 && refOut.value != nullptr) {
      _registered.add('$label ${b.label}');
    } else {
      // 常见：-9869 / -9868 之类的「已被占用」——把键码一起写进日志好排查。
      _errors.add('$label ${b.label} 注册失败（OSStatus $st）：可能已被其他应用占用');
    }
  }

  register(_kIdReload, cfg.reload, '热重载');
  register(_kIdRestart, cfg.restart, '热重启');
  if (_registered.isEmpty) {
    _errors.add('没有任何热键注册成功');
  }
  _writeStatus();
}

/// 由 [DynamicLibrary] 覆盖（Carbon 的 RunApplicationEventLoop）。
void Function() _runApplicationEventLoop = () {};

// ---------------------------------------------------------------------------
// libc 分配器（部署副本不允许 package:ffi）
// ---------------------------------------------------------------------------

final DynamicLibrary _libc = DynamicLibrary.process();
final Pointer<Void> Function(int) _malloc = _libc.lookupFunction<
    Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>('malloc');
final void Function(Pointer<Void>) _free = _libc.lookupFunction<
    Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');

final int Function(Pointer<Void>, int, int, Pointer<Void>, int,
        Pointer<Uint32>, Pointer<Void>) _getEventParameter = DynamicLibrary
    .open('/System/Library/Frameworks/Carbon.framework/Carbon')
    .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Uint32, Pointer<Void>, Uint32,
            Pointer<Uint32>, Pointer<Void>),
        int Function(Pointer<Void>, int, int, Pointer<Void>, int,
            Pointer<Uint32>, Pointer<Void>)>('GetEventParameter');

// ---------------------------------------------------------------------------
// 后台 isolate：按键 → GUI HTTP + 心跳
// ---------------------------------------------------------------------------

Future<void> _workerMain(List<Object?> init) async {
  final mainPort = init[0] as SendPort;
  final guiPort = init[1] as int;
  final token = init[2] as String?;
  final home = init[3] as String;
  // 后台 isolate 看不到主 isolate 赋的值：两个 isolate 的静态变量各自独立。
  _home = home;

  final rp = ReceivePort();
  mainPort.send(rp.sendPort);

  // 优雅退出：GUI 按精确 pid 发 SIGTERM。事件循环在后台 isolate 里是通的，
  // 这里收到就直接结束进程（主 isolate 还阻塞在 CFRunLoop 上）。
  for (final sig in <ProcessSignal>[
    ProcessSignal.sigterm,
    ProcessSignal.sigint,
    ProcessSignal.sighup,
  ]) {
    try {
      sig.watch().listen((_) {
        _log('收到退出信号，监听器结束');
        exit(0);
      });
    } catch (_) {
      // 平台不支持该信号：跳过。
    }
  }

  var misses = 0;
  Timer? beat;
  if (guiPort > 0) {
    beat = Timer.periodic(const Duration(seconds: 5), (_) async {
      final ok = await _ping(guiPort, home);
      misses = ok ? 0 : misses + 1;
      // GUI 已退出（kill -9 / 崩溃）：60 秒还没回来就自己收摊，别留孤儿占热键。
      if (misses >= 12) {
        _log('GUI（端口 $guiPort）已连续 ${misses * 5}s 不可达，监听器退出');
        exit(0);
      }
    });
  }

  await for (final msg in rp) {
    if (msg is! int) continue;
    _lastAction = msg == _kIdRestart ? 'restart' : 'reload';
    _lastAt = DateTime.now().toIso8601String();
    final r = await _postAction(guiPort, token, home, _lastAction);
    _lastResult = r;
    _writeStatus();
  }
  beat?.cancel();
}

Future<bool> _ping(int port, String home) async {
  final client = HttpClient();
  try {
    final req = await client
        .getUrl(Uri.parse('http://127.0.0.1:$port/ping'))
        .timeout(const Duration(seconds: 2));
    final resp = await req.close().timeout(const Duration(seconds: 2));
    await resp.drain<void>();
    return resp.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// 触发一次动作；返回给状态文件看的一句话结果。
Future<String> _postAction(
    int port, String? token, String home, String action) async {
  if (port <= 0) {
    _log('没有 GUI 端口，无法执行 $action');
    return '没有 GUI 端口';
  }
  final effective = (token == null || token.isEmpty) ? _readToken() : token;
  final client = HttpClient();
  try {
    final req = await client
        .postUrl(Uri.parse('http://127.0.0.1:$port/api/hotkey/action'))
        .timeout(const Duration(seconds: 3));
    req.headers.contentType = ContentType.json;
    if (effective != null && effective.isNotEmpty) {
      req.headers.set('x-xbume-token', effective);
    }
    req.write(jsonEncode(<String, Object?>{'action': action}));
    final resp = await req.close().timeout(const Duration(seconds: 30));
    final text = await utf8.decoder
        .bind(resp)
        .join()
        .timeout(const Duration(seconds: 30));
    Map<String, Object?> body = const <String, Object?>{};
    try {
      final v = jsonDecode(text);
      if (v is Map) body = v.map((k, v) => MapEntry('$k', v));
    } catch (_) {}
    final ok = body['ok'] != false;
    final msg = body['error']?.toString() ??
        body['message']?.toString() ??
        (text.length > 200 ? '${text.substring(0, 200)}…' : text);
    _log('$action → ${ok ? 'ok' : '失败'}：$msg');
    return '${ok ? 'ok' : '失败'}：$msg';
  } catch (e) {
    _log('$action 请求失败：$e');
    return '请求失败：$e';
  } finally {
    client.close(force: true);
  }
}

String? _readToken() {
  try {
    final f = File('${xbumeIdeDir(_home)}${Platform.pathSeparator}gui.token');
    if (!f.existsSync()) return null;
    return f.readAsStringSync().trim();
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 日志 / 状态落盘（GUI 读它们显示「监听中 / 失败原因」）
// ---------------------------------------------------------------------------

const int _kLogCapBytes = 256 * 1024;

void _log(String msg) {
  final line = '[${DateTime.now().toIso8601String()}] $msg\n';
  try {
    final dir = Directory(xbumeIdeDir(_home));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File(hotkeysLogPath(_home));
    if (f.existsSync() && f.lengthSync() > _kLogCapBytes) {
      final tail = f.readAsStringSync();
      f.writeAsStringSync(tail.substring(tail.length ~/ 2));
    }
    f.writeAsStringSync(line, mode: FileMode.append, flush: true);
  } catch (_) {
    // 日志失败不影响热键。
  }
}

void _writeStatus() {
  try {
    final dir = Directory(xbumeIdeDir(_home));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File(hotkeysStatusPath(_home)).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'pid': pid,
        'ts': DateTime.now().toIso8601String(),
        'guiPort': _guiPort,
        'registered': List<String>.of(_registered),
        'errors': List<String>.of(_errors),
        if (_lastAction.isNotEmpty) 'lastAction': _lastAction,
        if (_lastResult.isNotEmpty) 'lastResult': _lastResult,
        if (_lastAt.isNotEmpty) 'lastAt': _lastAt,
      }),
    );
  } catch (_) {
    // 状态文件只服务 GUI 展示。
  }
}

String? _argValue(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i >= 0 && i + 1 < args.length) return args[i + 1];
  return null;
}
