// 全局快捷键配置：~/.xb_ume_ide/hotkeys.json
//
// GUI「调试」页的全局快捷键（热重载 / 热重启）由这里的模型描述：
//   {"enabled": true,
//    "reload":  {"key": "KeyR", "cmd": true, "shift": true},
//    "restart": {"key": "KeyR", "cmd": true, "alt": true}}
//
// `key` 用浏览器 KeyboardEvent.code（物理键位，不受输入法 / 键盘布局影响），
// 监听器再翻成 macOS 虚拟键码（Carbon RegisterEventHotKey 只认键码）。
//
// 本文件与 hotkey_listener.dart 一起部署到 ~/.xb_ume_ide/src/hotkeys/，
// 不能出现 package: 依赖（部署副本只按相对路径解析）。
library;

import 'dart:convert';
import 'dart:io';

/// 配置 / 状态 / pid 文件名（都在 [xbumeIdeDir] 下）。
const String kHotkeysFileName = 'hotkeys.json';
const String kHotkeysStatusFileName = 'hotkeys.status.json';
const String kHotkeysPidFileName = 'hotkeys.pid';
const String kHotkeysLogFileName = 'hotkeys.log';

/// 安装目录（与 ide.dart 的 kInstallDirName 保持一致）。
String xbumeIdeDir(String home) => '$home${Platform.pathSeparator}.xb_ume_ide';

String hotkeysFilePath(String home) =>
    '${xbumeIdeDir(home)}${Platform.pathSeparator}$kHotkeysFileName';

String hotkeysStatusPath(String home) =>
    '${xbumeIdeDir(home)}${Platform.pathSeparator}$kHotkeysStatusFileName';

String hotkeysLogPath(String home) =>
    '${xbumeIdeDir(home)}${Platform.pathSeparator}$kHotkeysLogFileName';

/// 浏览器 KeyboardEvent.code → macOS 虚拟键码（Carbon 用）。
///
/// 只收录能用键盘按出来的键；没收录的（媒体键等）在设置页会被拒。
const Map<String, int> kMacVirtualKeyCodes = <String, int>{
  'KeyA': 0x00,
  'KeyS': 0x01,
  'KeyD': 0x02,
  'KeyF': 0x03,
  'KeyH': 0x04,
  'KeyG': 0x05,
  'KeyZ': 0x06,
  'KeyX': 0x07,
  'KeyC': 0x08,
  'KeyV': 0x09,
  'KeyB': 0x0B,
  'KeyQ': 0x0C,
  'KeyW': 0x0D,
  'KeyE': 0x0E,
  'KeyR': 0x0F,
  'KeyY': 0x10,
  'KeyT': 0x11,
  'Digit1': 0x12,
  'Digit2': 0x13,
  'Digit3': 0x14,
  'Digit4': 0x15,
  'Digit6': 0x16,
  'Digit5': 0x17,
  'Equal': 0x18,
  'Digit9': 0x19,
  'Digit7': 0x1A,
  'Minus': 0x1B,
  'Digit8': 0x1C,
  'Digit0': 0x1D,
  'BracketRight': 0x1E,
  'KeyO': 0x1F,
  'KeyU': 0x20,
  'BracketLeft': 0x21,
  'KeyI': 0x22,
  'KeyP': 0x23,
  'Enter': 0x24,
  'KeyL': 0x25,
  'KeyJ': 0x26,
  'Quote': 0x27,
  'KeyK': 0x28,
  'Semicolon': 0x29,
  'Backslash': 0x2A,
  'Comma': 0x2B,
  'Slash': 0x2C,
  'KeyN': 0x2D,
  'KeyM': 0x2E,
  'Period': 0x2F,
  'Tab': 0x30,
  'Space': 0x31,
  'Backquote': 0x32,
  'Backspace': 0x33,
  'Escape': 0x35,
  'F1': 0x7A,
  'F2': 0x78,
  'F3': 0x63,
  'F4': 0x76,
  'F5': 0x60,
  'F6': 0x61,
  'F7': 0x62,
  'F8': 0x64,
  'F9': 0x65,
  'F10': 0x6D,
  'F11': 0x67,
  'F12': 0x6F,
  'F13': 0x69,
  'F14': 0x6B,
  'F15': 0x71,
  'F16': 0x6A,
  'F17': 0x40,
  'F18': 0x4F,
  'F19': 0x50,
  'F20': 0x5A,
  'ArrowLeft': 0x7B,
  'ArrowRight': 0x7C,
  'ArrowDown': 0x7D,
  'ArrowUp': 0x7E,
  'Home': 0x73,
  'End': 0x77,
  'PageUp': 0x74,
  'PageDown': 0x79,
  'Delete': 0x75,
};

