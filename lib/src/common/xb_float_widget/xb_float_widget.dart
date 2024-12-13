import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBFloatWidget extends StatefulWidget {
  final Widget child;
  final double contentWidth;
  final int type;

  const XBFloatWidget({
    Key? key,
    required this.child,
    required this.contentWidth,
    this.type = 0,
  }) : super(key: key);

  Widget buildContent(double contentLeft, double contentWidth, bool isAbove) {
    return Container(
      width: contentWidth,
      height: 100,
      color: Colors.red,
      child: const Text(
        '请重写buildContent',
        style: TextStyle(color: Colors.white),
      ),
    );
  }

  @override
  State<XBFloatWidget> createState() => _XBFloatWidgetState();
}

class _XBFloatWidgetState extends State<XBFloatWidget> {
  final GlobalKey childKey = GlobalKey();
  final GlobalKey<XBFadeWidgetState> animationKey = GlobalKey();
  OverlayEntry? tipsOverlay;

  final double contentPadding = 5;

  bool isShow() {
    return tipsOverlay != null;
  }

  hide() {
    animationKey.currentState?.hide(() {
      tipsOverlay?.remove();
      tipsOverlay = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // ignore: deprecated_member_use
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
          _showContent(
            context,
            Offset(
              position.dx + box.size.width / 2,
              widget.type == 0 ? position.dy + box.size.height : position.dy,
            ),
          );
        },
        child: Container(key: childKey, child: widget.child),
      ),
    );
  }

  Widget buildContent(double contentLeft, double contentWidth, bool isAbove) {
    return widget.buildContent(contentLeft, contentWidth, isAbove);
  }

  ///显示一个Tips的方法
  _showContent(BuildContext context, Offset position) {
    double contentWidth = widget.contentWidth;

    /// 判断左右是否超出边界，并调整位置
    double contentLeft = position.dx - contentWidth / 2;
    if (contentLeft < contentPadding) {
      contentLeft = contentPadding;
    } else if (contentLeft + contentWidth > screenW - contentPadding) {
      contentLeft = screenW - contentPadding - contentWidth;
    }

    tipsOverlay = OverlayEntry(builder: (ctx) {
      return XBFadeWidget(
        key: animationKey,
        autoShowAnimation: true,
        child: Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              //移除
              Positioned.fill(
                  child: GestureDetector(
                onTap: () {
                  hide();
                },
                child: Container(
                  color: Colors.transparent,
                ),
              )),
              Positioned(
                //居中
                left: contentLeft,
                top: widget.type == 0 ? position.dy : null,
                bottom: widget.type == 1 ? (screenH - position.dy) : null,
                child:
                    buildContent(contentLeft, contentWidth, widget.type == 1),
              ),
            ],
          ),
        ),
      );
    });
    Overlay.of(context).insert(tipsOverlay!);
  }
}
