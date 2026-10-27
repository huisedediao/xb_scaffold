// 「AI 调试模式」的共用素材：项目校验、设备推荐、给 AI 的指令模板。
//
// 命令（bin/ai.dart）与 GUI「AI 调试」Tab 共用这里，保证两边生成的指令
// 完全一致——用户看到的东西不应该因为入口不同而变。
library;

import 'dart:io';

import '../device/registry.dart';

/// 校验项目目录：必须含 pubspec.yaml，返回绝对路径。
///
/// 抛 [FormatException]（带可读中文），调用方直接展示给用户。
String resolveProjectDir(String raw) {
  final input = raw.trim();
  final dir = input.isEmpty
      ? Directory.current.path
      : Directory(input).absolute.path;
  final pubspec = File('$dir/pubspec.yaml');
  if (!pubspec.existsSync()) {
    throw FormatException('$dir 下没有 pubspec.yaml；'
        '请用 Flutter 项目根目录（包含 pubspec.yaml），'
        '或用 --dir <目录> 指定');
  }
  return dir;
}

/// 推荐设备：唯一 adb/hdc 设备优先，其次本机桌面（macOS / Windows），最后第一台可用设备。
///
/// 返回 null 表示选不出来（多台手机/无任何设备），调用方应让用户显式指定。
Future<String?> guessDevice() async {
  final reg = DeviceRegistry.fromSpec('auto');
  try {
    await reg.warmupAll();
    final devices = await reg.usableDevices();
    final phones =
        devices.where((d) => d.backend == 'adb' || d.backend == 'hdc').toList();
    if (phones.length == 1) return phones.single.id;
    if (phones.length > 1) return null; // 多台手机不替用户猜
    if (Platform.isMacOS) return 'macos';
    // Windows 桌面同样是合法目标（`flutter run -d windows`），与 macOS 对等
    // 优先于「首个可用设备」（可能是状态异常的手机）。
    if (Platform.isWindows) return 'windows';
    if (devices.isNotEmpty) return devices.first.id;
    return null;
  } finally {
    await reg.disposeAll();
  }
}

/// 设备列表（给「选不出来」时提示用）。
Future<List<Map<String, String>>> listDeviceChoices() async {
  final reg = DeviceRegistry.fromSpec('auto');
  try {
    await reg.warmupAll();
    final devices = await reg.usableDevices();
    return devices
        .map((d) => <String, String>{
              'id': d.id,
              'backend': d.backend,
              'platform': d.platform,
            })
        .toList(growable: false);
  } catch (_) {
    return const <Map<String, String>>[];
  } finally {
    await reg.disposeAll();
  }
}

/// 生成「可直接粘给 AI」的指令。
///
/// 设计原则：AI 拿到这段话就能自己跑完全程，不需要用户再解释任何工具名。
/// 项目路径与设备写死在正文里；eval 行按实际是否开启决定出现与否。
String buildAiPrompt({
  required String projectDir,
  required String deviceId,
  required bool hasEval,
}) {
  final sb = StringBuffer()
    ..writeln('用 xb_ume 自己调试这个 Flutter 项目，不要让我手动启动 app。')
    ..writeln()
    ..writeln('项目：$projectDir')
    ..writeln('设备：$deviceId')
    ..writeln()
    ..writeln('## 第一步：接上 app（只做一次）')
    ..writeln('先调 xbume_sessions 看有没有现成会话：')
    ..writeln('- 已列出这个项目的会话 → 停下来问我：复用现有会话（不能热重载），'
        '还是重新拉起（会重启 app，手机上会顶掉 IDE 的调试会话），不要直接启动；')
    ..writeln('- 没有可用会话 → 用 xbume_app_launch 启动，参数：')
    ..writeln(
        '{"deviceId": "$deviceId", "via": "flutter-run", "cwd": "$projectDir"}')
    ..writeln('它会由 xb_ume 启动 flutter run 并把新会话设为当前；'
        '只有这种「自己拉起」的会话才支持后面的热重载。')
    ..writeln('同设备同目录已有 flutter run 时它会拒绝启动并给出 pid：把情况告诉我，'
        '由我决定复用还是加 force: true。')
    ..writeln()
    ..writeln('## 第二步：按需使用工具')
    ..writeln('- xbume_screenshot / xbume_find_widget / xbume_tap / xbume_input：'
        '看界面、按类型/文字/Key 找组件、点击、输入')
    ..writeln('- xbume_timeline / xbume_exceptions / xbume_network_detail / '
        'xbume_console：复现之后取证（路由+网络+日志+异常按时间合并）')
    ..writeln('- xbume_route_stack / xbume_navigate：看路由栈、push/pop')
    ..writeln('- xbume_scenario_run / xbume_scenario_status：把复现路径存成场景后复跑');
  if (hasEval) {
    sb.writeln('- xbume_eval {"expr": "<单行 Dart 表达式>"}：在 app 进程内求值，'
        '用来验证「这个字段到底是什么值」；能读也能改，改完记得说明改了什么');
  }
  sb
    ..writeln()
    ..writeln('## 第三步：改完代码就热重载')
    ..writeln('xbume_hot_reload {"mode": "reload"} —— 改了 widget/文案/局部逻辑用它；')
    ..writeln('xbume_hot_reload {"mode": "restart"} —— 改了初始化逻辑、全局状态、'
        'main() 用它（isolate 会重建，之前的缓存自动清掉）。')
    ..writeln('热重载失败时把编译错误原样读出来再改，不要凭猜测绕过。')
    ..writeln()
    ..writeln('## 规则')
    ..writeln('1. 每次只改一处，改完立刻热重载并复跑同一条路径，确认是修好还是没修好。')
    ..writeln('2. 定位结论必须落到「文件:行」——xbume_find_widget 返回的 source 字段直接可用。')
    ..writeln('3. 不要改与问题无关的代码，不要顺手重构。')
    ..writeln('4. 结束前给一句话结论：问题在哪、改了什么、验证结果（截图为证）。');
  return sb.toString();
}

/// 客户端 MCP 配置（HTTP 模式，带 token）。
String aiClientConfig({required String url, required String token}) {
  final headers =
      token.isEmpty ? '' : ',\n      "headers": {"X-XBUME-Token": "$token"}';
  return '{\n'
      '  "mcpServers": {\n'
      '    "xb_ume": {\n'
      '      "type": "http",\n'
      '      "url": "$url"$headers\n'
      '    }\n'
      '  }\n'
      '}';
}