/// 键位的显示名（与前端 hkKeyLabel 保持同一套字符）。
String hotkeyKeyLabel(String code) {
  if (code.startsWith('Key') && code.length == 4) {
    return code.substring(3).toUpperCase();
  }
  if (code.startsWith('Digit') && code.length == 6) {
    return code.substring(5);
  }
  if (RegExp(r'^F\d{1,2}$').hasMatch(code)) return code;
  const extra = <String, String>{
    'Minus': '-',
    'Equal': '=',
    'Comma': ',',
    'Period': '.',
    'Slash': '/',
    'Backslash': r'\',
    'Semicolon': ';',
    'Quote': "'",
    'BracketLeft': '[',
    'BracketRight': ']',
    'Backquote': '`',
    'Space': 'Space',
    'Enter': '↩',
    'Tab': '⇥',
    'Escape': 'Esc',
    'Backspace': '⌫',
    'Delete': '⌦',
    'Home': '↖',
    'End': '↘',
    'PageUp': '⇞',
    'PageDown': '⇟',
    'ArrowLeft': '←',
    'ArrowRight': '→',
    'ArrowUp': '↑',
    'ArrowDown': '↓',
  };
  return extra[code] ?? code;
}

/// 一个快捷键组合。
class XbHotkeyBinding {
  const XbHotkeyBinding({
    required this.key,
    this.cmd = false,
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
  });

  /// KeyboardEvent.code（如 KeyR / F5 / Digit1）。
  final String key;
  final bool cmd;
  final bool ctrl;
  final bool alt;
  final bool shift;

  bool get isEmpty => key.isEmpty;

  /// 至少一个 ⌘ / ⌃ / ⌥：只有 Shift 的组合会把正常打字吞掉，设置页直接拒。
  bool get hasModifier => cmd || ctrl || alt;

  int? get macKeyCode => kMacVirtualKeyCodes[key];

  /// Carbon 修饰键（RegisterEventHotKey 用）。
  int get carbonModifiers =>
      (cmd ? 0x0100 : 0) |
      (shift ? 0x0200 : 0) |
      (alt ? 0x0800 : 0) |
      (ctrl ? 0x1000 : 0);

  /// 展示用标签：⌃⌥⇧⌘R（macOS 菜单里的固定顺序）。
  String get label {
    final sb = StringBuffer();
    if (ctrl) sb.write('⌃');
    if (alt) sb.write('⌥');
    if (shift) sb.write('⇧');
    if (cmd) sb.write('⌘');
    sb.write(hotkeyKeyLabel(key));
    return sb.toString();
  }

