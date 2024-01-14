import 'dart:async';

import 'package:flutter/material.dart';

class XBFadeWidget extends StatefulWidget {
  final Widget child;

  /// 动画时长
  final int milliseconds;

  /// 是否初始就要展示
  final bool initShow;

  /// 动画帧率
  final int fps;

  const XBFadeWidget(
      {required this.child,
      this.milliseconds = 200,
      this.initShow = false,
      this.fps = 30,
      super.key});

  @override
  State<XBFadeWidget> createState() => XBFadeWidgetState();
}

class XBFadeWidgetState extends State<XBFadeWidget> {
  Timer? _timer;
  double _opacity = 0;
  VoidCallback? _hided;

  @override
  void initState() {
    super.initState();
    if (widget.initShow) {
      _opacity = 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: _opacity,
      child: widget.child,
    );
  }

  /// 变化一次的时间
  int get animationChangeUtil => 1.0 * 1000 ~/ widget.fps;

  int get _animationTime => widget.milliseconds ~/ changeTime;

  int get changeTime =>
      (1.0 * widget.milliseconds / animationChangeUtil).ceil();

  double get _opacityStep => 1.0 / changeTime;

  show() {
    _startShowTimer();
  }

  hide(VoidCallback done) {
    _hided = done;
    _startHideTimer();
  }

  _refresh() {
    try {
      setState(() {});
    } catch (e) {}
  }

  _startShowTimer() {
    _stopTimer();
    _timer = Timer.periodic(Duration(milliseconds: _animationTime), (timer) {
      _opacity += _opacityStep;
      if (_opacity >= 1) {
        _opacity = 1;
        _stopTimer();
      }
      _refresh();
    });
  }

  _startHideTimer() {
    _stopTimer();
    _timer = Timer.periodic(Duration(milliseconds: _animationTime), (timer) {
      _opacity -= _opacityStep;
      if (_opacity <= 0) {
        _opacity = 0;
        if (_hided != null) {
          _hided!();
        }
        _stopTimer();
      }
      _refresh();
    });
  }

  _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopTimer();
    super.dispose();
  }
}
