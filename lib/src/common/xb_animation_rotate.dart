import 'dart:math';

import 'package:flutter/material.dart';

enum XBAnimationRotateAxis { x, y, z }

class XBAnimationRotate extends StatefulWidget {
  final Widget child;
  final XBAnimationRotateAxis axis;
  final bool repeat;
  final double begin;
  final double end;
  final VoidCallback? onDismissed;
  final VoidCallback? onCompleted;
  final VoidCallback? onForward;
  final VoidCallback? onReverse;
  final Duration duration;
  final Duration reverseDuration;

  const XBAnimationRotate(
      {Key? key,
      required this.child,
      this.axis = XBAnimationRotateAxis.z,
      this.repeat = false,
      this.onDismissed,
      this.onCompleted,
      this.onForward,
      this.onReverse,
      this.begin = 0.0,
      double? end,
      Duration? duration,
      Duration? reverseDuration})
      : duration = duration ?? const Duration(milliseconds: 500),
        reverseDuration = reverseDuration ?? const Duration(milliseconds: 500),
        end = end ?? pi * 2,
        super(key: key);

  @override
  State createState() => _XBAnimationRotateState();
}

class _XBAnimationRotateState extends State<XBAnimationRotate>
    with SingleTickerProviderStateMixin {
  AnimationController? _animationController;
  Animation? _rotateAnimation;

  get transform {
    if (widget.axis == XBAnimationRotateAxis.x) {
      return Matrix4.rotationX(_rotateAnimation!.value);
    } else if (widget.axis == XBAnimationRotateAxis.y) {
      return Matrix4.rotationY(_rotateAnimation!.value);
    } else if (widget.axis == XBAnimationRotateAxis.z) {
      return Matrix4.rotationZ(_rotateAnimation!.value);
    }
  }

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
        vsync: this,
        duration: widget.duration,
        reverseDuration: widget.duration);
    CurvedAnimation(parent: _animationController!, curve: Curves.linear);
    _rotateAnimation = Tween(begin: widget.begin, end: widget.end)
        .animate(_animationController!);
    _animationController!.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        if (widget.onDismissed != null) widget.onDismissed!();
      } else if (status == AnimationStatus.completed) {
        if (widget.onCompleted != null) widget.onCompleted!();
      } else if (status == AnimationStatus.forward) {
        if (widget.onForward != null) widget.onForward!();
      } else if (status == AnimationStatus.reverse) {
        if (widget.onReverse != null) widget.onReverse!();
      }
    });
    if (widget.repeat) {
      _animationController!.repeat();
    } else {
      forward();
    }
  }

  forward() {
    _animationController!.forward(from: widget.begin);
  }

  reverse() {
    _animationController!.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animationController!,
      builder: (ctx, child) {
        return Transform(
          transform: transform,
          alignment: Alignment.center,
          child: child,
        );
      },
      child: widget.child,
    );
  }

  @override
  void dispose() {
    _animationController!.dispose();
    super.dispose();
  }
}
