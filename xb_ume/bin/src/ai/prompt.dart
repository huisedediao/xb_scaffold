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
    ..writeln('用 xb_ume 自己调试这个 Flutter 项目：能复用就复用，需要启动时自己启动，'
        '不要让我手动跑 app。')
    ..writeln()
    ..writeln('项目：$projectDir')
    ..writeln('设备：$deviceId')
    ..writeln()
    ..writeln('## 第一步：接上 app（复用优先，只做一次）')
    ..writeln('先调 xbume_sessions，按每个会话的 launcher 标记分流：')
    ..writeln('- 带 launcher 标记且标了·可热重载（本工具 / GUI 拉起或认领；我可能已经在「调试」Tab '
        '点过「启动 / 复用」）→ 直接 xbume_use_session 选它，不要 app_launch 重跑；')
    ..writeln('- 带 launcher 标记但标了·只读（认领到的进程拿不到输入句柄）→ 看现场、下断点都能用，'
        '热重载按第三步的回落处理；')
    ..writeln('- 只有这个项目的会话、但没有 launcher 标记（IDE 拉起）→ 先问我要哪种，不要自己选：')
    ..writeln('  (a) 只读接入：xbume_use_session 选它，界面 / 断点 / eval / 时间轴都能用，'
        '改完回 IDE 按 r；')
    ..writeln('  (b) 由 xb_ume 接管：app_launch 加 force: true，会重装包并重启 app，'
        '手机上会顶掉 IDE 的调试会话；')
    ..writeln('- 没有可用会话 → 用 xbume_app_launch 启动，参数：')
    ..writeln(
        '{"deviceId": "$deviceId", "via": "flutter-run", "cwd": "$projectDir"}')
    ..writeln('它会由 xb_ume 启动 flutter run 并把新会话设为当前；'
        '返回 reused=true 表示复用了已有进程（未重装包），这是期望行为，不要因为它再 force 一次。')
    ..writeln('同设备同目录已有 IDE 拉起的 flutter run 时它会拒绝启动并给出 pid：把情况告诉我，'
        '由我选 (a) 还是 (b)。')
    ..writeln()
    ..writeln('## 第二步：按需使用工具')
    ..writeln('- xbume_screenshot / xbume_find_widget / xbume_tap / xbume_input：'
        '看界面、按类型/文字/Key 找组件、点击、输入')
    ..writeln('- xbume_timeline / xbume_exceptions / xbume_network_detail / '
        'xbume_console：复现之后取证（路由+网络+日志+异常按时间合并）')
    ..writeln('- xbume_route_stack / xbume_navigate：看路由栈、push/pop')
    ..writeln('- xbume_scenario_run / xbume_scenario_status：把复现路径存成场景后复跑')
    ..writeln('- 需要看运行时数据时，工具列表里有就用（没有就跳过）：'
        'xbume_debug_breakpoints / xbume_debug_state / xbume_debug_inspect / '
        'xbume_debug_control（断点、单步、调用栈、变量）、xbume_instances / '
        'xbume_widget_tree / xbume_perf、xbume_storage / xbume_db / xbume_sandbox；'
        '后三组走本机 GUI，需要工具箱在跑');
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
    ..writeln('只对带·可热重载标记的会话有效；·只读 会话会直接报错，不要反复重试，'
        '改让那个会话的主人自己重跑（IDE 里按 r），或先问我要不要 force 重启。')
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
