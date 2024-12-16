import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
export 'xb_float_meun_icon_title.dart';
export 'xb_float_menu_title.dart';
export 'xb_float_widget_arrow.dart';
export 'xb_float_menu.dart';
export 'xb_tip.dart';

class XBFloatWidget extends StatefulWidget {
  final Widget child;
  final int type;
  final bool tapContentHide;

  /// 内容到屏幕边缘的最小距离
  final double minGapToBorder = 5;

  const XBFloatWidget({
    Key? key,
    required this.child,
    this.type = 0,
    this.tapContentHide = false,
  }) : super(key: key);

  double get contentWidth => 280;

  Widget buildContent(
      Offset position, double contentLeft, bool isAbove, Function hide) {
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
        coverTransparentWhileOpacity: true,
        child: Container(key: childKey, child: widget.child),
      ),
    );
  }

  Widget buildContent(Offset position, double contentLeft, bool isAbove) {
    return widget.buildContent(position, contentLeft, isAbove, hide);
  }

  Widget _buildContent(Offset position, double contentLeft, bool isAbove) {
    if (widget.tapContentHide) {
      return GestureDetector(
        onTap: () {
          hide();
        },
        child: widget.buildContent(position, contentLeft, isAbove, hide),
      );
    }
    return widget.buildContent(position, contentLeft, isAbove, hide);
  }

  _showContent(BuildContext context, Offset position) {
    double contentWidth = widget.contentWidth;

    /// 判断左右是否超出边界，并调整位置
    double contentLeft = position.dx - contentWidth / 2;
    if (contentLeft < widget.minGapToBorder) {
      contentLeft = widget.minGapToBorder;
    } else if (contentLeft + contentWidth > screenW - widget.minGapToBorder) {
      contentLeft = screenW - widget.minGapToBorder - contentWidth;
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
                left: contentLeft,
                top: widget.type == 0 ? position.dy : null,
                bottom: widget.type == 1 ? (screenH - position.dy) : null,
                child: _buildContent(position, contentLeft, widget.type == 1),
              ),
            ],
          ),
        ),
      );
    });
    Overlay.of(context).insert(tipsOverlay!);
  }
}
