import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 按字段粒度订阅 VM 的轻量组件（大页面性能优化）
///
/// 背景：`XBWidget` 内部用 `Consumer<T>` 监听整个 VM，每次 `vm.notify()`
/// 都会重建整个 `buildWidget`。大页面需要把刷新范围缩小到具体字段。
///
/// 本组件把 `context.select` 的正确用法（独立 Widget 的 build + 缓存跳过）
/// 封装成一步到位的写法：
/// - selector 返回值变化时，本组件被 Provider 单独唤醒重建；
/// - 值未变时返回上一次缓存的 child（同一实例），父级 Consumer 波及重建时
///   Element 判定 identical 直接跳过整棵子树，等效于 const 的跳过语义。
///
/// 用法：
/// ```dart
/// XBSelect<PageVM, int>(
///   selector: (vm) => vm.unreadCount,
///   builder: (context, count) => Chip(label: Text('未读 $count')),
/// )
/// ```
///
/// 注意：
/// - 重建判定分两层：内层由 Provider 的 select 完成（DeepCollectionEquality
///   深比较，List/Map/Set 的内容变化——含原地修改——都会触发重建；超大集合
///   注意每次 notify 的深比较成本）；外层缓存用 `==` 比较聚合值，推荐标量或
///   Dart 3 record（record 的 `==` 是字段级结构相等，天然适合聚合多值）；
/// - 监听同一 VM 的多个值：直接让 [selector] 返回 record，无需本类变体；
///   监听多个 VM 的值请用 [XBSelectMulti]；
/// - [builder] 应只依赖传入的 [value] 与常量：值未变时会复用缓存的 child，
///   若读取其他会变化的外部数据，可能拿到过期画面；
/// - 高频值（每帧/每秒变化的倒计时、进度等）不要走 `notify()`——每次 notify
///   仍会触发整个 buildWidget 重跑。请改用 `vm.createNotifier` +
///   `ValueListenableBuilder`，只重建订阅该值的 builder。
class XBSelect<T extends Listenable, R> extends StatefulWidget {
  const XBSelect({
    super.key,
    required this.selector,
    required this.builder,
  });

  /// 从 VM 中挑选要订阅的值，本组件只依赖该值的变化
  final R Function(T vm) selector;

  /// 值变化时重建；参数为 selector 的返回值
  final Widget Function(BuildContext context, R value) builder;

  @override
  State<XBSelect<T, R>> createState() => _XBSelectState<T, R>();
}

class _XBSelectState<T extends Listenable, R> extends State<XBSelect<T, R>> {
  R? _lastValue;
  Widget? _cachedChild;

  @override
  Widget build(BuildContext context) {
    final R value = context.select<T, R>(widget.selector);

    // 值未变：返回上一次的 child 实例（identical），
    // 父级重建波及时 Element.updateChild 直接短路，子树整块跳过
    if (_cachedChild != null && value == _lastValue) {
      return _cachedChild!;
    }
    _lastValue = value;
    _cachedChild = widget.builder(context, value);
    return _cachedChild!;
  }
}

/// 跨 VM / 多值的字段级订阅组件
///
/// [XBSelect] 只能订阅单个 VM 的单个值；[XBSelectMulti] 的 [XBSelectMulti.selector]
/// 接收 BuildContext，可在闭包内对任意多个 VM 调用任意多次
/// `context.select`（同一 VM 的多个字段、跨多个 VM 均可），把结果聚合为
/// 一个值返回——任何一个被 select 的值变化，本组件都会重建。
///
/// 推荐用 Dart 3 record 聚合结果（record 的 `==` 是字段级结构相等）：
/// ```dart
/// XBSelectMulti<({int unread, String userName})>(
///   selector: (context) => (
///     unread: context.select<PageVM, int>((vm) => vm.unreadCount),
///     userName: context.select<UserVM, String>((vm) => vm.name),
///     // 同一 VM 选多个字段也没问题：
///     // count: context.select<PageVM, int>((vm) => vm.itemCount),
///   ),
///   builder: (context, v) => Text('${v.userName}: ${v.unread}'),
/// )
/// ```
///
/// 机制：每个 `context.select` 调用会在对应 Provider 上注册一个独立的
/// aspect，notify 时任一 aspect 判定变化即唤醒本组件；外层缓存逻辑与
/// [XBSelect] 相同——聚合值未变时返回缓存的 child（identical），父级
/// Consumer 波及重建时整棵子树直接跳过。
///
/// 注意：[R] 必须有可靠的相等性（推荐 record）；所有被 select 的 Provider
/// 都必须是本组件的祖先。
class XBSelectMulti<R> extends StatefulWidget {
  const XBSelectMulti({
    super.key,
    required this.selector,
    required this.builder,
  });

  /// 聚合多个订阅点：闭包内对任意多个 VM 调用任意多次 `context.select`，
  /// 将结果聚合为一个值返回（推荐 record）。任一被 select 的值变化时，
  /// 本组件会被唤醒重建。
  final R Function(BuildContext context) selector;

  /// 聚合值变化时重建；参数为 [selector] 的返回值
  final Widget Function(BuildContext context, R value) builder;

  @override
  State<XBSelectMulti<R>> createState() => _XBSelectMultiState<R>();
}

class _XBSelectMultiState<R> extends State<XBSelectMulti<R>> {
  R? _lastValue;
  Widget? _cachedChild;

  @override
  Widget build(BuildContext context) {
    // 闭包内的每个 context.select 都会独立注册依赖：
    // 任一被 select 的值变化，Provider 都会唤醒本组件
    final R value = widget.selector(context);

    // 聚合值未变：返回缓存 child（identical），父级波及时整块跳过
    if (_cachedChild != null && value == _lastValue) {
      return _cachedChild!;
    }
    _lastValue = value;
    _cachedChild = widget.builder(context, value);
    return _cachedChild!;
  }
}
