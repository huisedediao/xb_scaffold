// xb_ume AI 调试模式：一条命令把环境准备好，并生成可直接粘给 AI 的指令。
//
// 用法（在 Flutter 项目根目录执行）：
//   dart run xb_ume:ai
//   dart run xb_ume:ai -d macos
//   dart run xb_ume:ai --dir ../my_app --device emulator-5554
//
// 它做三件事（都是之前要手工点的）：
//   1. 起一个带 --allow-eval 的 MCP HTTP 服务（已在跑且状态一致就复用）；
//   2. 推断项目路径与设备，写进指令；
//   3. 打印客户端配置 + 指令，并把指令复制到剪贴板。
//
// 它**不**拉起 app：拉起由 AI 调 xbume_app_launch 完成，这样 MCP 进程才握着
// flutter run 的 stdin，后续 xbume_hot_reload 才能用。
library;

import 'dart:convert';
import 'dart:io';

import 'src/ai/prompt.dart';
import 'src/mcp/host.dart';

const String _usage = '''
xb_ume AI 调试模式

用法：
  dart run xb_ume:ai [选项]          # 在 Flutter 项目根目录执行

选项：
  --dir, -C <path>     项目目录（默认当前目录，必须含 pubspec.yaml）
  --device, -d <id>    设备 id（默认自动：唯一手机 > macOS 桌面）
  --print-only         只生成指令，不启动/不检查 MCP 服务
  --json               输出 JSON（给脚本用）
  -h, --help           显示帮助

它会启动（或复用）带 xbume_eval 的 MCP 服务，并生成一段指令；
把指令粘给 AI，AI 会自己 xbume_app_launch 拉起 app 并完成调试闭环。
''';

class _Args {
  String dir = '';
  String device = '';
  bool printOnly = false;
  bool json = false;
  bool help = false;
}

_Args _parse(List<String> argv) {
  final a = _Args();
  for (var i = 0; i < argv.length; i++) {
    final s = argv[i];
    switch (s) {
      case '-h' || '--help':
        a.help = true;
      case '--print-only':
        a.printOnly = true;
      case '--json':
        a.json = true;
      case '--dir' || '-C':
        if (i + 1 >= argv.length) throw const FormatException('--dir 缺少参数');
        a.dir = argv[++i];
      case '--device' || '-d':
        if (i + 1 >= argv.length) throw const FormatException('--device 缺少参数');
        a.device = argv[++i];
      default:
        if (s.startsWith('-')) {
          throw FormatException('未知参数：$s（用 --help 看用法）');
        }
        // 位置参数当作项目目录，方便 `dart run xb_ume:ai ../app`。
        if (a.dir.isEmpty) a.dir = s;
    }
  }
  return a;
}

Future<void> main(List<String> argv) async {
  _Args args;
  try {
    args = _parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('[xb_ume] ${e.message}');
    stderr.writeln(_usage);
    exit(2);
  }
  if (args.help) {
    stdout.writeln(_usage);
    return;
  }

  try {
    final projectDir = resolveProjectDir(args.dir);

    var device = args.device.trim();
    if (device.isEmpty) {
      device = await guessDevice() ?? '';
    }
    if (device.isEmpty) {
      final choices = await listDeviceChoices();
      final lines = StringBuffer('[xb_ume] 无法自动选择设备（有多台或没有可用设备）。\n');
      if (choices.isNotEmpty) {
        lines.writeln('可选设备：');
        for (final d in choices) {
          lines.writeln('  ${d['id']}  (${d['backend']} · ${d['platform']})');
        }
      } else {
        lines.writeln('没有检测到可用设备：先连手机（adb/hdc）或确认 macOS 桌面可用。');
      }
      lines.write('用 --device <id> 指定。');
      stderr.writeln(lines.toString());
      exit(2);
    }

    Map<String, Object?> mcp;
    if (args.printOnly) {
      mcp = await McpHost().probe();
    } else {
      mcp = await McpHost().ensure(allowEval: true);
    }
    final hasEval = mcp['hasEval'] == true;
    final url = '${mcp['url'] ?? 'http://127.0.0.1:$kDefaultMcpPort/mcp'}';
    final token = mcp['running'] == true ? McpHost().token : '';

    final prompt = buildAiPrompt(
      projectDir: projectDir,
      deviceId: device,
      hasEval: hasEval,
    );
    final config = aiClientConfig(url: url, token: token);

    final copied =
        args.printOnly ? false : await _copyToClipboard(prompt);

    if (args.json) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'ok': true,
        'projectDir': projectDir,
        'deviceId': device,
        'mcp': mcp,
        'prompt': prompt,
        'config': config,
        'copied': copied,
      }));
      return;
    }

    final b = StringBuffer()
      ..writeln('[xb_ume] AI 调试模式'
          '${args.printOnly ? '（仅生成指令，未改动服务）' : '已就绪'}'
          '${mcp['running'] == true ? '（${mcp['toolCount']} 个工具，'
              'eval ${hasEval ? '已开' : '未开'}）' : ''}')
      ..writeln()
      ..writeln('  项目：$projectDir')
      ..writeln('  设备：$device');
    if (mcp['running'] == true) {
      b
        ..writeln('  服务：$url')
        ..writeln('  日志：${McpHost().home}/logs/mcp.log');
      if (!args.printOnly && !hasEval) {
        b.writeln('  注意：服务已启动但 eval 没开，请把启动命令里加上 --allow-eval');
      }
    }
    b
      ..writeln()
      ..writeln('① 首次使用：把下面这段加到 Qoder / Cursor 的 MCP Servers（只需一次）')
      ..writeln(config)
      ..writeln()
      ..writeln('② 每次调试：把下面这段粘给 AI'
          '${copied ? '（已复制到剪贴板）' : ''}')
      ..writeln('─' * 60)
      ..writeln(prompt)
      ..writeln('─' * 60);
    stdout.writeln(b.toString());
  } on FormatException catch (e) {
    stderr.writeln('[xb_ume] ${e.message}');
    exit(2);
  } on StateError catch (e) {
    stderr.writeln('[xb_ume] ${e.message}');
    exit(2);
  }
}

/// 把文本放进系统剪贴板；失败返回 false（只影响提示语，不影响功能）。
Future<bool> _copyToClipboard(String text) async {
  try {
    final (String cmd, List<String> args) = Platform.isMacOS
        ? ('pbcopy', const <String>[])
        : Platform.isWindows
            ? ('clip', const <String>[])
            : ('xclip', const <String>['-selection', 'clipboard']);
    final p = await Process.start(cmd, args);
    p.stdin.write(text);
    await p.stdin.close();
    return await p.exitCode == 0;
  } catch (_) {
    return false;
  }
}
