// 全局快捷键配置模型（bin/src/hotkeys/hotkey_config.dart）的纯逻辑测试：
// 键码映射、展示标签、校验规则、hotkeys.json 读写。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/hotkeys/hotkey_config.dart';

void main() {
  group('键位映射与标签', () {
    test('字母 / 数字 / F 键的 macOS 键码与展示名', () {
      expect(kMacVirtualKeyCodes['KeyR'], 0x0F);
      expect(kMacVirtualKeyCodes['KeyA'], 0x00);
      expect(kMacVirtualKeyCodes['Digit1'], 0x12);
      expect(kMacVirtualKeyCodes['F5'], 0x60);
      expect(kMacVirtualKeyCodes.length, greaterThanOrEqualTo(60));
      expect(hotkeyKeyLabel('KeyR'), 'R');
      expect(hotkeyKeyLabel('Digit7'), '7');
      expect(hotkeyKeyLabel('F12'), 'F12');
      expect(hotkeyKeyLabel('ArrowUp'), '↑');
      expect(hotkeyKeyLabel('WeirdKey'), 'WeirdKey');
    });

    test('标签按 ⌃⌥⇧⌘ 顺序拼（与 macOS 菜单一致）', () {
      const b = XbHotkeyBinding(
        key: 'KeyR',
        cmd: true,
        ctrl: true,
        alt: true,
        shift: true,
      );
      expect(b.label, '⌃⌥⇧⌘R');
      const onlyCmd = XbHotkeyBinding(key: 'F5', cmd: true);
      expect(onlyCmd.label, '⌘F5');
    });

    test('Carbon 修饰位与 JSON 往返', () {
      const b = XbHotkeyBinding(key: 'KeyR', cmd: true, shift: true);
      expect(b.carbonModifiers, 0x0100 | 0x0200);
      final back = XbHotkeyBinding.fromJson(
        jsonDecode(jsonEncode(b.toJson())) as Map<String, Object?>,
      );
      expect(back, isNotNull);
      expect(back!.identity, b.identity);
      expect(back.label, '⇧⌘R');
      // 缺 key 的脏数据按「未设置」处理，不能让 GUI 崩。
      expect(XbHotkeyBinding.fromJson(<String, Object?>{'cmd': true}), isNull);
    });

    test('Windows VK 码与 Ctrl+ 写法标签', () {
      expect(kWindowsVirtualKeys['KeyR'], 0x52);
      expect(kWindowsVirtualKeys['F5'], 0x74);
      expect(kWindowsVirtualKeys['ArrowUp'], 0x26);
      // 两张表收录的键必须一模一样：配置才能在 macOS / Windows 之间直接搬
      expect(kWindowsVirtualKeys.keys.toSet(),
          kMacVirtualKeyCodes.keys.toSet());
      const b = XbHotkeyBinding(
        key: 'KeyR',
        cmd: true,
        ctrl: true,
        alt: true,
        shift: true,
      );
      expect(b.windowsVirtualKey, 0x52);
      expect(b.windowsLabel, 'Ctrl+Alt+Shift+Win+R');
      expect(b.hasKeyCode, isTrue);
      expect(const XbHotkeyBinding(key: 'AudioVolumeUp').hasKeyCode, isFalse);
    });

    test('RegisterHotKey 修饰位（含 MOD_NOREPEAT）', () {
      // MOD_ALT=0x0001 / MOD_CONTROL=0x0002 / MOD_SHIFT=0x0004 / MOD_WIN=0x0008
      // MOD_NOREPEAT=0x4000：按住不放只触发一次，否则热重载被长按连发
      const b = XbHotkeyBinding(key: 'KeyR', cmd: true, shift: true);
      expect(b.windowsModifiers, 0x4000 | 0x0008 | 0x0004);
      const plain = XbHotkeyBinding(key: 'KeyR', alt: true);
      expect(plain.windowsModifiers, 0x4000 | 0x0001);
    });
  });

  group('校验', () {
    test('纯按键（没有 ⌘/⌃/⌥）被拒', () {
      const b = XbHotkeyBinding(key: 'KeyR', shift: true);
      expect(b.validate(), contains('至少带一个'));
    });

    test('不支持的按键被拒', () {
      const b = XbHotkeyBinding(key: 'AudioVolumeUp', cmd: true);
      expect(b.validate(), contains('不支持'));
    });

    test('热重载与热重启不能是同一组合', () {
      const cfg = XbHotkeysConfig(
        enabled: true,
        reload: XbHotkeyBinding(key: 'KeyR', cmd: true),
        restart: XbHotkeyBinding(key: 'KeyR', cmd: true),
      );
      expect(cfg.validate(), contains('同一个组合'));
      expect(cfg.active, isTrue);
    });

    test('合法配置 / 空配置都通过校验', () {
      expect(XbHotkeysConfig.empty.validate(), isNull);
      const ok = XbHotkeysConfig(
        enabled: true,
        reload: XbHotkeyBinding(key: 'KeyR', cmd: true, shift: true),
        restart: XbHotkeyBinding(key: 'KeyR', cmd: true, alt: true),
      );
      expect(ok.validate(), isNull);
    });

    test('enabled 为 false 或没有任何绑定时 active 为 false', () {
      const onlyReload = XbHotkeysConfig(
        enabled: false,
        reload: XbHotkeyBinding(key: 'KeyR', cmd: true),
      );
      expect(onlyReload.active, isFalse);
      const emptyOn = XbHotkeysConfig(enabled: true);
      expect(emptyOn.active, isFalse);
      expect(emptyOn.hasAny, isFalse);
    });

    test('完成通知默认开，只有明确写 false 才关', () {
      // 默认开：不设置任何东西也该有「热重载完成」的提示
      expect(XbHotkeysConfig.empty.notify, isTrue);
      expect(XbHotkeysConfig.fromJson(<String, Object?>{}).notify, isTrue,
          reason: '老配置里没有 notify 键，不能当成关');
      expect(
          XbHotkeysConfig.fromJson(<String, Object?>{'notify': false}).notify,
          isFalse);
      // notify 与快捷键是否启用无关：不开热键也能收通知
      const noHotkey = XbHotkeysConfig(notify: true);
      expect(noHotkey.active, isFalse);
      expect(noHotkey.notify, isTrue);
    });
  });

  group('落盘', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('xbume_hk_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('写入 ~/.xb_ume_ide/hotkeys.json 后能读回来', () {
      expect(hotkeysFilePath('/tmp/h'), contains('${Platform.pathSeparator}.xb_ume_ide${Platform.pathSeparator}'));
      const cfg = XbHotkeysConfig(
        enabled: true,
        reload: XbHotkeyBinding(key: 'KeyR', cmd: true, shift: true),
        restart: XbHotkeyBinding(key: 'KeyE', cmd: true, alt: true),
      );
      expect(writeHotkeysConfig(tmp.path, cfg), isNull);
      final file = File(hotkeysFilePath(tmp.path));
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains('"enabled": true'));
      final back = readHotkeysConfig(tmp.path);
      expect(back.enabled, isTrue);
      expect(back.reload?.label, '⇧⌘R');
      expect(back.restart?.label, '⌥⌘E');
      // notify 也要写进文件：否则下次读回来又变回默认值
      expect(file.readAsStringSync(), contains('"notify": true'));
      expect(back.notify, isTrue);
      expect(
          writeHotkeysConfig(tmp.path, cfg.copyWith(notify: false)), isNull);
      expect(readHotkeysConfig(tmp.path).notify, isFalse);
    });

    test('文件不存在 / 内容损坏都回默认配置', () {
      expect(readHotkeysConfig(tmp.path).active, isFalse);
      File(hotkeysFilePath(tmp.path))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{not json');
      expect(readHotkeysConfig(tmp.path).active, isFalse);
    });

    test('状态文件读不出来时返回 null（GUI 只当没在跑）', () {
      expect(readHotkeysStatus(tmp.path), isNull);
    });
  });
}
