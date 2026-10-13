import 'package:flutter/material.dart';

import '../config/xb_ume_config.dart';
import '../models/xb_ume_log_item.dart';
import '../persistence/xb_ume_persistence.dart';
import '../ui/xb_ume_host.dart';
import 'xb_ume_binding.dart';
import 'xb_ume_controller.dart';
import 'xb_ume_plugin.dart';
import 'xb_ume_storage_adapter.dart';
import 'xb_ume_store_registry.dart';

class XBUme {
  static XBUmeBinding ensureInitialized({
    XBUmeConfig config = const XBUmeConfig(),
    XBUmePersistence? persistence,
    List<XBUmePlugin> extraPlugins = const <XBUmePlugin>[],
  }) {
    return XBUmeBinding.ensureInitialized(
      config: config,
      persistence: persistence,
      extraPlugins: extraPlugins,
    );
  }

  static XBUmeController get controller => XBUmeBinding.instance.controller;

  static NavigatorObserver get routeObserver =>
      XBUmeBinding.instance.routeObserver;

  static TransitionBuilder appBuilder({TransitionBuilder? builder}) {
    return (BuildContext context, Widget? child) {
      final root = builder?.call(context, child) ?? child ?? const SizedBox();
      return XBUmeHost(controller: controller, child: root);
    };
  }

  static bool registerPlugin(XBUmePlugin plugin) {
    return controller.registerPlugin(plugin);
  }

  static bool unregisterPlugin(String pluginId) {
    return controller.unregisterPlugin(pluginId);
  }

  static bool registerStorageAdapter(XBUmeStorageAdapter adapter) {
    return controller.registerStorageAdapter(adapter);
  }

  static bool unregisterStorageAdapter(String adapterId) {
    return controller.unregisterStorageAdapter(adapterId);
  }

  static void log(
    String message, {
    XBUmeLogLevel level = XBUmeLogLevel.info,
    String tag = 'app',
    String? stack,
  }) {
    controller.addLog(level: level, tag: tag, message: message, stack: stack);
  }

  /// 注册一个需要 GUI「实例」Tab 查看的运行时对象（如 Provider 的
  /// ChangeNotifier、全局 State、单例）。重复 id 覆盖；GUI 按本 id 定位实例。
  static void registerStore(String id, Object store) {
    XBUmeStoreRegistry.register(id, store);
  }
}
