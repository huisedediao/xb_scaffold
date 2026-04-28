import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBCellGroup extends StatelessWidget {
  final ValueGetter<Widget>? headerBuilder;
  final double? headerBottomPadding;
  final ValueGetter<Widget>? footerBuilder;
  final double? footerTopPadding;
  final List<Widget> children; // 子组件
  final double? radius; // 圆角
  final double? paddingTop; // 顶部内间距
  final double? paddingBottom; // 底部内间距
  final double? paddingLeft; // 左侧内间距
  final double? paddingRight; // 右侧内间距
  final double? marginTop; // 顶部外间距
  final double? marginBottom; // 底部外间距
  final double? marginLeft; // 左侧外间距
  final double? marginRight; // 右侧外间距
  final Color? backgroundColor; // 背景颜色
  final XBValueGetter<Widget, int>? separatorBuilder; // 分割线
  const XBCellGroup(
      {super.key,
      required this.children,
      this.headerBuilder,
      this.headerBottomPadding,
      this.footerBuilder,
      this.footerTopPadding,
      this.radius,
      this.paddingTop,
      this.paddingBottom,
      this.paddingLeft,
      this.paddingRight,
      this.marginTop,
      this.marginBottom,
      this.marginLeft,
      this.marginRight,
      this.backgroundColor,
      this.separatorBuilder});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        top: marginTop ?? 0,
        bottom: marginBottom ?? 0,
        left: marginLeft ?? 0,
        right: marginRight ?? 0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: headerBottomPadding ?? 0),
            child: headerBuilder != null ? headerBuilder!() : Container(),
          ),
          Container(
            decoration: BoxDecoration(
              color: backgroundColor ?? Colors.white,
              borderRadius: BorderRadius.circular(radius ?? 6),
            ),
            child: Padding(
              padding: EdgeInsets.only(
                top: paddingTop ?? 0,
                bottom: paddingBottom ?? 0,
                left: paddingLeft ?? 0,
                right: paddingRight ?? 0,
              ),
              child:
                  Column(mainAxisSize: MainAxisSize.min, children: _children),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(top: footerTopPadding ?? 0),
            child: footerBuilder != null ? footerBuilder!() : Container(),
          ),
        ],
      ),
    );
  }

  List<Widget> get _children {
    List<Widget> ret = [];
    for (int i = 0; i < children.length; i++) {
      ret.add(children[i]);
      if (i < children.length - 1) {
        if (separatorBuilder != null) {
          ret.add(separatorBuilder!(i));
        } else {
          ret.add(xbLine());
        }
      }
    }
    return ret;
  }
}
