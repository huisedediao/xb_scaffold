// 设备类 MCP 工具（P2）：后端发现、app 起停装、按键/原生点击、崩溃日志。
//
// 与 VM 侧工具的分工：
//   - 这里的操作走进程外后端（adb / hdc / simctl / idevice / flutter run），
//     不依赖 app 处于 debug 且已连上 VM service；
//   - 不支持的能力返回 structured.unsupported（不是异常），让模型自行改道。
library;

import 'dart:io';

import '../device/bridge.dart';
import 'protocol.dart';
import 'tools.dart';

/// 全部设备类工具（由分组过滤决定最终暴露哪些）。
List<McpTool> deviceTools() => <McpTool>[
      _devicesTool(),
      _appLaunchTool(),
      _appInstallTool(),
      _appUninstallTool(),
      _appTerminateTool(),
      _pressKeyTool(),
      _nativeTapTool(),
      _keepAwakeTool(),
      _crashListTool(),
      _crashGetTool(),
    ];

/// 本机桌面设备在 `flutter devices` 里的名字（macOS：macos / Windows：windows）。
final String _desktopDevice = Platform.isWindows ? 'windows' : 'macos';

Map<String, Object?> _deviceIdProp({String extra = ''}) => prop(
      'string',
      '设备 id（xbume_devices 返回的 id：Android 序列号 / iOS UDID / hdc connect key；'
          'flutter-run 模式下用 flutter 设备名，如 $_desktopDevice）$extra',
    );

/// 把后端异常统一转成结构化结果。
McpToolResult _unsupported(DeviceUnsupported e) => McpToolResult.text(
      '该后端不支持 ${e.capability.name}：${e.reason}',
      structured: <String, Object?>{
        'ok': false,
        'unsupported': true,
        'backend': e.backend,
        'capability': e.capability.name,
        'reason': e.reason,
      },
    );

Never _fail(DeviceCommandError e) =>
    throw McpToolException(e.message, hint: '命令：${e.command}');

/// 解析并校验设备存在；找不到时给可操作提示。
Future<(DeviceBridge, DeviceInfo)> _requireDevice(
  McpToolContext ctx,
  Map<String, Object?> args, {
  String? backend,
}) async {
  final id = requireString(args, 'deviceId', hint: '先调用 xbume_devices 查看可用设备');
  final hit = await ctx.devices.resolve(id, backend: backend);
  if (hit == null) {
    final known =
        (await ctx.devices.listDevices()).map((d) => '${d.id}(${d.backend})');
    throw McpToolException(
      '设备 $id 未找到${known.isEmpty ? '' : '，可用：${known.join(', ')}'}',
      hint: '先调用 xbume_devices；Android 需开启 USB 调试，iOS 模拟器需已启动',
    );
  }
  return hit;
}

McpTool _devicesTool() => McpTool(
      name: 'xbume_devices',
      title: '列出可用设备与后端能力',
      description: '返回各后端（adb/hdc/simctl/idevice/mobile-mcp）的可用性、能力矩阵，'
          '以及已连接设备清单；不可用后端会带 reason。',
      group: ToolGroup.diagnose,
      inputSchema: toolSchema(<String, Object?>{
        'refresh': prop('boolean', '保留参数（每次都实时探测）', defaultValue: false),
      }),
      handler: (ctx, args) async {
        // 适配器类后端需要先握手，否则首次调用看不到能力与设备。
        await ctx.devices.warmupAll();
        final devices = await ctx.devices.listDevices();
        final backends = ctx.devices.backendsJson();
        final live = ctx.launcher.live;
        final sb = StringBuffer();
        for (final b in backends) {
          final ok = b['available'] == true;
          sb.write('${ok ? '✓' : '✗'} ${b['name']}'
              '${ok ? ' · ${(b['capabilities'] as List).length} 项能力' : ' · ${b['reason'] ?? '不可用'}'}\n');
        }
        if (ctx.devices.bridgeOf('mobile-mcp') == null) {
          sb.write('· mobile-mcp 适配器未启用（可选，需 Node/npx）：'
              '--device-backend adb,mobile-mcp\n');
        }
        if (devices.isEmpty) {
          sb.write('没有已连接设备。Android 打开 USB 调试；iOS 用 xcrun simctl boot 启动模拟器。');
        } else {
          for (final d in devices) {
            sb.write(
                '${d.usable ? '▶' : '·'} ${d.id} · ${d.platform} · ${d.name} · ${d.state}'
                '（${d.backend}）\n');
          }
        }
        if (live.isNotEmpty) {
          sb.write('flutter run 进程：');
          sb.write(live.map((h) => '${h.pid}@${h.device}').join(', '));
        }
        return McpToolResult.text(sb.toString().trimRight(),
            structured: <String, Object?>{
              'backends': backends,
              'count': devices.length,
              'devices': devices.map((d) => d.toJson()).toList(growable: false),
              'launchPids': live
                  .map((h) => <String, Object?>{
                        'pid': h.pid,
                        'device': h.device,
                        'target': h.target,
                        'wsUri': h.wsUri,
                      })
                  .toList(growable: false),
            });
      },
    );

