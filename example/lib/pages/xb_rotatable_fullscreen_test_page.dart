import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBRotatableFullscreenTestPage
    extends XBPage<XBRotatableFullscreenTestPageVM> {
  const XBRotatableFullscreenTestPage({super.key});

  @override
  XBRotatableFullscreenTestPageVM generateVM(BuildContext context) {
    return XBRotatableFullscreenTestPageVM(context: context);
  }

  @override
  Color? backgroundColor(BuildContext context) {
    return Colors.white;
  }

  @override
  Widget buildPage(BuildContext context) {
    final vm = vmOf(context);

    return Column(
      children: [
        Expanded(
          child: Column(
            children: [
              XBRotatableFullscreen(
                controller: vm.fullscreenController,
                onFullscreenChanged: (isFullscreen) {
                  debugPrint('全屏状态变化: $isFullscreen');
                },
                child: GestureDetector(
                  onTap: () {
                    if (vm.fullscreenController.isFullscreen) {
                      vm.fullscreenController.exit();
                    }
                  },
                  child: Container(
                    width: screenW,
                    height: screenW / 16 * 9,
                    // color: colors.randColor,
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
              Expanded(child: ListView.builder(itemBuilder: (ctx, index) {
                return Container(
                  height: 50,
                  color: colors.randColor,
                );
              }))
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Colors.white,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              XBButtonText(
                text: '进入全屏',
                backgroundColor: colors.primary,
                style: const TextStyle(color: Colors.white),
                onTap: () {
                  vm.fullscreenController.enter();
                },
              ),
              XBButtonText(
                text: '退出全屏',
                backgroundColor: Colors.grey,
                style: const TextStyle(color: Colors.white),
                onTap: () {
                  vm.fullscreenController.exit();
                },
              ),
              XBButtonText(
                text: '切换全屏',
                backgroundColor: Colors.orange,
                style: const TextStyle(color: Colors.white),
                onTap: () {
                  vm.fullscreenController.toggle();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class XBRotatableFullscreenTestPageVM
    extends XBPageVM<XBRotatableFullscreenTestPage> {
  XBRotatableFullscreenTestPageVM({required super.context});

  final XBRotatableFullscreenController fullscreenController =
      XBRotatableFullscreenController();
}
