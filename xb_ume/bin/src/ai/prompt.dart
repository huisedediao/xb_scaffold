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
  String instanceName = '',
}) {
  final sb = StringBuffer()
    ..writeln('用 xb_ume 自己调试这个 Flutter 项目：能复用就复用，需要启动时自己启动，'
        '不要让我手动跑 app。')
    ..writeln()
    ..writeln('项目：$projectDir')
    ..writeln('设备：$deviceId');
  if (instanceName.trim().isNotEmpty) {
    sb.writeln('MCP 实例：${instanceName.trim()}');
  }
  sb
    ..writeln()
    ..writeln('## 第零步：先确认「谁在驱动」（同一台机器可能有别的 AI 也在用）')
    ..writeln('会话级写操作（点按 / 输入 / 滑动 / 路由跳转 / eval / 热重载 / 场景回放 / '
        '拉起或停止 app / 断点增删 / 单步）都要先拿「会话租约」：')
    ..writeln('- 空闲时自动拿到，不需要额外调用；')
    ..writeln('- 被占时工具直接报 busy（谁占着、在干什么、还剩多久）——不要重试硬抢：'
        '只读排查照常做（screenshot / find_widget / widget_tree / timeline / '
        'debug_state 都无需租约）；要接管先问我，确认后再 '
        'xbume_lease {"op": "steal", "sessionId": "<会话>"}；')
    ..writeln('- 想看全局：xbume_clients 列出本机所有 MCP 实例与各自占着的会话，'
        'xbume_lease {"op": "status", "sessionId": "<会话>"} 看单条；')
    ..writeln('- 同一个助手可能开了多个窗口连同一个实例（xbume_clients 里「客户端连接 N 个」）：'
        '各自的当前会话互不覆盖，但写同一个 app 仍然排队——busy 里写着 '
        '「（连接 …xxxxxx）」的那份就是另一个窗口的，别当成自己的续期。')
    ..writeln('- 你验证完就把会话让出来：xbume_lease {"op": "release"}'
        '（不释放也会 10 分钟后自动过期）；')
    ..writeln('- 发现别的实例正在驱动同一个 app 时先告诉我，'
        '不要用 force 重启顶掉对方的会话。')
    ..writeln()
    ..writeln('## 第一步：接上 app（复用优先，只做一次）')
    ..writeln('先调 xbume_sessions，按每个会话的 launcher 标记分流（·可热重载 后面括号里就是通道：'
        'signal / stdin / none）：')
    ..writeln('- 带 launcher 标记且标了·可热重载（本工具 / GUI 拉起或认领；我可能已经在「调试」Tab '
        '点过「启动 / 复用」）→ 直接 xbume_use_session 选它，不要 app_launch 重跑；')
    ..writeln('- 带 launcher 标记但标了·只读（没有可用通道：Windows 上拿不到输入句柄、也发不了信号）'
        '→ 看现场、下断点都能用，热重载按第三步的回落处理；')
    ..writeln('- 只有这个项目的会话、但没有 launcher 标记（IDE 拉起）→ 先问我要哪种，不要自己选：')
    ..writeln('  (a) 只读接入：xbume_use_session 选它，界面 / 断点 / eval / 时间轴都能用，'
        '改完回 IDE 按 r；')
    ..writeln('  (b) 由 xb_ume 接管：app_launch 加 force: true，会重装包并重启 app，'
        '手机上会顶掉 IDE 的调试会话；')
    ..writeln('- 没有可用会话 → 用 xbume_app_launch 启动，参数：')
    ..writeln(
        '{"deviceId": "$deviceId", "via": "flutter-run", "cwd": "$projectDir"}')
    ..writeln('启动前先查这个项目有没有具名运行配置：')
    ..writeln(
        '  先调 xbume_app_launch {"cwd": "$projectDir", "listConfigs": true}（只列不启动）；')
    ..writeln('  有配置就按名字选：{"deviceId": "$deviceId", "via": "flutter-run", '
        '"cwd": "$projectDir", "config": "<配置名>"}——入口 / flavor / dart-define / '
        'env / 预启动都按它来，不要自己猜参数；名字写错工具会列出可用名。')
    ..writeln('  只对本次生效的临时参数用 args（如 ["--dart-define=LOG=1"]），'
        '不要把它写进配置；配置与 args 都会记住，下次不传也按它回填。')
    ..writeln('它会由 xb_ume 启动 flutter run 并把新会话设为当前；'
        '返回 reused=true 表示复用了已有进程（未重装包），这是期望行为，不要因为它再 force 一次。')
    ..writeln('同设备同目录已有 IDE 拉起的 flutter run 时它会拒绝启动并给出 pid：把情况告诉我，'
        '由我选 (a) 还是 (b)。')
    ..writeln()
    ..writeln('## 第一步半：接上之后先自检（一次调用，别靠试错）')
    ..writeln('use_session / app_launch 返回后，立刻调：')
    ..writeln('  xbume_session_check {"deviceId": "$deviceId", "cwd": "$projectDir"}')
    ..writeln('一次拿到：VM 通不通、是不是这个项目的这台设备、截图 / 点按 / 读运行时状态能不能用、'
        '热重载走哪条通道（signal / stdin / none），并顺带真发一次重载实测'
        '（没改动时 flutter run 只回 No changes detected，不会扰动 app）。')
    ..writeln('按 verdict 决定下一步：ready 才动手改代码；ready_no_reload 只能只读排查；'
        'degraded 先看 warnings 与 next；wrong_device / wrong_project 立即停手换会话；'
        'stale 用 xbume_sessions {"refresh": true} 重扫或重启 app。')
    ..writeln('不要跳过这一步直接发 hot_reload——通道不通时那是几十秒白等。')
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
    ..writeln('## 第三步：改完代码按改动类型选重载级别（选错会误判「已修复」）')
    ..writeln('① xbume_hot_reload {"mode": "reload"} —— 只改了函数体 / widget / 文案 / 局部逻辑，'
        '状态保留，最快；')
    ..writeln('② xbume_hot_reload {"mode": "restart"} —— 改了 initState / 全局单例 / '
        '路由表初值 / main() 里的初始化顺序：isolate 重建、Dart 状态清空，'
        '但不会重装包、也不会重编原生；')
    ..writeln('③ xbume_app_launch {…, "force": true} —— 进程级重启（等于先点停止再点启动）。'
        '下列任何一种都必须走它，热重载 / 热重启验证不出来：')
    ..writeln('   · pubspec.yaml / 依赖（含 assets、字体、flutter 版本）')
    ..writeln('   · 原生侧（android/ios/ohos/windows/macos 下的 gradle、plist、'
        '权限、插件注册、MethodChannel 原生实现）')
    ..writeln('   · 启动参数（--dart-define / flavor / 入口 target / 环境变量）')
    ..writeln('   · 只在 app 启动那一刻读一次的东西（平台通道注册、首次读配置、'
        '顶层常量与静态初始化）')
    ..writeln('   用法：{"deviceId": "$deviceId", "via": "flutter-run", '
        '"cwd": "$projectDir", "force": true}；'
        '它先按精确 PID 停掉旧会话（含 app 子进程）再重新编译装包启动，'
        '新会话自动设为当前。重启后必须重新走一遍同样的路径再下结论。')
    ..writeln('只对带·可热重载标记的会话有效（工具按通道发：POSIX 上发 SIGUSR1 / SIGUSR2，'
        '不再往管道里写 r 键）；·只读 会话会直接报错，不要反复重试，'
        '改让那个会话的主人自己重跑（IDE 里按 r），或先问我要不要 force 重启。')
    ..writeln('判断不了属于哪一档时按最重的来（force）：宁可多等一次构建，'
        '也不要在旧进程上得出「已修复」的结论。')
    ..writeln('热重载失败时把编译错误原样读出来再改，不要凭猜测绕过。')
    ..writeln()
    ..writeln('## 规则')
    ..writeln('1. 每次只改一处，改完按第三步选对重载级别并复跑同一条路径，'
        '确认是修好还是没修好。')
    ..writeln('2. 定位结论必须落到「文件:行」——xbume_find_widget 返回的 source 字段直接可用。')
    ..writeln('3. 不要改与问题无关的代码，不要顺手重构。')
    ..writeln('4. 验证完释放会话租约（xbume_lease {"op": "release"}），'
        '让其他 AI / 会话能接着用。')
    ..writeln('5. 结束前给一句话结论：问题在哪、改了什么、验证结果（截图为证）。');
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