McpTool _appLaunchTool() => McpTool(
      name: 'xbume_app_launch',
      title: '启动 app 并可选等待调试会话',
      description: 'via=flutter-run（默认）会执行 flutter run 并用解析到的 VM service '
          '自动选为当前会话；同设备同目录已有存活会话时直接复用（不重装包）。'
          'via=adb/simctl/hdc 只启动已安装的包（需要 packageId）。',
      group: ToolGroup.core,
      inputSchema: toolSchema(<String, Object?>{
        'deviceId': _deviceIdProp(extra: '；via=flutter-run 时可用 $_desktopDevice'),
        'via': prop('string', 'flutter-run | adb | simctl | hdc',
            defaultValue: 'flutter-run'),
        'packageId': prop(
            'string', '已安装包名（via=adb/simctl/hdc 必填；hdc 支持 bundle#Ability）'),
        'target': prop('string', '入口文件（flutter-run，默认 lib/main.dart）'),
        'cwd': prop('string', 'flutter run 的工作目录（默认 MCP 服务进程的当前目录）'),
        'waitVm': prop('boolean', '是否等待 VM service（flutter-run 默认 true）',
            defaultValue: true),
        'force': prop('boolean',
            '是否强制重启：先停掉同设备同目录由本服务/GUI 拉起的会话再重新拉起（会重装包；异于复用）',
            defaultValue: false),
        'timeoutMs': prop('integer', '等待超时（毫秒）', defaultValue: 180000),
      }, <String>[
        'deviceId'
      ]),
      handler: (ctx, args) async {
        final deviceId = requireString(args, 'deviceId',
            hint: '先调用 xbume_devices；桌面可用 $_desktopDevice');
        final via =
            (optionalString(args, 'via') ?? 'flutter-run').toLowerCase();
        final timeout = Duration(
            milliseconds:
                (optionalInt(args, 'timeoutMs') ?? 180000).clamp(5000, 600000));

        if (via == 'flutter-run') {
          try {
            final r = await ctx.launcher.launch(
              device: deviceId,
              target: optionalString(args, 'target'),
              cwd: optionalString(args, 'cwd'),
              waitVm: optionalBool(args, 'waitVm', fallback: true),
              force: optionalBool(args, 'force'),
              owner: 'mcp',
              timeout: timeout,
            );
            String? sessionId;
            if (r.wsUri != null) {
              final s = ctx.sessions.addManual(r.wsUri!);
              sessionId = s.id;
            }
            final action = r.reused ? '复用已有 flutter run' : '已启动 flutter run';
            return McpToolResult.text(
              sessionId == null
                  ? '$action（pid ${r.pid}），未拿到 VM service；日志 ${r.logPath}'
                  : '$action（pid ${r.pid}）并通过临时会话 $sessionId 接入'
                      '${r.reused ? '（未重装包）' : ''}',
              structured: <String, Object?>{
                'ok': true,
                'via': via,
                'pid': r.pid,
                'deviceId': deviceId,
                'wsUri': r.wsUri,
                'sessionId': sessionId,
                'logPath': r.logPath,
                'reused': r.reused,
              },
            );
          } on DeviceCommandError catch (e) {
            _fail(e);
          }
        }

        // adb / simctl / hdc：启动已安装的包。
        final packageId = optionalString(args, 'packageId');
        if (packageId == null || packageId.isEmpty) {
          throw McpToolException('via=$via 需要 packageId（已安装的包名）',
              hint: '例如 com.example.app；不确定可用 adb shell pm list packages 查看');
        }
        final bridge = ctx.devices.bridgeOf(via);
        if (bridge == null || !bridge.available) {
          throw McpToolException('后端 $via 不可用',
              hint: '调用 xbume_devices 查看可用后端与原因');
        }
        try {
          final detail = bridge.launch(deviceId, packageId);
          final info = await detail;
          String? sessionId;
          if (optionalBool(args, 'waitVm', fallback: true)) {
            sessionId = await _waitSessionFor(ctx, deviceId, timeout);
          }
          return McpToolResult.text(
            '已通过 $via 启动 $packageId（$info）'
            '${sessionId == null ? '；未发现调试会话（release 包无法操作）' : '；会话 $sessionId'}',
            structured: <String, Object?>{
              'ok': true,
              'via': via,
              'deviceId': deviceId,
              'packageId': packageId,
              'detail': info,
              'sessionId': sessionId,
            },
          );
        } on DeviceUnsupported catch (e) {
          return _unsupported(e);
        } on DeviceCommandError catch (e) {
          _fail(e);
        }
      },
    );

