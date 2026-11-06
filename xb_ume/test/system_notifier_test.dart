// 系统通知的命令拼装：只断言参数与转义，绝不真的弹窗（跑测试时不该有通知）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/notify/system_notifier.dart';

void main() {
  group('macOS', () {
    test('走 osascript 的 display notification，标题正文都进参数', () {
      final c = buildNoticeCommand(
        '热重载完成',
        'HomePage（320ms）',
        isMacOS: true,
        isWindows: false,
      );
      expect(c, isNotNull);
      expect(c!.executable, 'osascript');
      expect(c.arguments.first, '-e');
      final script = c.arguments.last;
      expect(script, startsWith('display notification '));
      expect(script, contains('"HomePage（320ms）"'));
      expect(script, contains('with title "热重载完成"'));
      // 不加 sound name：热重载一天按几十次，响一声太吵
      expect(script, isNot(contains('sound name')));
    });

    test('正文里的双引号 / 反斜杠被转义，不会破坏脚本', () {
      final c = buildNoticeCommand(
        r'说 "好" 的 \ 路径',
        r'done: C:\tmp\a "b"',
        isMacOS: true,
        isWindows: false,
      );
      final script = c!.arguments.last;
      expect(script, contains(r'\"好\"'));
      expect(script, contains(r'C:\\tmp\\a \"b\"'));
      // 未转义的裸双引号只应出现在字符串边界（4 处：正文 + 标题各一对）
      expect(RegExp(r'(?<!\\)"').allMatches(script).length, 4);
    });
  });

  group('Windows', () {
    test('走 PowerShell + NotifyIcon 气泡（不依赖第三方模块）', () {
      final c = buildNoticeCommand(
        '热重启完成',
        "HomePage · 用时 510ms",
        isMacOS: false,
        isWindows: true,
      );
      expect(c, isNotNull);
      expect(c!.executable, 'powershell');
      expect(c.arguments, contains('-NoProfile'));
      expect(c.arguments, contains('-NonInteractive'));
      final script = c.arguments.last;
      expect(script, contains('System.Windows.Forms.NotifyIcon'));
      expect(script, contains('ShowBalloonTip'));
      expect(script, contains("'热重启完成'"));
      expect(script, contains("'HomePage · 用时 510ms'"));
      // 气泡要撑住显示时间，进程不能立刻退出
      expect(script, contains('Start-Sleep'));
      expect(script, contains('Dispose'));
    });

    test('单引号翻倍（PowerShell 里不展开变量）', () {
      final c = buildNoticeCommand(
        "it's done",
        r'$env:PATH 里',
        isMacOS: false,
        isWindows: true,
      );
      final script = c!.arguments.last;
      expect(script, contains("'it''s done'"));
      expect(script, contains(r"'$env:PATH 里'"));
    });
  });

  test('其他平台不弹（return null，不抛）', () {
    expect(
      buildNoticeCommand('t', 'b', isMacOS: false, isWindows: false),
      isNull,
    );
    expect(
      buildNoticeSoundCommand(isMacOS: false, isWindows: false),
      isNull,
    );
  });

  group('提示音', () {
    test('macOS 用 afplay 播系统 Glass，另起进程不受通知权限管', () {
      // 专注模式下通知会被系统吞掉（日志有 Presenting、屏幕没东西），
      // 普通音频播放不会被静默，所以声音是第二道保险。
      final c = buildNoticeSoundCommand(isMacOS: true, isWindows: false);
      expect(c, isNotNull);
      expect(c!.executable, 'afplay');
      expect(c.arguments.single, '/System/Library/Sounds/Glass.aiff');
    });

    test('Windows 用 SystemSounds，播完等一会儿再退', () {
      final c = buildNoticeSoundCommand(isMacOS: false, isWindows: true);
      expect(c!.executable, 'powershell');
      final script = c.arguments.last;
      expect(script, contains('SystemSounds'));
      expect(script, contains('Play()'));
      expect(script, contains('Start-Sleep'));
    });
  });

  group('正文清洗', () {
    test('换行 / 制表符压成空格，连续空格并一个', () {
      expect(cleanNoticeText('a\nb\t\tc   d'), 'a b c d');
      expect(cleanNoticeText('  \n 完成 \n'), '完成');
    });

    test('超长正文截断并加省略号（Windows 气泡会硬截）', () {
      final long = 'x' * 500;
      final t = cleanNoticeText(long);
      expect(t.length, 200);
      expect(t.endsWith('…'), isTrue);
      // 标题更短
      expect(cleanNoticeText(long, max: 80).length, 80);
    });
  });
}
