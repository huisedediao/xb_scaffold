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
/// - [R] 的 `==` 决定是否重建：返回 List/自定义对象时须整体替换引用，
///   原地修改（clear + addAll）不会被识别为变化；
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
