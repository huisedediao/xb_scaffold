import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../xb_scaffold.dart';
import 'configs/color_config.dart';

abstract class XBPage<T extends XBPageVM> extends XBWidget<T> {
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
  bool onAndroidPhysicalBack(T vm) {
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

  /// 在展示loading的时候，是否需要相应navigationBar的左侧部分
  bool needResponseNavigationBarLeftWhileLoading() {
    return true;
  }

  /// 在展示loading的时候，是否需要相应navigationBar的中间部分
  bool needResponseNavigationBarCenterWhileLoading() {
    return false;
  }

  /// 在展示loading的时候，是否需要相应navigationBar的右侧部分
  bool needResponseNavigationBarRightWhileLoading() {
    return false;
  }

  /// 是否需要在刚展示页面就展示loading
  bool needInitLoading() {
    return false;
  }

  /// 是否需要loading
  bool needLoading() {
    return false;
  }

  bool get _primary => !needShowContentFromScreenTop();

  /// -------------------- build params --------------------

  /// 页面背景颜色
  Color? get backgroundColor {
    return viewBG;
  }

  /// tabbar的高度
  tabbarHeight(T vm) {
    return tabbarH;
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
          endEditing;
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
      onWillPop: vm.onWillPop(),
      child: _buildLoadingContent(vm),
    );
  }

  Widget _buildLoadingContent(T vm) {
    Widget scaffold = Scaffold(
      primary: _primary,
      backgroundColor: backgroundColor,
      resizeToAvoidBottomInset: needAdaptKeyboard(), //输入框抵住键盘
      appBar: _primary == false ? const XBEmptyAppBar() : buildAppBar(vm),
      body: _buildBodyContent(vm),
    );
    if (!needLoading()) {
      return scaffold;
    }
    return Stack(
      children: [
        scaffold,
        XBFadeWidget(
          key: vm.fadeKey,
          initShow: needInitLoading(),
          child: Visibility(
            visible: vm.isLoading,
            child: Stack(children: [
              Column(
                children: [
                  SizedBox(
                    height: topBarH,
                    child: Row(
                      children: [
                        Expanded(
                            child: Container(
                          color: needResponseNavigationBarLeftWhileLoading()
                              ? null
                              : Colors.transparent,
                        )),
                        Expanded(
                            child: Container(
                          color: needResponseNavigationBarCenterWhileLoading()
                              ? null
                              : Colors.transparent,
                        )),
                        Expanded(
                            child: Container(
                          color: needResponseNavigationBarRightWhileLoading()
                              ? null
                              : Colors.transparent,
                        ))
                      ],
                    ),
                  ),
                  Expanded(
                      child: Container(
                    color: Colors.transparent,
                  ))
                ],
              ),
              buildLoading(vm),
            ]),
          ),
        )
      ],
    );
  }

  /// 如果需要不同loading，重写此方法
  Widget buildLoading(T vm) {
    return const XBLoadingWidget();
  }

  Widget _buildBodyContent(T vm) {
    Widget content = buildPage(vm, vm.context);
    if (needPageContentAdaptTabbar()) {
      content = Padding(
        padding: EdgeInsets.only(bottom: tabbarHeight(vm) + safeAreaBottom),
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
        vm.back();
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
}
