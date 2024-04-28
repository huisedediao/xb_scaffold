import 'package:flutter/material.dart';

class XBTip extends StatefulWidget {
  final Widget? child;
  final String tip;
  final TextStyle? tipStyle;
  final Color? bgColor;
  final double maxWidth;

  /// 箭头起始位置，箭头始终指向child在x轴的中心位置
  final double? arrowStart;
  const XBTip(
      {Key? key,
      this.child,
      required this.tip,
      this.tipStyle,
      this.bgColor,
      this.maxWidth = 280,
      this.arrowStart})
      : super(key: key);

  @override
  State<XBTip> createState() => _XBTipState();
}

class _XBTipState extends State<XBTip> {
  final GlobalKey childKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    assert(widget.tip.isNotEmpty, "tip 不能为空字符串");
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (details) {
        RenderBox box =
            childKey.currentContext?.findRenderObject() as RenderBox;
        Offset position = box.localToGlobal(Offset.zero);
        //调用显示tips
        showTips(
          context,
          Offset(
            position.dx + box.size.width / 2,
            position.dy + box.size.height,
          ),
        );
      },
      child: Container(
          key: childKey,
          //如果没有外部的点击组件可以自己设置一个默认组件
          child: widget.child),
    );
  }

  ///显示一个Tips的方法
  showTips(BuildContext context, Offset position) {
    Color bgColor = widget.bgColor ?? Colors.black;
    double paddingLeft = 10;
    double textWidth = textSize().width;
    double arrowWidth = 10;
    double arrowStart = widget.arrowStart ?? textWidth * 0.5;
    if (arrowStart < 0) {
      arrowStart = 0;
    }
    double arrowMaxStart = textWidth - arrowWidth;
    if (arrowStart > arrowMaxStart) {
      arrowStart = arrowMaxStart;
    }
    double offset = textWidth * 0.5 - arrowWidth * 0.5 - arrowStart;
    bool isNotNeedTopLeftRadius = arrowStart < 4;
    bool isNotNeedTopRightRadius =
        (arrowStart + arrowWidth) > (paddingLeft + textWidth - 4);
    OverlayEntry? tipsOverlay;
    tipsOverlay = OverlayEntry(builder: (ctx) {
      return Material(
        color: Colors.transparent,
        child: WillPopScope(
          onWillPop: () async {
            return false;
          },
          child: Stack(
            children: [
              Positioned(
                //减去了文字一半的长度，让tips居中，这个位置可以自己根据需求调整
                left: position.dx - textWidth / 2 + offset,
                top: position.dy,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(left: arrowStart),
                      child: CustomPaint(
                        size: Size(arrowWidth,
                            5), //You can Replace this with your desired WIDTH and HEIGHT
                        painter: RPSCustomPainter(color: bgColor),
                      ),
                    ),
                    ClipRRect(
                      borderRadius: BorderRadius.only(
                          topLeft:
                              Radius.circular(isNotNeedTopLeftRadius ? 0 : 6),
                          topRight:
                              Radius.circular(isNotNeedTopRightRadius ? 0 : 6),
                          bottomLeft: const Radius.circular(6),
                          bottomRight: const Radius.circular(6)),
                      child: Container(
                        color: bgColor,
                        constraints: BoxConstraints(maxWidth: widget.maxWidth),
                        child: Padding(
                          padding: EdgeInsets.only(
                              left: paddingLeft,
                              right: paddingLeft,
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
        ),
      );
    });
    Overlay.of(context).insert(tipsOverlay);
  }

  TextStyle get _tipsStyle =>
      widget.tipStyle ?? const TextStyle(color: Colors.white, fontSize: 12);

  Size textSize() {
    final TextPainter textPainter = TextPainter(
      text: TextSpan(text: widget.tip, style: _tipsStyle),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: widget.maxWidth);

    final double height = textPainter.height;
    final double width = textPainter.width;
    return Size(width, height);
  }
}

class RPSCustomPainter extends CustomPainter {
  Color color;
  RPSCustomPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    Paint paint_0 = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..strokeWidth = 1.0;

    Path path_0 = Path();
    path_0.moveTo(size.width * 0.50, 0);
    path_0.lineTo(size.width * 1.00, size.height);
    path_0.lineTo(0, size.height);
    path_0.lineTo(size.width * 0.50, 0);
    path_0.close();

    canvas.drawPath(path_0, paint_0);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}
