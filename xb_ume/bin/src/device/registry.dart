// 设备后端注册表：按 --device-backend 组装 adb/hdc/simctl/idevice/mobile-mcp，
// 并把 deviceId 路由到对应后端。
//
// 约定：
//   - 'auto'（默认）= 所有可用的自研后端（adb/hdc/simctl/idevice）；
//   - 显式列表按顺序启用（如 'adb,hdc'）；
//   - mobile-mcp 是可选适配器，**不**进入 auto：启用它会拉起
//     `npx @mobilenext/mobile-mcp`，可能在用户机器上触发外网下载，
//     必须由使用者显式写进 --device-backend 才生效；
//   - 不可用的后端仍出现在 xbume_devices 的 backends 里，带 reason，
//     让模型知道"为什么没有设备"，而不是静默消失。
library;

import 'adb.dart';
import 'bridge.dart';
import 'hdc.dart';
import 'idevice.dart';
import 'mobile_mcp.dart';
import 'simctl.dart';

class DeviceRegistry {
  DeviceRegistry(this.bridges);

  /// 按规格构建：auto / 逗号分隔的后端名。
  factory DeviceRegistry.fromSpec(String spec) {
    final raw = spec.trim().toLowerCase();
    final wanted = raw.isEmpty || raw == 'auto'
        ? const <String>['adb', 'hdc', 'simctl', 'idevice']
        : raw
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
    final list = <DeviceBridge>[];
    for (final name in wanted) {
      switch (name) {
        case 'adb':
          list.add(AdbBridge());
        case 'hdc':
          list.add(HdcBridge());
        case 'simctl':
          list.add(SimctlBridge());
        case 'idevice':
          list.add(IDeviceBridge());
        case 'mobile-mcp' || 'mobilemcp' || 'mobile_mcp':
          list.add(MobileMcpBridge());
        default:
          // 未知后端名忽略（保持 --device-backend 宽容，不因拼写失败整体退出）。
          break;
      }
    }
    return DeviceRegistry(list);
  }

  final List<DeviceBridge> bridges;

  /// 后端自述（供 xbume_devices 展示能力与不可用原因）。
  List<Map<String, Object?>> backendsJson() => bridges
      .map((b) => <String, Object?>{
            'name': b.backend,
            'available': b.available,
            'capabilities': b.capabilityNames,
            if (!b.available && b.unavailableReason != null)
              'reason': b.unavailableReason,
          })
      .toList(growable: false);

  /// 预热各后端（适配器握手等）；失败只影响对应后端。
  Future<void> warmupAll() async {
    await Future.wait(bridges.map((b) async {
      try {
        await b.warmup();
      } catch (_) {
        // 预热失败留给 backendsJson 的 reason 展示。
      }
    }));
  }

  /// 汇总所有后端的设备列表（按后端并发，单个后端失败不影响其他）。
  Future<List<DeviceInfo>> listDevices() async {
    final results = await Future.wait(bridges.map((b) async {
      if (!b.available) return <DeviceInfo>[];
      try {
        return await b.listDevices();
      } catch (_) {
        return <DeviceInfo>[];
      }
    }));
    final out = <DeviceInfo>[];
    for (final r in results) {
      out.addAll(r);
    }
    return out;
  }

  /// 按 deviceId 找后端；可选 [backend] 限定。
  Future<(DeviceBridge, DeviceInfo)?> resolve(String deviceId,
      {String? backend}) async {
    final devices = await listDevices();
    for (final d in devices) {
      if (d.id != deviceId) continue;
      if (backend != null && backend.isNotEmpty && d.backend != backend) {
        continue;
      }
      final b = bridgeOf(d.backend);
      if (b != null) return (b, d);
    }
    return null;
  }

  DeviceBridge? bridgeOf(String name) {
    for (final b in bridges) {
      if (b.backend == name) return b;
    }
    return null;
  }

  /// 已连接（usable）设备（launch 时给模型做默认选择）。
  Future<List<DeviceInfo>> usableDevices() async =>
      (await listDevices()).where((d) => d.usable).toList(growable: false);

  /// 释放各后端资源（如 mobile-mcp 适配器进程）；单个失败不影响其他。
  Future<void> disposeAll() async {
    for (final b in bridges) {
      try {
        await b.dispose();
      } catch (_) {
        // 回收失败不应阻断退出。
      }
    }
  }
}