/// 轮询扫描，等设备上的 debug 会话出现。
Future<String?> _waitSessionFor(
  McpToolContext ctx,
  String deviceId,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final list = await ctx.sessions.refresh(force: true);
    for (final s in list) {
      if (s.deviceId == null ||
          s.deviceId == deviceId ||
          s.deviceId!.endsWith(deviceId)) {
        ctx.sessions.use(s.id);
        return s.id;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return null;
}

McpTool _appInstallTool() => McpTool(
      name: 'xbume_app_install',
      title: '安装安装包到设备',
      description: '校验后缀（.apk/.ipa/.app/.hap）后调用对应后端安装。',
      group: ToolGroup.deviceWrite,
      inputSchema: toolSchema(<String, Object?>{
        'deviceId': _deviceIdProp(),
        'artifact': prop('string', '安装包绝对路径（.apk/.ipa/.app/.hap）'),
      }, <String>[
        'deviceId',
        'artifact'
      ]),
      handler: (ctx, args) async {
        final artifact = requireString(args, 'artifact', hint: '传安装包的绝对路径');
        final f = File(artifact);
        if (!f.existsSync()) {
          throw McpToolException('安装包不存在：$artifact');
        }
        final ext = artifact.toLowerCase();
        const allowed = <String>['.apk', '.ipa', '.app', '.hap'];
        if (!allowed.any(ext.endsWith)) {
          throw McpToolException('不支持的安装包类型：$artifact',
              hint: '支持 ${allowed.join(' / ')}');
        }
        final (bridge, device) = await _requireDevice(ctx, args);
        if (!bridge.supports(DeviceCapability.install)) {
          return _unsupported(DeviceUnsupported(
              DeviceCapability.install, bridge.backend, '该后端未声明 install 能力'));
        }
        try {
          await bridge.install(device.id, artifact);
          return McpToolResult.text(
            '已安装 $artifact → ${device.id}（${bridge.backend}）',
            structured: <String, Object?>{
              'ok': true,
              'deviceId': device.id,
              'backend': bridge.backend,
              'artifact': artifact,
            },
          );
        } on DeviceCommandError catch (e) {
          _fail(e);
        }
      },
    );

McpTool _appUninstallTool() => McpTool(
      name: 'xbume_app_uninstall',
      title: '卸载设备上的 app（高危）',
      description: '高危写操作：必须显式传 confirm=true，否则拒绝执行。',
      group: ToolGroup.deviceWrite,
      inputSchema: toolSchema(<String, Object?>{
        'deviceId': _deviceIdProp(),
        'packageId': prop('string', '包名 / bundle id（hdc 可用 bundle#Ability）'),
        'confirm': prop('boolean', '必须为 true 才会执行', defaultValue: false),
      }, <String>[
        'deviceId',
        'packageId'
      ]),
      handler: (ctx, args) async {
        final packageId = requireString(args, 'packageId');
        final confirm = optionalBool(args, 'confirm');
        final (bridge, device) = await _requireDevice(ctx, args);
        if (!confirm) {
          throw McpToolException(
            '高危操作需 confirm=true：将卸载 ${device.id} 上的 $packageId',
            hint: '确认无误后重试并传 confirm=true',
          );
        }
        if (!bridge.supports(DeviceCapability.uninstall)) {
          return _unsupported(DeviceUnsupported(DeviceCapability.uninstall,
              bridge.backend, '该后端未声明 uninstall 能力'));
        }
        try {
          await bridge.uninstall(device.id, packageId);
          return McpToolResult.text(
            '已卸载 $packageId ← ${device.id}（${bridge.backend}）',
            structured: <String, Object?>{
              'ok': true,
              'deviceId': device.id,
              'packageId': packageId,
              'backend': bridge.backend,
            },
          );
        } on DeviceCommandError catch (e) {
          _fail(e);
        }
      },
    );

McpTool _appTerminateTool() => McpTool(
      name: 'xbume_app_terminate',
      title: '停止设备上的 app（高危）',
      description: '高危写操作：必须显式传 confirm=true。支持按 pid 停止由 '
          'xbume_app_launch(via: flutter-run) 启动的进程。',
      group: ToolGroup.deviceWrite,
      inputSchema: toolSchema(<String, Object?>{
        'deviceId': _deviceIdProp(extra: '；按 pid 停止时可省略'),
        'packageId': prop('string', '包名 / bundle id（按 pid 停止时可省略）'),
        'pid': prop('integer', 'flutter run 进程 pid（xbume_app_launch 返回）'),
        'confirm': prop('boolean', '必须为 true 才会执行', defaultValue: false),
      }),
      handler: (ctx, args) async {
        final pid = optionalInt(args, 'pid');
        final packageId = optionalString(args, 'packageId');
        if (pid == null && (packageId == null || packageId.isEmpty)) {
          throw McpToolException('需要 pid 或 packageId 之一');
        }
        if (!optionalBool(args, 'confirm')) {
          final target = pid != null ? '进程 $pid' : '$packageId';
          final where = args['deviceId'] == null ? '' : ' @${args['deviceId']}';
          throw McpToolException(
            '高危操作需 confirm=true：将停止 $target$where',
            hint: '确认无误后重试并传 confirm=true',
          );
        }
        if (pid != null) {
          final r = await ctx.launcher.stop(pid);
          if (!r.stopped) {
            throw McpToolException('进程 $pid 已不存在或无法结束',
                hint: '用 xbume_devices 的 launchPids 查看在跑的 flutter run');
          }
          final extra =
              r.children.isEmpty ? '' : '，并结束子进程 ${r.children.join(',')}';
          return McpToolResult.text('已停止 pid $pid$extra',
              structured: <String, Object?>{
                'ok': true,
                'pid': pid,
                'children': r.children,
              });
        }
        final (bridge, device) = await _requireDevice(ctx, args);
        if (!bridge.supports(DeviceCapability.terminate)) {
          return _unsupported(DeviceUnsupported(DeviceCapability.terminate,
              bridge.backend, '该后端未声明 terminate 能力'));
        }
        try {
          await bridge.terminate(device.id, packageId!);
          return McpToolResult.text(
            '已停止 $packageId @ ${device.id}（${bridge.backend}）',
            structured: <String, Object?>{
              'ok': true,
              'deviceId': device.id,
              'packageId': packageId,
              'backend': bridge.backend,
            },
          );
        } on DeviceCommandError catch (e) {
          _fail(e);
        }
      },
    );

McpTool _pressKeyTool() => McpTool(
      name: 'xbume_press_key',
      title: '向设备发送按键',
      description: '走设备后端注入按键（back/home/enter/tab/menu/appSwitch/音量/电源 等）。',
      group: ToolGroup.act,
      inputSchema: toolSchema(<String, Object?>{
        'deviceId': _deviceIdProp(),
        'key': prop(
            'string', '按键名：${DeviceKey.values.map((e) => e.name).join(' / ')}'),
      }, <String>[
        'deviceId',
        'key'
      ]),
      handler: (ctx, args) async {
        final raw = requireString(args, 'key');
        final key = parseDeviceKey(raw);
        if (key == null) {
          throw McpToolException('未知按键 $raw',
              hint: '可用：${DeviceKey.values.map((e) => e.name).join(', ')}');
        }
        final (bridge, device) = await _requireDevice(ctx, args);
        if (!bridge.supports(DeviceCapability.pressKey)) {
          return _unsupported(DeviceUnsupported(
              DeviceCapability.pressKey, bridge.backend, '该后端未声明 pressKey 能力'));
        }
        try {
          await bridge.pressKey(device.id, key);
          return McpToolResult.text('已发送 ${key.name} → ${device.id}',
              structured: <String, Object?>{
                'ok': true,
                'key': key.name,
                'deviceId': device.id
              });
        } on DeviceCommandError catch (e) {
          _fail(e);
        }
      },
    );

McpTool _keepAwakeTool() => McpTool(
      name: 'xbume_keep_awake',
      title: '调试期间保持屏幕常亮',
      description: '防止手机在长场景 / AI 循环中途熄屏（鸿蒙系统「休眠」最多 10 分钟）。'
          'hdc：power-shell timeout -o 2147483647 覆盖熄屏时间，手机或 powermgr 重启后失效；'
          'adb：svc power stayon true，只在充电时生效，拔线自动恢复。'
          '只改运行时状态，不写系统设置、不需要 root；用完传 on: false 恢复。iOS 后端没有等价命令。',
      group: ToolGroup.act,
      inputSchema: toolSchema(<String, Object?>{
        'deviceId': _deviceIdProp(),
        'on': prop('boolean', 'true 保持常亮（默认）/ false 恢复系统熄屏',
            defaultValue: true),
      }, <String>['deviceId']),
      handler: (ctx, args) async {
        final on = optionalBool(args, 'on', fallback: true);
        final (bridge, device) = await _requireDevice(ctx, args);
        if (!bridge.supports(DeviceCapability.keepAwake)) {
          return _unsupported(DeviceUnsupported(DeviceCapability.keepAwake,
              bridge.backend, '该后端未声明 keepAwake 能力'));
        }
        try {
          final msg = await bridge.keepAwake(device.id, on);
          return McpToolResult.text(
              '${on ? '已开启' : '已恢复'}屏幕常亮：$msg（${device.id}）',
              structured: <String, Object?>{
                'ok': true,
                'deviceId': device.id,
                'backend': bridge.backend,
                'on': on,
                'detail': msg,
              });
        } on DeviceCommandError catch (e) {
          _fail(e);
        }
      },
    );

McpTool _nativeTapTool() => McpTool(
      name: 'xbume_native_tap',
      title: '设备原生坐标点击',
      description: '通过设备后端注入点击（adb/hdc）。坐标为屏幕物理像素；'
          'Flutter 界面内的点击优先用 xbume_tap（ref 更稳）。',
      group: ToolGroup.act,
      inputSchema: toolSchema(<String, Object?>{
        'deviceId': _deviceIdProp(),
        'x': prop('number', 'X 坐标（物理像素）'),
        'y': prop('number', 'Y 坐标（物理像素）'),
      }, <String>[
        'deviceId',
        'x',
        'y'
      ]),
      handler: (ctx, args) async {
        final x = (args['x'] as num?)?.toInt();
        final y = (args['y'] as num?)?.toInt();
        if (x == null || y == null) {
          throw McpToolException('需要数值 x / y');
        }
        final (bridge, device) = await _requireDevice(ctx, args);
        if (!bridge.supports(DeviceCapability.tapNative)) {
          return _unsupported(DeviceUnsupported(DeviceCapability.tapNative,
              bridge.backend, '该后端未声明 tapNative 能力'));
        }
        try {
          await bridge.tapNative(device.id, x, y);
          return McpToolResult.text('已点击 ($x,$y) → ${device.id}',
              structured: <String, Object?>{
                'ok': true,
                'x': x,
                'y': y,
                'deviceId': device.id,
              });
        } on DeviceCommandError catch (e) {
          _fail(e);
        }
      },
    );

McpTool _crashListTool() => McpTool(
      name: 'xbume_crash_list',
      title: '列出设备崩溃记录',
      description: 'Android 走 logcat crash 缓冲区；iOS 模拟器读 DiagnosticReports；'
          '真机走 idevicecrashreport（取决于本机工具）。',
      group: ToolGroup.diagnose,
      inputSchema: toolSchema(<String, Object?>{
        'deviceId': _deviceIdProp(),
        'packageId': prop('string', '只看该包的崩溃'),
        'limit': prop('integer', '最多返回条数（默认 10）', defaultValue: 10),
      }, <String>[
        'deviceId'
      ]),
      handler: (ctx, args) async {
        final limit = (optionalInt(args, 'limit') ?? 10).clamp(1, 100);
        final packageId = optionalString(args, 'packageId');
        final (bridge, device) = await _requireDevice(ctx, args);
        if (!bridge.supports(DeviceCapability.crashList)) {
          return _unsupported(DeviceUnsupported(DeviceCapability.crashList,
              bridge.backend, '该后端未声明 crashList 能力'));
        }
        try {
          final list = await bridge.crashList(device.id,
              packageId: packageId, limit: limit);
          final sb = StringBuffer();
          if (list.isEmpty) {
            sb.write('没有崩溃记录（${bridge.backend} / ${device.id}）');
          } else {
            for (final c in list) {
              sb.write('${c.id} · ${c.package ?? '-'} · '
                  '${c.time?.toIso8601String() ?? '-'} · ${c.summary}\n');
            }
          }
          return McpToolResult.text(sb.toString().trimRight(),
              structured: <String, Object?>{
                'count': list.length,
                'backend': bridge.backend,
                'deviceId': device.id,
                'items': list.map((c) => c.toJson()).toList(growable: false),
              });
        } on DeviceCommandError catch (e) {
          _fail(e);
        }
      },
    );

McpTool _crashGetTool() => McpTool(
      name: 'xbume_crash_get',
      title: '读取单条崩溃详情',
      description: '按 xbume_crash_list 返回的 id 取原始日志（超长会截断到 64KB）。',
      group: ToolGroup.diagnose,
      inputSchema: toolSchema(<String, Object?>{
        'deviceId': _deviceIdProp(),
        'crashId': prop('string', '崩溃 id（xbume_crash_list 返回）'),
      }, <String>[
        'deviceId',
        'crashId'
      ]),
      handler: (ctx, args) async {
        final crashId = requireString(args, 'crashId');
        final (bridge, device) = await _requireDevice(ctx, args);
        if (!bridge.supports(DeviceCapability.crashGet)) {
          return _unsupported(DeviceUnsupported(
              DeviceCapability.crashGet, bridge.backend, '该后端未声明 crashGet 能力'));
        }
        try {
          final raw = await bridge.crashGet(device.id, crashId);
          const max = 64 * 1024;
          final text = raw.length <= max
              ? raw
              : '${raw.substring(0, max)}\n…（已截断，原长 ${raw.length} 字节）';
          return McpToolResult.text(text, structured: <String, Object?>{
            'crashId': crashId,
            'bytes': raw.length,
            'truncated': raw.length > max,
            'path': null,
          });
        } on DeviceCommandError catch (e) {
          _fail(e);
        }
      },
    );
