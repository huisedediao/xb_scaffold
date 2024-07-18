import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

_XBButtonState? _tappingState;

/// 使用cover的时候，会覆盖掉child上的点击事件
/// 如果需要响应child上的点击事件，使用opacity

enum XBButtonTapEffect {
  cover, //覆盖一层半透明黑色的Container
  opacity, //直接把控件进行一定程度的透明处理
  none //没有效果
}

class XBButton extends StatefulWidget {
  final Widget child;

  /// 是否可点击
  final bool enable;

  /// 不可点击时，child上覆盖的颜色，默认为0.24透明度的白色（外部传入半透明颜色）
  final Color? disableColor;

  /// 点击事件
  final VoidCallback? onTap;

  /// 点击事件，enable == false 时的点击事件
  final VoidCallback? onTapDisable;

  /// 点击效果
  final XBButtonTapEffect effect;

  /// 选择opacity效果的时候，按下的不透明度
  final double? opacityOnTap;

  /// 选择cover的时候,覆盖层的颜色
  final Color? coverEffectColor;

  /// 选择cover的时候，效果的圆角
  final double? coverEffectRadius;

  /// 是否需要点击效果，默认为true
  final bool needTapEffect;

  /// 屏蔽连续点击的间隔，默认0.5s
  final int preventMultiTapMilliseconds;

  const XBButton(
      {required this.child,
      this.enable = true,
      this.disableColor,
      this.onTap,
      this.needTapEffect = true,
      this.opacityOnTap,
      this.effect = XBButtonTapEffect.opacity,
      this.coverEffectColor,
      this.coverEffectRadius,
      this.onTapDisable,
      this.preventMultiTapMilliseconds = 500,
      Key? key})
      : super(key: key);

  @override
  State<XBButton> createState() => _XBButtonState();
}

class _XBButtonState extends State<XBButton> {
  bool _onTapDown = false;

  late XBPreventMultiTask _preventMultiTask;

  @override
  void initState() {
    super.initState();
    _preventMultiTask = XBPreventMultiTask(
        intervalMilliseconds: widget.preventMultiTapMilliseconds);
  }

  _setStateIfMounted() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enable) {
      return GestureDetector(
        onTap: () {
          _preventMultiTask.execute(() {
            widget.onTapDisable?.call();
          });
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            widget.child,
            Container(
              color: widget.disableColor ?? Colors.white38,
              child: Visibility(
                  visible: false,
                  maintainState: true,
                  maintainSize: true,
                  maintainAnimation: true,
                  child: widget.child),
            )
          ],
        ),
      );
    }

    final tapChild = GestureDetector(
      onTap: () {
        _preventMultiTask.execute(() {
          widget.onTap?.call();
        });
      },
      child: _child(),
    );
    if (widget.effect == XBButtonTapEffect.none) {
      return tapChild;
    } else {
      return Listener(
        onPointerDown: (event) {
          if (_tappingState != null) return;
          _tappingState = this;
          _onTapDown = true;
          _setStateIfMounted();
        },
        onPointerUp: (event) {
          if (_tappingState == this) {
            _tappingState = null;
          }
          _onTapDown = false;
          _setStateIfMounted();
        },
        onPointerCancel: (e) {
          if (_tappingState == this) {
            _tappingState = null;
          }
          _onTapDown = false;
          _setStateIfMounted();
        },
        child: tapChild,
      );
    }
  }

  @override
  void didUpdateWidget(covariant XBButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.preventMultiTapMilliseconds !=
        oldWidget.preventMultiTapMilliseconds) {
      _preventMultiTask = XBPreventMultiTask(
          intervalMilliseconds: widget.preventMultiTapMilliseconds);
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
