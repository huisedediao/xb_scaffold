import 'package:flutter/material.dart';

class XBTip extends StatefulWidget {
  final Widget? child;
  final String tip;
  final TextStyle? tipStyle;
  final Color? bgColor;
  const XBTip(
      {Key? key, this.child, required this.tip, this.tipStyle, this.bgColor})
      : super(key: key);

  @override
  State<XBTip> createState() => _XBTipState();
}

class _XBTipState extends State<XBTip> {
  final GlobalKey childKey = GlobalKey();

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
    OverlayEntry? tipsOverlay;
    tipsOverlay = OverlayEntry(builder: (ctx) {
      return Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned(
              //减去了文字一半的长度，让tips居中，这个位置可以自己根据需求调整
              left: position.dx + 12 - (widget.tip.length * 12) - paddingLeft,
              top: position.dy,
              child: Column(
                children: [
                  CustomPaint(
                    size: const Size(10,
                        5), //You can Replace this with your desired WIDTH and HEIGHT
                    painter: RPSCustomPainter(color: bgColor),
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      color: bgColor,
                      child: Padding(
                        padding: EdgeInsets.only(
                            left: paddingLeft,
                            right: paddingLeft,
                            top: 5,
                            bottom: 5),
                        child: Text(
                          widget.tip,
                          style: widget.tipStyle ??
                              const TextStyle(
                                  color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            //移除tips
            Positioned.fill(child: GestureDetector(
              onTap: () {
                tipsOverlay?.remove();
              },
            ))
          ],
        ),
      );
    });
    Overlay.of(context).insert(tipsOverlay);
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
