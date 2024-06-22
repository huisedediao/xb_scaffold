import 'dart:collection';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// 展示全局loading，优先级：widget > xbLoadingBuilder > const XBLoadingWidget()
showLoadingGlobal(
    {bool topLeftEnable = true,
    bool topCenterEnable = false,
    bool topRightEnable = false,
    bool contentEnable = false,
    String? msg,
    Widget? widget}) {
  _taskQueue.add(XBLoadingTask(_taskShow,
      topLeftEnable: topLeftEnable,
      topCenterEnable: topCenterEnable,
      topRightEnable: topRightEnable,
      contentEnable: contentEnable,
      msg: msg,
      widget: widget));
  _exeTask();
}

bool get isShowGoabolLoading => _items.isNotEmpty;

hideLoadingGlobal() {
  _taskQueue.add(XBLoadingTask(_taskHide));
  _exeTask();
}

class XBLoadingItem {
  OverlayEntry entry;
  GlobalKey<XBFadeWidgetState> key;
  XBLoadingItem({required this.entry, required this.key});
}

const String _taskShow = "_taskShow";
const String _taskHide = "_taskHide";

class XBLoadingTask {
  String name;
  bool topLeftEnable;
  bool topCenterEnable;
  bool topRightEnable;
  bool contentEnable;
  String? msg;
  Widget? widget;
  XBLoadingTask(this.name,
      {this.topLeftEnable = true,
      this.topCenterEnable = false,
      this.topRightEnable = false,
      this.contentEnable = false,
      this.msg,
      this.widget});
}

Queue<XBLoadingTask> _taskQueue = Queue();

final List<XBLoadingItem> _items = [];

_hideLast() {
  if (_items.isNotEmpty) {
    final lastItem = _items.removeLast();
    if (lastItem.key.currentState != null) {
      lastItem.key.currentState?.hide(() {
        lastItem.entry.remove();
      });
    } else {
      lastItem.entry.remove();
    }
  }
}

_showLoadingGlobal({
  required Widget widget,
  required bool topLeftEnable,
  required bool topCenterEnable,
  required bool topRightEnable,
  required bool contentEnable,
}) {
  _hideLast();
  final overlay = Overlay.of(xbGlobalContext);
  final GlobalKey<XBFadeWidgetState> key = GlobalKey();
  final overlayEntry = OverlayEntry(
    builder: (context) => XBFadeWidget(
      key: key,
      autoShowAnimation: true,
      child: Stack(children: [
        Column(
          children: [
            SizedBox(
              height: topBarH,
              child: Row(
                children: [
                  Expanded(
                      child: Container(
                    color: topLeftEnable ? null : Colors.transparent,
                  )),
                  Expanded(
                      child: Container(
                    color: topCenterEnable ? null : Colors.transparent,
                  )),
                  Expanded(
                      child: Container(
                    color: topRightEnable ? null : Colors.transparent,
                  ))
                ],
              ),
            ),
            Expanded(
                child: Container(
              color: contentEnable ? null : Colors.transparent,
            ))
          ],
        ),
        widget,
      ]),
    ),
  );

  _items.add(XBLoadingItem(entry: overlayEntry, key: key));
  overlay.insert(overlayEntry);
}

_exeTask() {
  if (_taskQueue.isEmpty) {
    return;
  }
  try {
    final task = _taskQueue.first;
    if (task.name == _taskShow) {
      late Widget loadingBody;
      if (task.widget != null) {
        loadingBody = task.widget!;
      } else if (xbLoadingBuilder != null) {
        loadingBody = xbLoadingBuilder!(xbGlobalContext, task.msg);
      } else {
        loadingBody = XBLoadingWidget(
          msg: task.msg,
        );
      }
      _showLoadingGlobal(
          widget: loadingBody,
          topLeftEnable: task.topLeftEnable,
          topCenterEnable: task.topCenterEnable,
          topRightEnable: task.topRightEnable,
          contentEnable: task.contentEnable);
    } else {
      _hideLast();
    }
    _taskQueue.remove(task);
    _exeTask();
  } catch (e) {
    _hideLast();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _exeTask();
    });
  }
}

class XBLoadingWidget extends XBVMLessWidget {
  final String? msg;
  const XBLoadingWidget({this.msg, super.key});

  double get w => 60;

  bool get msgEnable => msg != null && msg!.isNotEmpty;

  @override
  Widget buildWidget(XBVM vm, BuildContext context) {
    return Container(
        alignment: Alignment.center,
        child: Container(
          alignment: Alignment.center,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: XBShadowContainer(
              child: Container(
                color: Colors.white,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(
                          top: 10,
                          left: 10,
                          right: 10,
                          bottom: msgEnable ? 2 : 10),
                      child: SizedBox(
                        height: w,
                        width: w,
                        child: XBAnimationRotate(
                          repeat: true,
                          duration: const Duration(milliseconds: 1000),
                          child: CustomPaint(
                              size: Size(w, w), painter: XBLoadingPainter()),
                        ),
                      ),
                    ),
                    Visibility(
                        visible: msgEnable,
                        child: Material(
                          color: Colors.white,
                          child: Padding(
                            padding: EdgeInsets.only(
                                bottom: msgEnable ? 10 : 0,
                                left: 10,
                                right: 10),
                            child: Text(
                              msg ?? "",
                              overflow: TextOverflow.ellipsis,
                              style:
                                  TextStyle(color: Colors.black.withAlpha(150)),
                            ),
                          ),
                        ))
                  ],
                ),
              ),
            ),
          ),
        ));
  }
}

class XBLoadingPainter extends CustomPainter {
  final Color? color;

  XBLoadingPainter({this.color});

  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2;

    _paint.color = color ?? Colors.black.withAlpha(100);
    _paint.style = PaintingStyle.stroke;
    _paint.strokeWidth = 2.0;
    for (var i = 0; i < 360; i += 40) {
      final midPoint = Offset(center.dx + (radius * cos(i * pi / 180) / 1.4),
          center.dy + (radius * sin(i * pi / 180) / 1.4));

      _paint.style = PaintingStyle.fill;
      canvas.drawCircle(midPoint, (1 + (i * 1.0 / 60) * 0.4) * 1, _paint);
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
