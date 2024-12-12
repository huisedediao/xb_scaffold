import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/view/xb_arrow_painter.dart';
import 'package:xb_scaffold/src/utils/xb_text_size_util.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBMenu extends StatefulWidget {
  final Widget child;
  final List<String> items;
  final ValueChanged<int>? onItemSelected;
  final TextStyle? itemStyle;
  final Color? bgColor;
  final double maxWidth;
  final double paddingH;

  /// 0下 1上
  final int type;

  const XBMenu({
    Key? key,
    required this.child,
    required this.items,
    this.onItemSelected,
    this.itemStyle,
    this.bgColor,
    this.maxWidth = 280,
    this.paddingH = 10,
    this.type = 0,
  }) : super(key: key);

  @override
  State<XBMenu> createState() => _XBMenuState();
}

class _XBMenuState extends State<XBMenu> {
  final GlobalKey childKey = GlobalKey();
  OverlayEntry? menuOverlay;

  @override
  void initState() {
    super.initState();
    assert(widget.items.isNotEmpty, "菜单项不能为空");
  }

  bool isMenuVisible() {
    return menuOverlay != null;
  }

  hideMenu() {
    menuOverlay?.remove();
    menuOverlay = null;
  }

  @override
  Widget build(BuildContext context) {
    return XBButton(
      onTap: () {
        RenderBox box =
            childKey.currentContext?.findRenderObject() as RenderBox;
        Offset position = box.localToGlobal(Offset.zero);
        // 调用显示菜单
        showMenu(
          context,
          Offset(
            position.dx + box.size.width / 2,
            widget.type == 0 ? position.dy + box.size.height : position.dy,
          ),
        );
      },
      child: Container(key: childKey, child: widget.child),
    );
  }

  calculateMaxWidth() {
    /// 计算item的最大长度
    double maxWidth = 0;
    for (var item in widget.items) {
      double width = XBTextSizeUtil.textSize(
        text: item,
        textStyle: getItemStyle(),
        maxWidth: 10000,
      ).width;
      if (width > maxWidth) {
        maxWidth = width;
      }
    }
    if (maxWidth > widget.maxWidth - widget.paddingH * 2) {
      maxWidth = widget.maxWidth - widget.paddingH * 2;
    }
    return maxWidth;
  }

  TextStyle getItemStyle() {
    return widget.itemStyle ??
        const TextStyle(fontSize: 14, color: Colors.white);
  }

  final double contentPadding = 5;

  /// 显示菜单的方法
  showMenu(BuildContext context, Offset position) {
    Color bgColor = widget.bgColor ?? Colors.black;
    double calcWidth = calculateMaxWidth();
    double contentWidth = calcWidth + widget.paddingH * 2;

    /// 判断左右是否超出边界，并调整位置
    double contentLeft = position.dx - contentWidth / 2;
    double arrowOffset = 0;
    if (contentLeft < contentPadding) {
      arrowOffset = -(contentPadding - contentLeft);
      contentLeft = contentPadding;
    } else if (contentLeft + contentWidth > screenW - contentPadding) {
      arrowOffset = contentLeft + contentWidth - screenW + contentPadding;
      contentLeft = screenW - contentPadding - contentWidth;
    }

    double arrowWidth = 10;
    double arrowHeight = 5;
    double arrowStart =
        contentLeft + contentWidth * 0.5 - arrowWidth * 0.5 + arrowOffset;

    double circular = 5;

    menuOverlay = OverlayEntry(builder: (ctx) {
      return Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            // 点击空白处隐藏菜单
            Positioned.fill(
              child: XBButton(
                onTap: hideMenu,
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              left: contentLeft,
              top: widget.type == 0 ? position.dy : null,
              bottom: widget.type == 1
                  ? (screenH - position.dy + arrowHeight)
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: arrowHeight),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(circular),
                    child: Container(
                      color: bgColor,
                      constraints: BoxConstraints(maxWidth: widget.maxWidth),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(widget.items.length, (index) {
                          return XBButton(
                            onTap: () {
                              hideMenu();
                              widget.onItemSelected?.call(index);
                            },
                            coverTransparentWhileOpacity: true,
                            child: Column(
                              children: [
                                Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: widget.paddingH,
                                      vertical: 10),
                                  child: Text(
                                    overflow: TextOverflow.ellipsis,
                                    widget.items[index],
                                    style: getItemStyle(),
                                  ),
                                ),
                                Container(
                                  height: onePixel,
                                  color: Colors.grey.withAlpha(100),
                                  width: calcWidth,
                                )
                              ],
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: widget.type == 0
                  ? position.dy + 1
                  : position.dy - arrowHeight - 1,
              child: Padding(
                padding: EdgeInsets.only(left: arrowStart),
                child: CustomPaint(
                  size: Size(arrowWidth,
                      arrowHeight), //You can Replace this with your desired WIDTH and HEIGHT
                  painter: XBArrowPainter(color: bgColor, type: widget.type),
                ),
              ),
            ),
          ],
        ),
      );
    });
    Overlay.of(context).insert(menuOverlay!);
  }
}
