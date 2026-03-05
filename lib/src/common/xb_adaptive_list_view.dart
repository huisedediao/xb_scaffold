import 'package:flutter/material.dart';

class XBAdaptiveListView extends StatelessWidget {
  final double maxHeight;
  final double? minHeight;

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final IndexedWidgetBuilder? separatorBuilder;

  /// 固定区（不随列表滚动）
  final Widget? header;
  final Widget? footer;

  /// 空态显示在 header 和 footer 中间（属于滚动区内容）
  final Widget? emptyView;

  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;
  final ScrollPhysics? physics;
  final bool reverse;

  final Duration animationDuration;

  const XBAdaptiveListView.builder({
    super.key,
    required this.maxHeight,
    this.minHeight,
    required this.itemCount,
    required this.itemBuilder,
    this.header,
    this.footer,
    this.emptyView,
    this.padding,
    this.controller,
    this.physics,
    this.reverse = false,
    this.animationDuration = const Duration(milliseconds: 200),
  }) : separatorBuilder = null;

  const XBAdaptiveListView.separated({
    super.key,
    required this.maxHeight,
    this.minHeight,
    required this.itemCount,
    required this.itemBuilder,
    required this.separatorBuilder,
    this.header,
    this.footer,
    this.emptyView,
    this.padding,
    this.controller,
    this.physics,
    this.reverse = false,
    this.animationDuration = const Duration(milliseconds: 200),
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: animationDuration,
      curve: Curves.easeInOut,
      child: ConstrainedBox(
        // 整体也受 max/min 约束：header + listArea + footer 的总高度
        constraints: BoxConstraints(
          maxHeight: maxHeight,
          minHeight: minHeight ?? 0,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (header != null) header!,

            // 中间滚动区：只让这里滚动，header/footer 固定
            Flexible(
              fit: FlexFit.loose,
              child: _buildScrollableArea(),
            ),

            if (footer != null) footer!,
          ],
        ),
      ),
    );
  }

  Widget _buildScrollableArea() {
    // 空态：放在滚动区中间（在 header/footer 之间）
    if (itemCount == 0) {
      return _wrapScroll(
        child: emptyView ?? const SizedBox.shrink(),
      );
    }

    // 有数据：滚动区显示列表
    if (separatorBuilder != null) {
      return ListView.separated(
        controller: controller,
        padding: padding,
        physics: physics,
        reverse: reverse,
        shrinkWrap: true,
        itemCount: itemCount,
        itemBuilder: itemBuilder,
        separatorBuilder: separatorBuilder!,
      );
    }

    return ListView.builder(
      controller: controller,
      padding: padding,
      physics: physics,
      reverse: reverse,
      shrinkWrap: true,
      itemCount: itemCount,
      itemBuilder: itemBuilder,
    );
  }

  /// 让 emptyView 也具备“内容少自适应，内容多可滚动”的一致行为
  /// （尤其 emptyView 可能很高，比如一堆说明文字/按钮）
  Widget _wrapScroll({required Widget child}) {
    return SingleChildScrollView(
      controller: controller,
      padding: padding,
      physics: physics,
      reverse: reverse,
      child: child,
    );
  }
}
