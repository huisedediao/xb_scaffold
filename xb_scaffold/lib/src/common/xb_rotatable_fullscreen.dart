import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef XBFullscreenChildBuilder = Widget Function(
  BuildContext context,
  double maxWidth,
  double maxHeight,
  bool isFullscreen,
);

class XBRotatableFullscreenController {
  _XBRotatableFullscreenState? _state;

  bool get isFullscreen => _state?._isFullscreen ?? false;

  Future<void> enter() async => _state?._enterFullscreen();
  Future<void> exit() async => _state?._exitFullscreen();

  Future<void> toggle() async {
    if (isFullscreen) {
      await exit();
    } else {
      await enter();
    }
  }
}

class XBRotatableFullscreen extends StatefulWidget {
  const XBRotatableFullscreen({
    super.key,
    required this.childBuilder,
    required this.controller,
    this.duration = const Duration(milliseconds: 300),
    this.curve = Curves.easeInOut,
    this.backgroundColor = Colors.black,
    this.turns = 0.25,
    this.onFullscreenChanged,
  });

  final XBFullscreenChildBuilder childBuilder;
  final XBRotatableFullscreenController controller;
  final Duration duration;
  final Curve curve;
  final Color backgroundColor;
  final double turns;
  final ValueChanged<bool>? onFullscreenChanged;

  @override
  State<XBRotatableFullscreen> createState() => _XBRotatableFullscreenState();
}

class _XBRotatableFullscreenState extends State<XBRotatableFullscreen> {
  final GlobalKey _childKey = GlobalKey();

  OverlayEntry? _overlayEntry;
  Rect? _startRect;

  bool _isFullscreen = false;
  bool _overlayVisible = false;

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
  }

  @override
  void didUpdateWidget(covariant XBRotatableFullscreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._state = null;
      widget.controller._state = this;
    }
  }

  @override
  void dispose() {
    widget.controller._state = null;
    _overlayEntry?.remove();
    super.dispose();
  }

  Future<void> _enterFullscreen() async {
    if (_isFullscreen) return;

    final rect = _getRect();
    if (rect == null) return;

    _startRect = rect;
    _isFullscreen = true;

    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
    );

    _overlayVisible = false;
    _insertOverlay();

    await WidgetsBinding.instance.endOfFrame;

    _overlayVisible = true;
    _overlayEntry?.markNeedsBuild();

    if (mounted) setState(() {});

    await Future<void>.delayed(widget.duration);
    widget.onFullscreenChanged?.call(true);
  }

  Future<void> _exitFullscreen() async {
    if (!_isFullscreen) return;

    _overlayVisible = false;
    _overlayEntry?.markNeedsBuild();

    await Future<void>.delayed(widget.duration);

    _overlayEntry?.remove();
    _overlayEntry = null;

    _isFullscreen = false;
    widget.onFullscreenChanged?.call(false);

    if (mounted) setState(() {});

    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
  }

  Rect? _getRect() {
    final ctx = _childKey.currentContext;
    if (ctx == null) return null;

    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;

    final offset = box.localToGlobal(Offset.zero);
    return offset & box.size;
  }

  void _insertOverlay() {
    _overlayEntry = OverlayEntry(
      builder: (context) {
        final screen = MediaQuery.sizeOf(context);
        final begin = _startRect ?? Rect.zero;

        return Material(
          type: MaterialType.transparency,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: _overlayVisible ? 1.0 : 0.0,
                  duration: widget.duration,
                  curve: widget.curve,
                  child: Container(color: widget.backgroundColor),
                ),
              ),
              AnimatedPositioned(
                duration: widget.duration,
                curve: widget.curve,
                left: _overlayVisible
                    ? (screen.width - screen.height) / 2
                    : begin.left,
                top: _overlayVisible
                    ? (screen.height - screen.width) / 2
                    : begin.top,
                width: _overlayVisible ? screen.height : begin.width,
                height: _overlayVisible ? screen.width : begin.height,
                child: AnimatedRotation(
                  turns: _overlayVisible ? widget.turns : 0,
                  duration: widget.duration,
                  curve: widget.curve,
                  child: Center(
                    child: SizedBox(
                      width: _overlayVisible ? screen.height : begin.width,
                      height: _overlayVisible ? screen.width : begin.height,
                      child: _buildChild(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  Widget _buildChild() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return widget.childBuilder(
          context,
          constraints.maxWidth,
          constraints.maxHeight,
          _isFullscreen,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _childKey,
      child: Opacity(
        opacity: _isFullscreen ? 0.0 : 1.0,
        alwaysIncludeSemantics: true,
        child: _buildChild(),
      ),
    );
  }
}
