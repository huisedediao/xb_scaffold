import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// loading 示例：页面级 showLoading/hideLoading 与全局 showLoadingGlobal/hideLoadingGlobal
///
/// 页面级：挂在页面上的遮罩，跟随页面路由，走 ValueNotifier 局部订阅，
/// 显隐不会重建页面内容（可打开 rebuild 调试验证）；
/// 全局：挂在 overlay 上，覆盖包括导航栏在内的整个屏幕，不依赖页面。
class XBLoadingDemo extends XBPage<XBLoadingDemoVM> {
  const XBLoadingDemo({super.key});

  @override
  XBLoadingDemoVM generateVM(BuildContext context) =>
      XBLoadingDemoVM(context: context);

  /// 开启页面 loading 能力（不开启时 showLoading 不生效）
  @override
  bool needLoading(BuildContext context) => true;

  @override
  Widget buildPage(BuildContext context) {
    final vm = vmOf(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text('页面级 loading（跟随页面路由）'),
        ),
        XBButtonText(
            text: '显示 2 秒后自动关闭', onTap: () => vm.demoPageLoading()),
        XBButtonText(
            text: '显示（手动关闭）',
            onTap: () => vm.showLoading(msg: '点下方按钮关闭')),
        XBButtonText(text: '隐藏', onTap: () => vm.hideLoading()),
        XBButtonText(
            text: '显示中更新文案',
            onTap: () => vm.demoMsgChange()),
        const SizedBox(height: 30),
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text('全局 loading（overlay 层，覆盖整个屏幕）'),
        ),
        XBButtonText(
            text: '显示 2 秒后自动关闭', onTap: () => vm.demoGlobalLoading()),
        XBButtonText(
            text: '显示自定义 loading 体',
            onTap: () => vm.showGlobalCustomWidget()),
        XBButtonText(text: '关闭全局 loading', onTap: () => hideLoadingGlobal()),
        const SizedBox(height: 30),
        // loading 显示期间点击此按钮：默认被遮罩拦截，无 toast；
        // 重写 needResponseContentWhileLoading 返回 true 可放行
        ElevatedButton(
          onPressed: () => toast('内容按钮被点击'),
          child: const Text('内容按钮（loading 时验证遮罩拦截）'),
        ),
      ],
    );
  }
}

class XBLoadingDemoVM extends XBPageVM<XBLoadingDemo> {
  XBLoadingDemoVM({required super.context});

  /// 页面级 loading：2 秒后自动关闭
  demoPageLoading() {
    showLoading(msg: '加载中...');
    Future.delayed(const Duration(seconds: 2), () {
      // 异步回调前先检查 mounted，避免页面销毁后操作悬空 state
      if (!mounted) return;
      hideLoading();
    });
  }

  /// 显示中更新文案：msg 走 ValueNotifier 局部订阅，只刷新 loading 本体
  demoMsgChange() {
    showLoading(msg: '第一步...');
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      showLoading(msg: '第二步...');
    });
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      hideLoading();
    });
  }

  /// 全局 loading：默认样式（优先级 widget > xbLoadingBuilder > XBLoadingWidget）
  demoGlobalLoading() {
    showLoadingGlobal(msg: '全局加载中...');
    Future.delayed(const Duration(seconds: 2), () {
      hideLoadingGlobal();
    });
  }

  /// 全局 loading：自定义 loading widget。
  /// 注意两点：
  /// 1. loading 体放在 overlay 的 Stack 里，非定位子节点默认左上对齐，
  ///    需要自己包 Center 居中（默认 XBLoadingWidget 自带 alignment 所以不用）
  /// 2. 包 Material 以获得正常文字样式（默认样式下无 Material 祖先时
  ///    debug 会显示黄色双下划线回退样式）
  showGlobalCustomWidget() {
    showLoadingGlobal(
      widget: Material(
        color: Colors.transparent,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(150),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '自定义 loading 体',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ),
    );
    Future.delayed(const Duration(seconds: 2), () {
      hideLoadingGlobal();
    });
  }
}
