import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../xb_scaffold.dart';
import 'configs/xb_color_config.dart';

enum XBStatusBarStyle { light, dark }

abstract class XBPage<T extends XBPageVM> extends XBWidget<T> {
  const XBPage({super.key});

  /// -------------------- build condition --------------------

  /*
  * 如果使用的是CupertinoTab或者原生的tabbar，需要给底部预留tabbar的位置
  * */
  bool needPageContentAdaptTabbar(T vm) => false;

  /// 是否需要安全区域
  bool needSafeArea(T vm) => false;

  /// 是否启动安卓物理返回
  bool onAndroidPhysicalBack(T vm) => true;

  /// 屏幕方向改变后，是否需要重新build
  bool needRebuildWhileOrientationChanged(T vm) => false;

  /// 是否需要监听主题变化，默认否
  bool needRebuildWhileAppThemeChanged(T vm) => true;

  /// 是否需要输入框跟随键盘移动
  bool needAdaptKeyboard(T vm) => false;

  /*
   * 返回true，则从屏幕顶部开始展示页面（而不是从状态栏下面开始）
   * 返回true，没有appbar
   * */
  bool needHideAppbar(T vm) => false;

  /// 是否需要沉浸式导航栏
  bool needImmersiveAppbar(T vm) => false;

  /// 是否启动iOS侧滑返回
  bool needIosGestureBack(T vm) => true;

  /// 在展示loading的时候，是否需要响应navigationBar的左侧部分
  bool needResponseNavigationBarLeftWhileLoading(T vm) => true;

  /// 在展示loading的时候，是否需要响应navigationBar的中间部分
  bool needResponseNavigationBarCenterWhileLoading(T vm) => false;

  /// 在展示loading的时候，是否需要响应navigationBar的右侧部分
  bool needResponseNavigationBarRightWhileLoading(T vm) => false;

  /// 在展示loading的时候，是否需要响应content部分
  bool needResponseContentWhileLoading(T vm) => false;

  /// 是否需要在刚展示页面就展示loading
  bool needInitLoading(T vm) => false;

  /// 是否需要loading
  bool needLoading(T vm) => false;

  /// 是否在触摸时结束编辑
  bool needEndEditingWhileTouch(T vm) => true;

  /// notify是否需要在push动画完成之后
  bool notifyNeedAfterPushAnimation(T vm) => false;

  bool _primary(T vm) => !needHideAppbar(vm);

  /// -------------------- build params --------------------

  /// 状态栏风格
  /// needHideAppbar为true时设置无效
  XBStatusBarStyle? statusBarStyle(T vm) => null;

  /// 页面背景
  Widget? backgroundWidget(T vm) => null;

  /// 页面背景颜色
  Color? backgroundColor(T vm) => viewBG;

  /// tabbar的高度
  tabbarHeight(T vm) => tabbarH;

  /// navigationBar的颜色
  Color? navigationBarBGColor(T vm) => naviBarBG;

  /// navigationBar title的颜色
  Color? navigationBarTitleColor(T vm) => naviBarTitle;

  /// navigationBar title的大小
  double? navigationBarTitleSize(T vm) => 16;

  /// navigationBar title的字重
  FontWeight? navigationBarTitleFontWeight(T vm) => app.fontWeights.bold;

  /// 页面的标题
  /// 如果重写了buildTitle，则不生效
  String setTitle(T vm) => "";

  /// 页面push动画时间
  int pushAnimationMilliseconds(T vm) => 450;

  /// 长按时间阈值（毫秒），超过此时间认为是长按，不触发endEditing
  int longPressThresholdMilliseconds(T vm) => 500;

  /// leading的宽度
  double? leadingWidth(T vm) => null;

  /// -------------------- build widgets --------------------

  @override
  Widget buildWidget(T vm, BuildContext context) {
    return _XBPageTouchHandler<T>(
      page: this,
      vm: vm,
      child: _themeConsumerWidget(vm),
    );
  }

  Widget _themeConsumerWidget(T vm) {
    if (needRebuildWhileAppThemeChanged(vm)) {
      return ChangeNotifierProvider.value(
          value: XBThemeVM(),
          child: Consumer(builder: (ctx, XBThemeVM value, child) {
            return _orientaionWidget(vm);
          }));
    } else {
      return _orientaionWidget(vm);
    }
  }

