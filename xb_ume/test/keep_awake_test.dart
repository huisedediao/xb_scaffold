// 屏幕常亮（防长场景 / AI 循环中途熄屏）三层守卫：
//   1. 设备后端的命令构造（hdc 覆盖熄屏时间 / adb 插电常亮）；
//   2. MCP 工具注册与参数；
//   3. GUI 头部开关与 /api/keepawake 端点（内联在 ide_gui.dart，只做源码断言）。
//
// 命令本身要真机才跑得动，这里只锁「拼了什么参数」，避免以后误改 -o/-r
// 方向或把 adb 的 screen_off_timeout 写进来（那会持久改用户系统设置）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/src/device/adb.dart';
import '../bin/src/device/hdc.dart';
import '../bin/src/mcp/device_tools.dart';
import '../bin/src/mcp/tools.dart';

void main() {
  test('hdc：覆盖熄屏时间用 -o 2147483647，恢复用 -r', () {
    expect(hdcKeepAwakeArgs(true),
        <String>['shell', 'power-shell', 'timeout', '-o', '2147483647']);
    expect(hdcKeepAwakeArgs(false),
        <String>['shell', 'power-shell', 'timeout', '-r']);
  });

  test('adb：只切插电常亮，不写 screen_off_timeout', () {
    expect(adbKeepAwakeArgs(true),
        <String>['shell', 'svc', 'power', 'stayon', 'true']);
    expect(adbKeepAwakeArgs(false),
        <String>['shell', 'svc', 'power', 'stayon', 'false']);
    expect(adbKeepAwakeArgs(true).join(' '), isNot(contains('screen_off_timeout')));
  });

  test('工具注册在 act 组，参数 deviceId + on，on 默认 true', () {
    final tool =
        deviceTools().firstWhere((t) => t.name == 'xbume_keep_awake');
    expect(tool.group, ToolGroup.act, reason: '改设备状态，需 --tool-groups act');
    final props =
        (tool.inputSchema['properties'] as Map).keys.cast<String>().toSet();
    expect(props, containsAll(<String>['deviceId', 'on']));
    expect(tool.inputSchema['required'], <String>['deviceId']);
    final on = (tool.inputSchema['properties'] as Map)['on'] as Map;
    expect(on['type'], 'boolean');
    expect(on['default'], isTrue);
  });

  test('GUI 头部开关与 /api/keepawake 端点接好', () {
    final gui = File('bin/ide_gui.dart').readAsStringSync();
    expect(gui, contains('id="hdr-awake"'), reason: '页头缺「常亮」勾选框');
    expect(gui, contains("path == '/api/keepawake' && req.method == 'POST'"),
        reason: '端点必须只接受 POST，且写操作不能走 GET');
    for (final t in <String>[
      'applyKeepAwake',
      'syncAwake',
      'setKeepAwake',
      'keepAwakeSet',
    ]) {
      expect(gui, contains(t), reason: '前端少了 $t');
    }
    // 刷新/重开页面后勾选状态要能恢复：设备列表回包必须带 keepAwake。
    expect(gui, contains("'keepAwake': keepAwakeIds"));
    // 只对 Android / 鸿蒙出开关（iOS 后端没有等价命令）。
    expect(gui, contains("d.platform === 'android' || d.platform === 'ohos'"));
    // hdc 对不支持的子命令也返回 0，必须看输出判失败，不能当成功写状态。
    expect(gui, contains('power-shell'));
    expect(gui, contains('svc'));
  });
}
