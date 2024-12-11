import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBTip extends StatefulWidget {
  final Widget? child;
  final String tip;
  final TextStyle? tipStyle;
  final Color? bgColor;
  final double maxWidth;
  final double paddingH;

  /// 0下 1上
  final int type;
  const XBTip({
    Key? key,
    this.child,
    required this.tip,
    this.tipStyle,
    this.bgColor,
    this.maxWidth = 280,
    this.paddingH = 10,
    this.type = 0,
  }) : super(key: key);

  @override
  State<XBTip> createState() => _XBTipState();
}

class _XBTipState extends State<XBTip> {
  final GlobalKey childKey = GlobalKey();
  OverlayEntry? tipsOverlay;

  @override
  void initState() {
    super.initState();
    assert(widget.maxWidth < (screenW - contentPadding * 2),
        "最大宽度不能超过屏幕宽度 - ${contentPadding * 2}");
    assert(widget.tip.isNotEmpty, "tip 不能为空字符串");
  }

  final double contentPadding = 5;

  bool isShow() {
    return tipsOverlay != null;
  }

  hide() {
    tipsOverlay?.remove();
    tipsOverlay = null;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (isShow()) {
          hide();
          return false;
        }
        return true;
      },
      child: XBButton(
        onTap: () {
          RenderBox box =
              childKey.currentContext?.findRenderObject() as RenderBox;
          Offset position = box.localToGlobal(Offset.zero);
          //调用显示tips
          showTips(
            context,
            Offset(
              position.dx + box.size.width / 2,
              widget.type == 0 ? position.dy + box.size.height : position.dy,
            ),
          );
        },
        child: Container(
            key: childKey,
            //如果没有外部的点击组件可以自己设置一个默认组件
            child: widget.child),
      ),
    );
  }

  ///显示一个Tips的方法
  showTips(BuildContext context, Offset position) {
    Color bgColor = widget.bgColor ?? Colors.black;
    double textWidth = textSize().width;
    double contentWidth = textWidth + widget.paddingH * 2;

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

    tipsOverlay = OverlayEntry(builder: (ctx) {
      return Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned(
              //让tips居中
              left: contentLeft,
              top: widget.type == 0 ? position.dy : null,
              bottom: widget.type == 1
                  ? (screenH - position.dy + arrowHeight)
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: arrowHeight,
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(circular),
                        topRight: Radius.circular(circular),
                        bottomLeft: Radius.circular(circular),
                        bottomRight: Radius.circular(circular)),
                    child: Container(
                      color: bgColor,
                      constraints: BoxConstraints(maxWidth: widget.maxWidth),
                      child: Padding(
                        padding: EdgeInsets.only(
                            left: widget.paddingH,
                            right: widget.paddingH,
                            top: 5,
                            bottom: 5),
                        child: Text(
                          widget.tip,
                          style: _tipsStyle,
                        ),
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
                  painter: RPSCustomPainter(color: bgColor, type: widget.type),
                ),
              ),
            ),
            //移除tips
            Positioned.fill(
                child: GestureDetector(
              onTap: () {
                tipsOverlay?.remove();
              },
              child: Container(
                color: Colors.transparent,
              ),
            ))
          ],
        ),
      );
    });
    Overlay.of(context).insert(tipsOverlay!);
  }

  TextStyle get _tipsStyle =>
      widget.tipStyle ?? const TextStyle(color: Colors.white, fontSize: 12);

  Size textSize() {
    final TextPainter textPainter = TextPainter(
      text: TextSpan(text: widget.tip, style: _tipsStyle),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: widget.maxWidth - widget.paddingH * 2);

    final double height = textPainter.height;
    final double width = textPainter.width;
    return Size(width, height);
  }
}

class RPSCustomPainter extends CustomPainter {
  Color color;
  int type;
  RPSCustomPainter({required this.color, required this.type});

  @override
  void paint(Canvas canvas, Size size) {
    Paint paint_0 = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..strokeWidth = 1.0;

    Path path_0 = Path();
    if (type == 0) {
      // type 为 0 时，保持当前样式
      path_0.moveTo(size.width * 0.50, 0);
      path_0.lineTo(size.width * 1.00, size.height);
      path_0.lineTo(0, size.height);
      path_0.lineTo(size.width * 0.50, 0);
    } else {
      // type 为 1 时，箭头方向上下翻转
      path_0.moveTo(size.width * 0.50, size.height);
      path_0.lineTo(size.width * 1.00, 0);
      path_0.lineTo(0, 0);
      path_0.lineTo(size.width * 0.50, size.height);
    }
    path_0.close();

    canvas.drawPath(path_0, paint_0);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}
