import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class RotatableCell extends XBWidget<RotatableCellVM> {
  const RotatableCell({super.key});

  @override
  RotatableCellVM generateVM(BuildContext context) {
    return RotatableCellVM(context: context);
  }

  @override
  Widget buildWidget(BuildContext context) {
    final vm = vmOf(context);
    return XBRotatableFullscreen(
      controller: vm.fullscreenController,
      onFullscreenChanged: (isFullscreen) {
        debugPrint('全屏状态变化: $isFullscreen');
      },
      childBuilder: (context, maxWidth, maxHeight, isFullscreen) {
        final w = maxWidth;
        final h = maxHeight.isFinite ? maxHeight : w / 16 * 9;
        xbError(
            "isFullscreen:$isFullscreen,maxWidth:$maxWidth,maxHeight:$maxHeight");
        return GestureDetector(
          onTap: () {
            if (vm.fullscreenController.isFullscreen) {
              vm.fullscreenController.exit();
            } else {
              vm.fullscreenController.enter();
            }
          },
          child: Container(
            alignment: Alignment.center,
            // color: colors.randColor,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                // width: !isFullscreen ? maxWidth : null,
                // height: !isFullscreen ? (maxWidth / 16 * 9) : null,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Center(
                  child: Text(
                    '点击下方按钮\n进入全屏',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class RotatableCellVM extends XBVM<RotatableCell> {
  RotatableCellVM({required super.context});
  final XBRotatableFullscreenController fullscreenController =
      XBRotatableFullscreenController();
}
