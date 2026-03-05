import 'package:flutter/material.dart';

class XBAdaptiveListView extends StatelessWidget {
  final double maxHeight;
  final double? minHeight;

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final IndexedWidgetBuilder? separatorBuilder;

  final Widget? header;
  final Widget? footer;
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
        constraints: BoxConstraints(
          maxHeight: maxHeight,
          minHeight: minHeight ?? 0,
        ),
        child: _buildList(),
      ),
    );
  }

  Widget _buildList() {
    final totalCount = _calculateItemCount();

    if (separatorBuilder != null) {
      return ListView.separated(
        controller: controller,
        padding: padding,
        physics: physics,
        reverse: reverse,
        shrinkWrap: true,
        itemCount: totalCount,
        itemBuilder: _itemBuilder,
        separatorBuilder: (context, index) {
          if (_isHeader(index) || _isFooter(index)) {
            return const SizedBox.shrink();
          }
          return separatorBuilder!(context, _dataIndex(index));
        },
      );
    }

    return ListView.builder(
      controller: controller,
      padding: padding,
      physics: physics,
      reverse: reverse,
      shrinkWrap: true,
      itemCount: totalCount,
      itemBuilder: _itemBuilder,
    );
  }

  int _calculateItemCount() {
    int count = 0;

    if (header != null) count++;

    if (itemCount == 0) {
      if (emptyView != null) count++;
    } else {
      count += itemCount;
    }

    if (footer != null) count++;

    return count;
  }

  bool _isHeader(int index) {
    return header != null && index == 0;
  }

  bool _isFooter(int index) {
    return footer != null && index == _calculateItemCount() - 1;
  }

  int _dataIndex(int index) {
    if (header != null) {
      return index - 1;
    }
    return index;
  }

  Widget _itemBuilder(BuildContext context, int index) {
    if (_isHeader(index)) {
      return header!;
    }

    if (_isFooter(index)) {
      return footer!;
    }

    // emptyView
    if (itemCount == 0) {
      return emptyView ?? const SizedBox.shrink();
    }

    final dataIndex = _dataIndex(index);
    return itemBuilder(context, dataIndex);
  }
}
