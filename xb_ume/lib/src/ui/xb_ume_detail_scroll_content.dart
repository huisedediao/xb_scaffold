import 'package:flutter/material.dart';

/// 详情弹窗正文：常显滚动条 + 可滚动内容。
///
/// Scrollbar 与 SingleChildScrollView 必须共用同一个 ScrollController：
/// 若不给 Scrollbar 传 controller，它会回退到 PrimaryScrollController，
/// 而桌面端（macOS/Windows/Linux）的 ScrollView 默认不继承
/// PrimaryScrollController（会创建自己的内部 controller），于是帧回调里
/// 触发 "The Scrollbar's ScrollController has no ScrollPosition attached." 断言。
class XBUmeDetailScrollContent extends StatefulWidget {
  const XBUmeDetailScrollContent({super.key, required this.child});

  final Widget child;

  @override
  State<XBUmeDetailScrollContent> createState() =>
      _XBUmeDetailScrollContentState();
}

class _XBUmeDetailScrollContentState extends State<XBUmeDetailScrollContent> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scrollController,
        child: widget.child,
      ),
    );
  }
}
