import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// XBDialogStyle 全局样式定制演示：
/// 结构不变，通过 xbSetDialogStyle 切换各部分样式 / 分区 builder。
class XBDialogStyleDemo extends XBPage<XBDialogStyleDemoVM> {
  const XBDialogStyleDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XBDialogStyleDemoVM(context: context);
  }

  @override
  Widget buildPage(BuildContext context) {
    final vm = vmOf(context);
    Widget item(String title, VoidCallback onTap) {
      return XBCellCenterTitle(
        contentHeight: 50,
        title: title,
        onTap: onTap,
      );
    }

    return ListView(
      children: [
        item('默认样式 dialog', vm.showDefault),
        item('深色卡片样式（xbSetDialogStyle）', vm.showDarkStyle),
        item('自定义按钮区 builder', vm.showCustomButtons),
        item('恢复框架默认样式', vm.resetStyle),
      ],
    );
  }
}

class XBDialogStyleDemoVM extends XBPageVM<XBDialogStyleDemo> {
  XBDialogStyleDemoVM({required super.context});

  void showDefault() {
    dialog(
      title: '提示',
      msg: '当前样式：框架默认（白色卡片、圆角 10）',
      btnTitles: const ['确定'],
      onSelected: (_) {},
    );
  }

  void showDarkStyle() {
    xbSetDialogStyle(const XBDialogStyle(
      backgroundColor: Color(0xFF2C2C2E),
      radius: 16,
      titleStyle: TextStyle(
          fontSize: 18, color: Colors.white, fontWeight: FontWeight.w600),
      msgStyle: TextStyle(fontSize: 15, color: Colors.white70),
      lineColor: Colors.white24,
      btnDefaultColor: Colors.white70,
      btnHighLightColor: Colors.amber,
    ));
    dialog(
      title: '提示',
      msg: '当前样式：深色卡片（radius 16、amber 高亮按钮）',
      btnTitles: const ['取消', '确定'],
      onSelected: (_) {},
    );
  }

  void showCustomButtons() {
    xbSetDialogStyle(XBDialogStyle(
      partBuilders: XBDialogPartBuilders(
        // 按钮区被完全替换，pop 由业务方自行调用
        buttons: (context, style) => Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () {
                  xbNavigatorState.pop();
                },
                child: const Text('知道了'),
              ),
            ),
          ],
        ),
      ),
    ));
    dialog(
      title: '提示',
      msg: '当前样式：底部按钮区由 builder 渲染',
      btnTitles: const ['取消', '确定'],
      onSelected: (_) {},
    );
  }

  void resetStyle() {
    xbSetDialogStyle(null);
    dialog(
      title: '已恢复默认',
      msg: '传 null 即回退框架默认样式',
      btnTitles: const ['确定'],
      onSelected: (_) {},
    );
  }
}
