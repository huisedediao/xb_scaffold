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
        item('设备密码输入风格（设计稿）', vm.showDevicePasswordStyle),
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

  /// 设计稿风格：白色圆角卡片 + 居中标题 + 灰色圆角输入框
  /// + 胶囊按钮（取消浅灰、确定青色渐变白字）
  void showDevicePasswordStyle() {
    xbSetDialogStyle(XBDialogStyle(
      radius: 16,
      titleStyle: const TextStyle(
          fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black),
      partBuilders: XBDialogPartBuilders(
        buttons: (context, style) => const _PillButtons(),
      ),
    ));
    dialogContent(
      title: '请输入设备密码',
      content: const _DevicePasswordBody(),
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

/// 设备密码弹窗内容区（设计稿还原）
class _DevicePasswordBody extends StatelessWidget {
  const _DevicePasswordBody();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '4329d34f23948****shd4',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: Colors.black),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'a***n',
                style: TextStyle(fontSize: 16, color: Colors.black),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '密码长度8-64位，由字母+数字组成',
                      style:
                          TextStyle(fontSize: 13, color: Color(0xFFB9B9B9)),
                    ),
                  ),
                  Icon(Icons.visibility_off,
                      size: 18, color: Color(0xFFB9B9B9)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '若忘记密码，请恢复出厂设置重新添加！',
          style: TextStyle(fontSize: 14, color: Colors.black),
        ),
      ],
    );
  }
}

/// 胶囊按钮行（替换默认分隔线 + 按钮行，pop 由自身调用）
class _PillButtons extends StatelessWidget {
  const _PillButtons();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                xbNavigatorState.pop();
              },
              child: Container(
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F0F0),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Text(
                  '取消',
                  style: TextStyle(fontSize: 16, color: Colors.black),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: GestureDetector(
              onTap: () {
                xbNavigatorState.pop();
              },
              child: Container(
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4FD9C6), Color(0xFF1FC8B7)],
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Text(
                  '确定',
                  style: TextStyle(
                      fontSize: 16,
                      color: Colors.white,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}