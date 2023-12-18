import 'package:flutter/material.dart';

import '../xb_state.dart';

/// 使用cover的时候，会覆盖掉child上的点击事件
/// 如果需要响应child上的点击事件，使用opacity

enum XBButtonTapEffect {
  cover, //覆盖一层半透明黑色的Container
  opacity, //直接把控件进行一定程度的透明处理
  none //没有效果
}

class XBButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  final XBButtonTapEffect effect;

  /// 选择opacity效果的时候，按下的不透明度
  final double? opacityOnTap;

  final Color? coverEffectColor;

  /// 选择cover的时候，效果的圆角
  final double? coverEffectRadius;

  /// 是否需要点击效果，默认为true
  final bool needTapEffect;

  const XBButton(
      {required this.child,
      this.onTap,
      this.needTapEffect = true,
      this.opacityOnTap,
      this.effect = XBButtonTapEffect.opacity,
      this.coverEffectColor,
      this.coverEffectRadius,
      Key? key})
      : super(key: key);

  @override
  XBState<XBButton> createState() => _XBButtonState();
}

class _XBButtonState extends XBState<XBButton> {
  bool _onTapDown = false;

  _setStateIfMounted() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final tapChild = GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: _child(),
    );
    if (widget.effect == XBButtonTapEffect.none) {
      return tapChild;
    } else {
      return Listener(
        onPointerDown: (event) {
          _onTapDown = true;
          _setStateIfMounted();
        },
        onPointerUp: (event) {
          _onTapDown = false;
          _setStateIfMounted();
        },
        onPointerCancel: (e) {
          _onTapDown = false;
          _setStateIfMounted();
        },
        child: tapChild,
      );
    }
  }

  Widget _child() {
    if (widget.effect == XBButtonTapEffect.opacity) {
      return Opacity(opacity: _opacityEffectOpacity(), child: widget.child);
    } else {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.coverEffectRadius ?? 0),
        child: Stack(
          alignment: Alignment.center,
          children: [
            widget.child,
            Opacity(
                opacity: _coverEffectOpacity(),
                child: Container(
                  color: widget.coverEffectColor ?? Colors.black.withAlpha(15),
                  child: Visibility(
                      visible: false,
                      maintainState: true,
                      maintainSize: true,
                      maintainAnimation: true,
                      child: widget.child),
                ))
          ],
        ),
      );
    }
  }

  /// 点击的时候才需要透明，所以点击的时候设置透明度
  double _opacityEffectOpacity() {
    if (widget.needTapEffect == false) return 1;
    return _onTapDown ? (widget.opacityOnTap ?? 0.5) : 1.0;
  }

  /// 点击的时候才展示cover，所以点击的时候不透明度为1
  double _coverEffectOpacity() {
    if (widget.needTapEffect == false) return 0.0;
    // return 1.0;
    return _onTapDown ? 1.0 : 0.0;
  }
}