  /// 去重用的稳定标识（含修饰键顺序无关的比较）。
  String get identity =>
      '${cmd ? 'cmd' : ''}-${ctrl ? 'ctrl' : ''}-${alt ? 'alt' : ''}'
      '-${shift ? 'shift' : ''}-$key';

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        if (cmd) 'cmd': true,
        if (ctrl) 'ctrl': true,
        if (alt) 'alt': true,
        if (shift) 'shift': true,
      };

  static XbHotkeyBinding? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = '${raw['key'] ?? ''}'.trim();
    if (key.isEmpty) return null;
    bool flag(String k) => raw[k] == true;
    return XbHotkeyBinding(
      key: key,
      cmd: flag('cmd'),
      ctrl: flag('ctrl'),
      alt: flag('alt'),
      shift: flag('shift'),
    );
  }

  /// 校验一条绑定；合法返回 null，否则返回给用户看的错误文案。
  String? validate() {
    if (isEmpty) return null; // 未设置是合法状态
    if (!kMacVirtualKeyCodes.containsKey(key)) {
      return '不支持的按键「$key」：换成字母 / 数字 / F1~F20 / 方向键等';
    }
    if (!hasModifier) return '至少带一个 ⌘ / ⌃ / ⌥：纯按键的组合会把正常输入吞掉';
    return null;
  }
}

/// 全局快捷键配置。
class XbHotkeysConfig {
  const XbHotkeysConfig({this.enabled = false, this.reload, this.restart});

  final bool enabled;
  final XbHotkeyBinding? reload;
  final XbHotkeyBinding? restart;

  static const XbHotkeysConfig empty = XbHotkeysConfig();

  bool get hasAny =>
      (reload != null && !reload!.isEmpty) ||
      (restart != null && !restart!.isEmpty);

  /// 真正要注册的条件。
  bool get active => enabled && hasAny;

  /// 第一条错误（保存 / 启动前用）；合法返回 null。
  String? validate() {
    final r = reload?.validate();
    if (r != null) return '热重载：$r';
    final s = restart?.validate();
    if (s != null) return '热重启：$s';
    final a = reload;
    final b = restart;
    if (a != null && b != null && !a.isEmpty && a.identity == b.identity) {
      return '热重载与热重启不能是同一个组合（${a.label}）';
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': enabled,
        if (reload != null) 'reload': reload!.toJson(),
        if (restart != null) 'restart': restart!.toJson(),
      };

  static XbHotkeysConfig fromJson(Object? raw) {
    if (raw is! Map) return empty;
    return XbHotkeysConfig(
      enabled: raw['enabled'] == true,
      reload: XbHotkeyBinding.fromJson(raw['reload']),
      restart: XbHotkeyBinding.fromJson(raw['restart']),
    );
  }

  XbHotkeysConfig copyWith({
    bool? enabled,
    XbHotkeyBinding? reload,
    XbHotkeyBinding? restart,
  }) =>
      XbHotkeysConfig(
        enabled: enabled ?? this.enabled,
        reload: reload ?? this.reload,
        restart: restart ?? this.restart,
      );
}

/// 读配置；文件不存在 / 解析失败一律回默认（不打断 GUI 启动）。
XbHotkeysConfig readHotkeysConfig(String home) {
  try {
    final f = File(hotkeysFilePath(home));
    if (!f.existsSync()) return XbHotkeysConfig.empty;
    return XbHotkeysConfig.fromJson(jsonDecode(f.readAsStringSync()));
  } catch (_) {
    return XbHotkeysConfig.empty;
  }
}

/// 写配置（目录自动创建）；返回错误文案，成功返回 null。
String? writeHotkeysConfig(String home, XbHotkeysConfig cfg) {
  try {
    final dir = Directory(xbumeIdeDir(home));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File(hotkeysFilePath(home))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(cfg.toJson()));
    return null;
  } catch (e) {
    return '写入 ${hotkeysFilePath(home)} 失败：$e';
  }
}

/// 读监听器写的运行状态（没在跑 / 没有文件返回 null）。
Map<String, Object?>? readHotkeysStatus(String home) {
  try {
    final f = File(hotkeysStatusPath(home));
    if (!f.existsSync()) return null;
    final v = jsonDecode(f.readAsStringSync());
    return v is Map ? v.map((k, v) => MapEntry('$k', v)) : null;
  } catch (_) {
    return null;
  }
}
