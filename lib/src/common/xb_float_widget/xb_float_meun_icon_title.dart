import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBFloatMenuIconTitleItem {
  final String title;
  final String icon;
  const XBFloatMenuIconTitleItem(
    this.title,
    this.icon,
  );
}

class XBFloatMenuIconTitle extends StatelessWidget {
  final Widget child;
  final List<XBFloatMenuIconTitleItem> items;
  final Size iconSize;
  final ValueChanged<int> onTapItem;
  final Color? bgColor;
  final double width;
  final double paddingLeft;
  final TextStyle? titleStyle;
  final TextOverflow? titleOverflow;
  final Color? separatorColor;
  final double? gap;
  final int type;
  final double? contentHeight;
  const XBFloatMenuIconTitle(
      {super.key,
      required this.child,
      required this.items,
      required this.onTapItem,
      this.iconSize = const Size(20, 20),
      this.bgColor,
      this.width = 80,
      this.paddingLeft = 0,
      this.titleStyle,
      this.titleOverflow,
      this.separatorColor,
      this.gap,
      this.type = 0,
      this.contentHeight});

  @override
  Widget build(BuildContext context) {
    return XBFloatMenu(
      bgColor: bgColor,
      width: width,
      type: type,
      itemCount: items.length,
      itemBuilder: (index, hide) {
        return XBButton(
          onTap: () {
            hide();
            onTapItem(index);
          },
          coverTransparentWhileOpacity: true,
          child: SizedBox(
            height: contentHeight ?? 40,
            child: Padding(
              padding: EdgeInsets.only(left: paddingLeft),
              child: Row(
                children: [
                  XBImage(
                    items[index].icon,
                    width: iconSize.width,
                    height: iconSize.height,
                  ),
                  SizedBox(width: gap ?? spaces.gapLess),
                  Text(
                    items[index].title,
                    style: _textStyle,
                    overflow: titleOverflow,
                  ),
                ],
              ),
            ),
          ),
        );
      },
      separatorBuilder: (index) {
        return xbLine(color: separatorColor, startPadding: 5, endPadding: 5);
      },
      child: child,
    );
  }

  TextStyle get _textStyle =>
      titleStyle ?? const TextStyle(color: Colors.white);
}
