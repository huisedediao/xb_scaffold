/*
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBReplaceKeywordTest extends XBPage<XBReplaceKeywordTestVM> {
  const XBReplaceKeywordTest({super.key});

  @override
  List<Widget>? actions(BuildContext context) {
    return super.actions(context);
  }

  @override
  PreferredSizeWidget buildAppBar(BuildContext context) {
    // TODO: implement buildAppBar
    return super.buildAppBar(context);
  }

  @override
  Widget buildLoading(BuildContext context) {
    // TODO: implement buildLoading
    return super.buildLoading(context);
  }

  @override
  generateVM(BuildContext context) {
    return XBReplaceKeywordTestVM(context: context);
  }

  /*
  * 如果使用的是CupertinoTab或者原生的tabbar，需要给底部预留tabbar的位置
  * */
  @override
  bool needPageContentAdaptTabbar(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 是否需要安全区域
  @override
  bool needSafeArea(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 是否启动安卓（harmony）物理返回
  @override
  bool onAndroidPhysicalBack(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 屏幕方向改变后，是否需要重新build
  @override
  bool needRebuildWhileOrientationChanged(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 是否需要监听主题变化，默认否
  @override
  bool needRebuildWhileAppThemeChanged(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 是否需要输入框跟随键盘移动
  @override
  bool needAdaptKeyboard(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /*
   * 返回true，则从屏幕顶部开始展示页面（而不是从状态栏下面开始）
   * 返回true，没有appbar
   * */
  @override
  bool needHideAppbar(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 是否需要沉浸式导航栏
  @override
  bool needImmersiveAppbar(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 是否需要 MediaQuery.removePadding
  @override
  bool needRemovePadding(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 是否启动iOS侧滑返回
  @override
  bool needIosGestureBack(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 在展示loading的时候，是否需要响应navigationBar的左侧部分
  @override
  bool needResponseNavigationBarLeftWhileLoading(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 在展示loading的时候，是否需要响应navigationBar的中间部分
  @override
  bool needResponseNavigationBarCenterWhileLoading(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 在展示loading的时候，是否需要响应navigationBar的右侧部分
  @override
  bool needResponseNavigationBarRightWhileLoading(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 在展示loading的时候，是否需要响应content部分
  @override
  bool needResponseContentWhileLoading(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 是否需要在刚展示页面就展示loading
  @override
  bool needInitLoading(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 是否需要loading
  @override
  bool needLoading(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// 是否在触摸时结束编辑
  @override
  bool needEndEditingWhileTouch(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// notify是否需要在push动画完成之后
  @override
  bool notifyNeedAfterPushAnimation(XBReplaceKeywordTestVM vm) {
    return false;
  }

  /// -------------------- build params --------------------

  /// 状态栏风格
  /// needHideAppbar为true时设置无效
  @override
  XBStatusBarStyle? statusBarStyle(XBReplaceKeywordTestVM vm) {
    return null;
  }

  /// 页面背景
  @override
  Widget? backgroundWidget(XBReplaceKeywordTestVM vm) {
    return null;
  }

  /// 页面背景颜色
  @override
  Color? backgroundColor(XBReplaceKeywordTestVM vm) {
    return null;
  }

  /// tabbar的高度
  @override
  double tabbarHeight(XBReplaceKeywordTestVM vm) {
    return tabbarH;
  }

  /// navigationBar的颜色
  @override
  Color? navigationBarBGColor(XBReplaceKeywordTestVM vm) {
    return null;
  }

  /// navigationBar title的颜色
  @override
  Color? navigationBarTitleColor(XBReplaceKeywordTestVM vm) {
    return null;
  }

  /// navigationBar title的大小
  @override
  double? navigationBarTitleSize(XBReplaceKeywordTestVM vm) {
    return null;
  }

  /// navigationBar title的字重
  @override
  FontWeight? navigationBarTitleFontWeight(XBReplaceKeywordTestVM vm) {
    return null;
  }

  /// 页面的标题
  /// 如果重写了buildTitle，则不生效
  @override
  String setTitle(XBReplaceKeywordTestVM vm) {
    return "";
  }

  /// 页面push动画时间
  @override
  int pushAnimationMilliseconds(XBReplaceKeywordTestVM vm) {
    return 450;
  }

  /// 长按时间阈值（毫秒），超过此时间认为是长按，不触发endEditing
  @override
  int longPressThresholdMilliseconds(XBReplaceKeywordTestVM vm) {
    return 500;
  }

  /// leading的宽度
  @override
  double? leadingWidth(XBReplaceKeywordTestVM vm) {
    return null;
  }

  @override
  Widget buildPage(BuildContext context) {
    return Container();
  }
}

class XBReplaceKeywordTestVM extends XBPageVM<XBReplaceKeywordTest> {
  XBReplaceKeywordTestVM({required super.context});
}
*/
