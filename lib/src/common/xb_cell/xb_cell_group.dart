import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellGroup extends StatelessWidget {
  final List<Widget> children; // 子组件
  final double? radius; // 圆角
  final double? topPadding; // 顶部内间距
  final double? bottomPadding; // 底部内间距
  final double? leftPadding; // 左侧内间距
  final double? rightPadding; // 右侧内间距
  final double? topMargin; // 顶部外间距
  final double? bottomMargin; // 底部外间距
  final double? leftMargin; // 左侧外间距
  final double? rightMargin; // 右侧外间距
  final Color? backgroundColor; // 背景颜色
  final XBValueGetter<Widget, int>? separatedBuilder; // 分割线
  const XBCellGroup(
      {super.key,
      required this.children,
      this.radius,
      this.topPadding,
      this.bottomPadding,
      this.leftPadding,
      this.rightPadding,
      this.topMargin,
      this.bottomMargin,
      this.leftMargin,
      this.rightMargin,
      this.backgroundColor,
      this.separatedBuilder});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        top: topMargin ?? 15,
        bottom: bottomMargin ?? 15,
        left: leftMargin ?? 10,
        right: rightMargin ?? 10,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: backgroundColor ?? Colors.white,
          borderRadius: BorderRadius.circular(radius ?? 6),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            top: topPadding ?? 15,
            bottom: bottomPadding ?? 15,
            left: leftPadding ?? 10,
            right: rightPadding ?? 10,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: _children),
        ),
      ),
    );
  }

  List<Widget> get _children {
    List<Widget> ret = [];
    for (int i = 0; i < children.length; i++) {
      ret.add(children[i]);
      if (i < children.length - 1) {
        if (separatedBuilder != null) {
          ret.add(separatedBuilder!(i));
        } else {
          ret.add(xbLine());
        }
      }
    }
    return ret;
  }
}