  Widget _orientaionWidget(T vm) {
    if (needRebuildWhileOrientationChanged(vm)) {
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
      key: vm.scaffoldKey,
      drawer: drawer(vm),
      endDrawer: endDrawer(vm),
      primary: _primary(vm),
      backgroundColor: backgroundColor(vm),
      resizeToAvoidBottomInset: needAdaptKeyboard(vm), //输入框抵住键盘
      appBar: needImmersiveAppbar(vm)
          ? const XBEmptyAppBar()
          : (_primary(vm) == false ? const XBEmptyAppBar() : buildAppBar(vm)),
      extendBodyBehindAppBar: needImmersiveAppbar(vm),
      body: _buildBodyContent(vm),
    );
    if (!needLoading(vm)) {
      return scaffold;
    }
    return Stack(
      children: [
        scaffold,
        XBFadeWidget(
          key: vm.loadingWidgetFadeKey,
          initShow: needInitLoading(vm),
          child: Visibility(
            visible: vm.isShowLoadingWidget,
            child: Stack(children: [
              Column(
                children: [
                  SizedBox(
                    height: topBarH,
                    child: Row(
                      children: [
                        Expanded(
                            child: Container(
                          color: needResponseNavigationBarLeftWhileLoading(vm)
                              ? null
                              : Colors.transparent,
                        )),
                        Expanded(
                            child: Container(
                          color: needResponseNavigationBarCenterWhileLoading(vm)
                              ? null
                              : Colors.transparent,
                        )),
                        Expanded(
                            child: Container(
                          color: needResponseNavigationBarRightWhileLoading(vm)
                              ? null
                              : Colors.transparent,
                        ))
                      ],
                    ),
                  ),
                  Expanded(
                      child: Container(
                    color: needResponseContentWhileLoading(vm)
                        ? null
                        : Colors.transparent,
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
    if (xbLoadingBuilder != null) {
      return xbLoadingBuilder!(xbGlobalContext, vm.loadingMsg);
    }
    return XBLoadingWidget(msg: vm.loadingMsg);
  }

  Widget _buildBodyContent(T vm) {
    return Builder(
      builder: (context) {
        Widget content = buildPage(vm, context);
        Widget appBar;
        if (needImmersiveAppbar(vm) && needHideAppbar(vm) == false) {
          appBar = buildAppBar(vm);
        } else {
          appBar = Container(width: double.infinity);
        }
        content = Column(
          children: [appBar, Expanded(child: content)],
        );
        if (needPageContentAdaptTabbar(vm)) {
          content = Padding(
            padding: EdgeInsets.only(bottom: tabbarHeight(vm) + safeAreaBottom),
            child: content,
          );
        }
        if (needSafeArea(vm)) {
          content = SafeArea(child: content);
        }
        final bgWidget = backgroundWidget(vm);
        if (bgWidget != null) {
          return Stack(
            children: [Positioned.fill(child: bgWidget), content],
          );
        }
        return Container(color: backgroundColor(vm), child: content);
      },
    );
  }

  /// 构建主体
  @protected
  Widget buildPage(T vm, BuildContext context);

  PreferredSizeWidget buildAppBar(T vm) {
    return AppBar(
      backgroundColor: needImmersiveAppbar(vm)
          ? Colors.transparent
          : navigationBarBGColor(vm),
      scrolledUnderElevation: 0.0,
      elevation: 0,
      centerTitle: true,
      actions: actions(vm),
      leading: leading(vm),
      leadingWidth: leadingWidth(vm),
      title: buildTitle(vm) ?? _defaultTitle(vm),
      systemOverlayStyle: _statusBarStyle(vm),
    );
  }

  _statusBarStyle(vm) {
    if (statusBarStyle(vm) == XBStatusBarStyle.dark) {
      return const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark, // Android 图标颜色
        statusBarBrightness: Brightness.light, // iOS 状态栏颜色
      );
    } else if (statusBarStyle(vm) == XBStatusBarStyle.light) {
      return const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light, // Android 图标颜色
        statusBarBrightness: Brightness.dark, // iOS 状态栏颜色
      );
    } else {
      return null;
    }
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
            color: navigationBarTitleColor(vm),
            fontWeight: navigationBarTitleFontWeight(vm),
            fontSize: navigationBarTitleSize(vm)));
  }

  /// 构建navigationBar右侧widget
  List<Widget>? actions(T vm) {
    return null;
  }

  /// 构建drawer
  Widget? drawer(T vm) {
    return null;
  }

  /// 构建endDrawer
  Widget? endDrawer(T vm) {
    return null;
  }
}

/// 处理触摸事件的StatefulWidget，用于区分长按和普通点击
class _XBPageTouchHandler<T extends XBPageVM> extends StatefulWidget {
  final XBPage<T> page;
  final T vm;
  final Widget child;

  const _XBPageTouchHandler({
    required this.page,
    required this.vm,
    required this.child,
  });

  @override
  State<_XBPageTouchHandler<T>> createState() => _XBPageTouchHandlerState<T>();
}

class _XBPageTouchHandlerState<T extends XBPageVM>
    extends State<_XBPageTouchHandler<T>> {
  DateTime? _pointerDownTime;
  bool _isLongPress = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        _pointerDownTime = DateTime.now();
        _isLongPress = false;
      },
      onPointerUp: (event) {
        if (_pointerDownTime != null) {
          final duration = DateTime.now().difference(_pointerDownTime!);
          _isLongPress = duration.inMilliseconds >=
              widget.page.longPressThresholdMilliseconds(widget.vm);
        }

        // 只有在不是长按的情况下才触发endEditing
        if (!_isLongPress && widget.page.needEndEditingWhileTouch(widget.vm)) {
          endEditing(context: context);
        }

        _pointerDownTime = null;
        _isLongPress = false;
      },
      onPointerCancel: (_) {
        _pointerDownTime = null;
        _isLongPress = false;
      },
      child: widget.child,
    );
  }
}
