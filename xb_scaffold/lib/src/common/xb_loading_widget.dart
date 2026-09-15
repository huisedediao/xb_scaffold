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

bool get isShowGlobalLoading => _items.isNotEmpty;

/// 修正拼写（Goabol → Global），保留旧名兼容已发布版本的使用方
@Deprecated('Use isShowGlobalLoading instead')
bool get isShowGoabolLoading => isShowGlobalLoading;

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

  /// 执行失败后的重试次数（超过 [_maxTaskRetries] 丢弃，防毒任务每帧无限重试）
  int retryCount = 0;

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
  final overlay = xbOverlayState;
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

/// 任务连续失败重试上限，超过后丢弃并报错，
/// 避免持续性异常（如 overlay 不可用）导致每帧无限重试空转
const int _maxTaskRetries = 3;

_exeTask() {
  while (_taskQueue.isNotEmpty) {
    // 先出队再执行：失败的任务不会滞留队首
    final task = _taskQueue.removeFirst();
    try {
      if (task.name == _taskShow) {
        late Widget loadingBody;
        if (task.widget != null) {
          loadingBody = task.widget!;
        } else if (xbLoadingBuilder != null) {
          loadingBody = xbLoadingBuilder!(xbNavigatorContext, task.msg);
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
    } catch (e, s) {
      task.retryCount++;
      xbError('XBLoadingTask failed (retry ${task.retryCount}/$_maxTaskRetries):\n$e\n$s');
      if (task.retryCount <= _maxTaskRetries) {
        // 一次性失败（如 overlay 尚未就绪）：队首回插保持 FIFO，
        // 调度帧确保下帧重试能执行（静态画面下不会自然出帧）
        _taskQueue.addFirst(task);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _exeTask();
        });
        WidgetsBinding.instance.scheduleFrame();
        return;
      }
      // 连续失败超限：丢弃毒任务，继续处理后续任务
      xbError('XBLoadingTask dropped after $_maxTaskRetries retries');
    }
  }
}

class XBLoadingWidget extends XBVMLessWidget {
  final String? msg;
  const XBLoadingWidget({this.msg, super.key});

  double get w => 60;

  bool get msgEnable => msg != null && msg!.isNotEmpty;

  @override
  Widget buildWidget(BuildContext context) {
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

class XBLoadingMask extends StatelessWidget {
  final bool loading;
  final Widget child;
  final String? text;
  final Color? bgColor;

  const XBLoadingMask({
    super.key,
    required this.loading,
    required this.child,
    this.bgColor,
    this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        if (loading)
          Positioned.fill(
            child: Container(
              color: bgColor ?? Colors.transparent,
              alignment: Alignment.center,
              child: XBLoading(text: text),
            ),
          )
      ],
    );
  }
}

class XBLoading extends StatelessWidget {
  final String? text;

  const XBLoading({super.key, this.text});

  @override
  Widget build(BuildContext context) {
    if (xbLoadingBuilder != null) {
      return xbLoadingBuilder!(context, text);
    }
    return XBLoadingWidget(msg: text);
  }
}
