// 系统级完成提示：热重载 / 热重启结束时弹一条，不论用户当前停在哪个软件里。
//
// 为什么不用页面里的 toast：热重载的典型用法就是「在 IDE 里改完代码按一下热键，
// 眼睛还在编辑器上」，这时页面提示根本没人看。所以走操作系统的通知通道：
//   macOS → osascript 的 display notification（进通知中心，不需要额外授权）
//   Windows → PowerShell + NotifyIcon 托盘气泡（Win10/11 自带，不用装
//             BurntToast，也不需要 AppID / 注册表安装）
// 通知之外还单独响一声：专注模式下通知会被静默吞掉（实测 macOS 上日志有
// Presenting、屏幕上什么都没有），声音不受这个限制，两层至少保证有一层能感知。
// 命令拼装拆成纯函数，单测只验证参数，不真的弹窗。
library;

import 'dart:async';
import 'dart:io';

/// 要交给外部程序执行的一条命令。
class SystemNoticeCommand {
  const SystemNoticeCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

/// 标题 / 正文清洗：换行压成空格，过长截断。
///
/// Windows 气泡的正文超过两三百字符会被系统硬截，截在半个句子里很难看，
/// 所以自己按 200 收；标题更短（气泡标题栏实际只能放一行）。
String cleanNoticeText(String raw, {int max = 200}) {
  var t = raw.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
  t = t.replaceAll(RegExp(r' {2,}'), ' ');
  if (t.length <= max) return t;
  return '${t.substring(0, max - 1)}…';
}

/// AppleScript 双引号字符串字面量（反斜杠与双引号都要转义）。
String appleScriptLiteral(String raw) =>
    '"${raw.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// PowerShell 单引号字符串字面量（内部单引号翻倍，$ 不展开）。
String powerShellLiteral(String raw) => "'${raw.replaceAll("'", "''")}'";

/// 拼「弹一条系统提示」的命令；不支持的平台返回 null。
///
/// [isMacOS] / [isWindows] 显式传入而不是内部读 Platform，单测才能覆盖两套分支。
SystemNoticeCommand? buildNoticeCommand(
  String title,
  String body, {
  required bool isMacOS,
  required bool isWindows,
}) {
  final t = cleanNoticeText(title, max: 80);
  final b = cleanNoticeText(body);
  if (isMacOS) {
    // 不加 sound name：热重载一天可能按几十次，每回响一声太吵。
    return SystemNoticeCommand('osascript', <String>[
      '-e',
      'display notification ${appleScriptLiteral(b)} '
          'with title ${appleScriptLiteral(t)}',
    ]);
  }
  if (isWindows) {
    // 气泡要有个进程撑着显示时间，所以要 Start-Sleep 后再 Dispose。
    final script = '''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
\$n = New-Object System.Windows.Forms.NotifyIcon
\$n.Icon = [System.Drawing.SystemIcons]::Information
\$n.Visible = \$true
\$n.ShowBalloonTip(4000, ${powerShellLiteral(t)}, ${powerShellLiteral(b)}, [System.Windows.Forms.ToolTipIcon]::Info)
Start-Sleep -Milliseconds 4500
\$n.Dispose()
''';
    return SystemNoticeCommand('powershell', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ]);
  }
  return null;
}

/// 提示音命令：与系统通知分开起进程。
///
/// 不是「多余的一下」：专注 / 勿扰模式下系统通知会被系统直接吞掉（日志里
/// 有 Presenting，屏幕上什么都没有），而普通音频播放不受这个管。通知与声音
/// 各起一个进程，静音了还有得看，通知被吞了至少还有得听。
SystemNoticeCommand? buildNoticeSoundCommand({
  required bool isMacOS,
  required bool isWindows,
}) {
  if (isMacOS) {
    return const SystemNoticeCommand(
      'afplay',
      <String>['/System/Library/Sounds/Glass.aiff'],
    );
  }
  if (isWindows) {
    // 进程退出声音会断，所以播完再等 900ms。
    const script = r'''
[System.Media.SystemSounds]::Asterisk.Play()
Start-Sleep -Milliseconds 900
''';
    // script 是 const，整个参数表也能 const 化。
    return const SystemNoticeCommand('powershell', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ]);
  }
  return null;
}

/// 真的弹一条通知 + 响一声：失败一律吞掉。
///
/// 提示只是锦上添花，发不出来（没权限、PowerShell 被策略禁用）绝不能反过来
/// 影响热重载结果，所以这里不 await、不抛错，后台跑完就算。
void showSystemNotice(String title, String body, {bool sound = true}) {
  void fire(SystemNoticeCommand? cmd) {
    if (cmd == null) return;
    unawaited(
      Process.run(cmd.executable, cmd.arguments).then<void>(
        (_) {},
        onError: (Object _) {},
      ),
    );
  }

  fire(buildNoticeCommand(
    title,
    body,
    isMacOS: Platform.isMacOS,
    isWindows: Platform.isWindows,
  ));
  if (!sound) return;
  fire(buildNoticeSoundCommand(
    isMacOS: Platform.isMacOS,
    isWindows: Platform.isWindows,
  ));
}
