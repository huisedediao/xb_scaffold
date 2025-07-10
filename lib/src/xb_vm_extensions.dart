import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'xb_vm.dart';

/// BuildContext扩展，用于在任何地方访问XBWidget的vm实例
extension XBVMContext on BuildContext {
  /// 获取指定类型的vm实例（不监听变化）
  /// 
  /// 使用示例：
  /// ```dart
  /// final vm = context.vmOf<MyWidgetVM>();
  /// ```
  T vmOf<T extends XBVM>() {
    return Provider.of<T>(this, listen: false);
  }

  /// 获取指定类型的vm实例（监听变化，会触发rebuild）
  /// 
  /// 使用示例：
  /// ```dart
  /// final vm = context.vmWatch<MyWidgetVM>();
  /// ```
  T vmWatch<T extends XBVM>() {
    return Provider.of<T>(this, listen: true);
  }

  /// 安全获取vm实例，不存在时返回null（不监听变化）
  /// 
  /// 使用示例：
  /// ```dart
  /// final vm = context.vmOfOrNull<MyWidgetVM>();
  /// if (vm != null) {
  ///   // 使用vm
  /// }
  /// ```
  T? vmOfOrNull<T extends XBVM>() {
    try {
      return Provider.of<T>(this, listen: false);
    } catch (e) {
      return null;
    }
  }

  /// 安全获取vm实例（监听变化），不存在时返回null
  /// 
  /// 使用示例：
  /// ```dart
  /// final vm = context.vmWatchOrNull<MyWidgetVM>();
  /// if (vm != null) {
  ///   // 使用vm
  /// }
  /// ```
  T? vmWatchOrNull<T extends XBVM>() {
    try {
      return Provider.of<T>(this, listen: true);
    } catch (e) {
      return null;
    }
  }
}
