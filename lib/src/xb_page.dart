import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../xb_scaffold.dart';
import 'common/xb_empty_app_bar.dart';
import 'configs/color_config.dart';

abstract class XBPage<T extends XBVM> extends XBWidget<T> {
  const XBPage({super.key});

  /// -------------------- build condition --------------------

  /*
  * 如果使用的是CupertinoTab或者原生的tabbar，需要给底部预留tabbar的位置
  * */
  bool needPageContentAdaptTabbar() {
    return false;
  }

  /// 是否需要安全区域
  bool needSafeArea() {
    return false;
  }

  /// 是否启动安卓物理返回
  bool onAndroidPhysicalBack() {
    return true;
  }

  /// 屏幕方向改变后，是否需要重新build
  bool needRebuildWhileOrientationChanged() {
    return false;
  }

  /// 是否需要监听主题变化，默认否
  bool needRebuildWhileAppThemeChanged() {
    return false;
  }

  /// 是否需要输入框跟随键盘移动
  bool needAdaptKeyboard() {
    return false;
  }

  /*
   * 返回true，则从屏幕顶部开始展示页面（而不是从状态栏下面开始）
   * 如果返回true，则buildAppBar不可以重写
   * 返回true，没有appbar
   * */
  bool needShowContentFromScreenTop() {
    return false;
  }

  /// 是否启动iOS侧滑返回
  bool needIosGestureBack() {
    return true;
  }

  bool get _primary => !needShowContentFromScreenTop();

  /// -------------------- build params --------------------

  /// 页面背景颜色
  Color? get backgroundColor {
    return viewBG;
  }

  /// tabbar的高度
  tabbarHeight(T vm) {
    return vm.tabbarH;
  }

  /// navigationBar的颜色
  Color? get navigationBarBGColor {
    return naviBarBG;
  }

  /// 页面的标题
  /// 如果重写了buildTitle，则不生效
  String setTitle(T vm) {
    return "";
  }

  /// -------------------- build widgets --------------------

  @override
  Widget buildWidget(T vm, BuildContext context) {
    return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          vm.endEditing;
        },
        child: _themeConsumerWidget(vm));
  }

  Widget _themeConsumerWidget(T vm) {
    if (needRebuildWhileAppThemeChanged()) {
      return Consumer(builder: (ctx, XBThemeVM value, child) {
        return _orientaionWidget(vm);
      });
    } else {
      return _orientaionWidget(vm);
    }
  }

  Widget _orientaionWidget(T vm) {
    if (needRebuildWhileOrientationChanged()) {
      return OrientationBuilder(builder: (ctx, orientation) {
        return _rootWidget(vm);
      });
    } else {
      return _rootWidget(vm);
    }
  }

  Widget _rootWidget(T vm) {
    return WillPopScope(
      onWillPop: _onWillPop(),
      child: Scaffold(
        primary: _primary,
        backgroundColor: backgroundColor,
        resizeToAvoidBottomInset: needAdaptKeyboard(), //输入框抵住键盘
        appBar: _primary == false ? const XBEmptyAppBar() : buildAppBar(vm),
        body: _buildBodyContent(vm),
      ),
    );
  }

  _buildBodyContent(T vm) {
    Widget content = buildPage(vm, vm.context);
    if (needPageContentAdaptTabbar()) {
      content = Padding(
        padding: EdgeInsets.only(bottom: tabbarHeight(vm) + vm.safeAreaBottom),
        child: content,
      );
    }
    if (needSafeArea()) {
      content = SafeArea(child: content);
    }
    return Container(color: backgroundColor, child: content);
  }

  /// 构建主体
  @protected
  Widget buildPage(T vm, BuildContext context);

  PreferredSizeWidget buildAppBar(T vm) {
    return AppBar(
      backgroundColor: navigationBarBGColor,
      elevation: 0,
      centerTitle: true,
      actions: actions(vm),
      leading: leading(vm),
      title: buildTitle(vm) ?? _defaultTitle(vm),
    );
  }

  /// 构建navigationBar左侧widget
  Widget? leading(T vm) {
    return XBNavigatorBackBtn(
      onTap: () {
        vm.pop();
      },
    );
  }

  /// 构建navigationBar标题
  Widget? buildTitle(T vm) {
    return null;
  }

  Widget _defaultTitle(T vm) {
    return Text(setTitle(vm),
        style: TextStyle(
            color: naviBarTitle,
            fontWeight: app.fontWeights.bold,
            fontSize: 16));
  }

  /// 构建navigationBar右侧widget
  List<Widget>? actions(T vm) {
    return null;
  }

  /// -------------------- function --------------------
  /// 即将pop
  _onWillPop() {
    if (Platform.isAndroid) {
      return _androidOnWillPop;
    } else {
      if (needIosGestureBack()) {
        return null;
      } else {
        return _iosOnWillPop;
      }
    }
  }

  /// ios如果用WillPopScope的onWillPop不为null，则返回手势失效，可以用这个控制iOS是否能够返回
  /// 返回结果无影响，因为只要设置了就不能滑动返回
  Future<bool> _iosOnWillPop() async {
    return false;
  }

  /*
   * 只有 安卓 的 手势返回 操作，这个方法才生效
   * 如果需要控制iOS的滑动返回，在NeedIosGestureUtil中配置
   * */
  Future<bool> _androidOnWillPop() async {
    return onAndroidPhysicalBack();
  }
}
