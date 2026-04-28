import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../xb_scaffold.dart';
import 'common/xb_legacy_pop_scope.dart';
import 'configs/xb_color_config.dart';

enum XBStatusBarStyle { light, dark }

abstract class XBPage<T extends XBPageVM> extends XBWidget<T> {
  const XBPage({super.key});

  /// -------------------- build condition --------------------

  /*
  * 如果使用的是CupertinoTab或者原生的tabbar，需要给底部预留tabbar的位置
  * */
  bool needPageContentAdaptTabbar(BuildContext context) => false;

  /// 是否需要安全区域
  bool needSafeArea(BuildContext context) => false;

  /// 是否启动安卓（harmony）物理返回
  bool onAndroidPhysicalBack(BuildContext context) => true;

  /// 屏幕方向改变后，是否需要重新build
  bool needRebuildWhileOrientationChanged(BuildContext context) => false;

  /// 是否需要监听主题变化，默认否
  bool needRebuildWhileAppThemeChanged(BuildContext context) => true;

  /// 是否需要输入框跟随键盘移动
  bool needAdaptKeyboard(BuildContext context) => false;

  /*
   * 返回true，则从屏幕顶部开始展示页面（而不是从状态栏下面开始）
   * 返回true，没有appbar
   * */
  bool needHideAppbar(BuildContext context) => false;

  /// 是否需要沉浸式导航栏
  bool needImmersiveAppbar(BuildContext context) => false;

  /// 是否需要 MediaQuery.removePadding
  bool needRemovePadding(BuildContext context) => true;

  /// 是否启动iOS侧滑返回
  bool needIosGestureBack(BuildContext context) => true;

  /// 在展示loading的时候，是否需要响应navigationBar的左侧部分
  bool needResponseNavigationBarLeftWhileLoading(BuildContext context) => true;

  /// 在展示loading的时候，是否需要响应navigationBar的中间部分
  bool needResponseNavigationBarCenterWhileLoading(BuildContext context) =>
      false;

  /// 在展示loading的时候，是否需要响应navigationBar的右侧部分
  bool needResponseNavigationBarRightWhileLoading(BuildContext context) =>
      false;

  /// 在展示loading的时候，是否需要响应content部分
  bool needResponseContentWhileLoading(BuildContext context) => false;

  /// 是否需要在刚展示页面就展示loading
  bool needInitLoading(BuildContext context) => false;

  /// 是否需要loading
  bool needLoading(BuildContext context) => false;

  /// 是否在触摸时结束编辑
  bool needEndEditingWhileTouch(BuildContext context) => true;

  /// notify是否需要在push动画完成之后
  bool notifyNeedAfterPushAnimation(BuildContext context) => false;

  bool _primary(BuildContext context) => !needHideAppbar(context);

  /// -------------------- build params --------------------

  /// 状态栏风格
  /// needHideAppbar为true时设置无效
  XBStatusBarStyle? statusBarStyle(BuildContext context) => null;

  /// 页面背景
  Widget? backgroundWidget(BuildContext context) => null;

  /// 页面背景颜色
  Color? backgroundColor(BuildContext context) => viewBG;

  /// tabbar的高度
  tabbarHeight(BuildContext context) => tabbarH;

  /// navigationBar的颜色
  Color? navigationBarBGColor(BuildContext context) => naviBarBG;

  /// navigationBar title的颜色
  Color? navigationBarTitleColor(BuildContext context) => naviBarTitle;

  /// navigationBar title的大小
  double? navigationBarTitleSize(BuildContext context) => 16;

  /// navigationBar title的字重
  FontWeight? navigationBarTitleFontWeight(BuildContext context) =>
      app.fontWeights.bold;

  /// 页面的标题
  /// 如果重写了buildTitle，则不生效
  String setTitle(BuildContext context) => "";

  /// 页面push动画时间
  int pushAnimationMilliseconds(BuildContext context) => 450;

  /// 长按时间阈值（毫秒），超过此时间认为是长按，不触发endEditing
  int longPressThresholdMilliseconds(BuildContext context) => 500;

  /// leading的宽度
  double? leadingWidth(BuildContext context) => null;

  /// -------------------- build widgets --------------------

  @override
  Widget buildWidget(BuildContext context) {
    return _XBPageTouchHandler<T>(
      page: this,
      context: context,
      child: _themeConsumerWidget(context),
    );
  }

  Widget _themeConsumerWidget(BuildContext context) {
    if (needRebuildWhileAppThemeChanged(context)) {
      return ChangeNotifierProvider.value(
          value: XBThemeVM(),
          child: Consumer(builder: (ctx, XBThemeVM value, child) {
            return _orientaionWidget(context);
          }));
    } else {
      return _orientaionWidget(context);
    }
  }

  Widget _orientaionWidget(BuildContext context) {
    if (needRebuildWhileOrientationChanged(context)) {
      return OrientationBuilder(builder: (ctx, orientation) {
        return _rootWidget(context);
      });
    } else {
      return _rootWidget(context);
    }
  }

  Widget _rootWidget(BuildContext context) {
    final vm = vmOf(context);
    final onWillPop = vm.onWillPop();
    if (onWillPop == null) {
      return PopScope(
        canPop: true,
        child: _buildLoadingContent(context),
      );
    }
    return XBLegacyPopScope(
      onWillPop: onWillPop as Future<bool> Function(),
      child: _buildLoadingContent(context),
    );
  }

  Widget _buildLoadingContent(BuildContext context) {
    final vm = vmOf(context);
    Widget scaffold = Scaffold(
      key: vm.scaffoldKey,
      drawer: drawer(context),
      endDrawer: endDrawer(context),
      primary: _primary(context),
      backgroundColor: backgroundColor(context),
      resizeToAvoidBottomInset: needAdaptKeyboard(context), //输入框抵住键盘
      appBar: needImmersiveAppbar(context)
          ? null
          : (_primary(context) == false ? null : buildAppBar(context)),
      extendBodyBehindAppBar: needImmersiveAppbar(context),
      body: _buildBodyContent(context),
    );
    if (!needLoading(context)) {
      return scaffold;
    }
    return Stack(
      children: [
        scaffold,
        XBFadeWidget(
          key: vm.loadingWidgetFadeKey,
          initShow: needInitLoading(context),
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
                          color:
                              needResponseNavigationBarLeftWhileLoading(context)
                                  ? null
                                  : Colors.transparent,
                        )),
                        Expanded(
                            child: Container(
                          color: needResponseNavigationBarCenterWhileLoading(
                                  context)
                              ? null
                              : Colors.transparent,
                        )),
                        Expanded(
                            child: Container(
                          color: needResponseNavigationBarRightWhileLoading(
                                  context)
                              ? null
                              : Colors.transparent,
                        ))
                      ],
                    ),
                  ),
                  Expanded(
                      child: Container(
                    color: needResponseContentWhileLoading(context)
                        ? null
                        : Colors.transparent,
                  ))
                ],
              ),
              buildLoading(context),
            ]),
          ),
        )
      ],
    );
  }

  /// 如果需要不同loading，重写此方法
  Widget buildLoading(BuildContext context) {
    final vm = vmOf(context);
    if (xbLoadingBuilder != null) {
      return xbLoadingBuilder!(vm.context, vm.loadingMsg);
    }
    return XBLoadingWidget(msg: vm.loadingMsg);
  }

  Widget _buildBodyContent(BuildContext context) {
    return Builder(
      builder: (context) {
        Widget content = buildPage(context);
        if (needRemovePadding(context)) {
          content = MediaQuery.removePadding(
              removeTop: true,
              removeBottom: true,
              removeLeft: true,
              removeRight: true,
              context: context,
              child: content);
        }
        Widget appBar;
        if (needImmersiveAppbar(context) && needHideAppbar(context) == false) {
          appBar = buildAppBar(context);
        } else {
          appBar = Container(width: double.infinity);
        }
        content = Column(
          children: [appBar, Expanded(child: content)],
        );
        if (needPageContentAdaptTabbar(context)) {
          content = Padding(
            padding:
                EdgeInsets.only(bottom: tabbarHeight(context) + safeAreaBottom),
            child: content,
          );
        }
        if (needSafeArea(context)) {
          content = SafeArea(child: content);
        }
        final bgWidget = backgroundWidget(context);
        if (bgWidget != null) {
          return Stack(
            children: [Positioned.fill(child: bgWidget), content],
          );
        }
        return Container(color: backgroundColor(context), child: content);
      },
    );
  }

  /// 构建主体
  @protected
  Widget buildPage(BuildContext context);

  PreferredSizeWidget buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: needImmersiveAppbar(context)
          ? Colors.transparent
          : navigationBarBGColor(context),
      scrolledUnderElevation: 0.0,
      elevation: 0,
      centerTitle: true,
      actions: actions(context),
      leading: leading(context),
      leadingWidth: leadingWidth(context),
      title: buildTitle(context) ?? _defaultTitle(context),
      systemOverlayStyle: _statusBarStyle(context),
    );
  }

  _statusBarStyle(context) {
    if (statusBarStyle(context) == XBStatusBarStyle.dark) {
      return const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark, // Android 图标颜色
        statusBarBrightness: Brightness.light, // iOS 状态栏颜色
      );
    } else if (statusBarStyle(context) == XBStatusBarStyle.light) {
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
  Widget? leading(BuildContext context) {
    final vm = vmOf(context);
    return XBNavigatorBackBtn(
      onTap: () {
        vm.back();
      },
    );
  }

  /// 构建navigationBar标题
  Widget? buildTitle(BuildContext context) {
    return null;
  }

  Widget _defaultTitle(BuildContext context) {
    return Text(setTitle(context),
        style: TextStyle(
            color: navigationBarTitleColor(context),
            fontWeight: navigationBarTitleFontWeight(context),
            fontSize: navigationBarTitleSize(context)));
  }

  /// 构建navigationBar右侧widget
  List<Widget>? actions(BuildContext context) {
    return null;
  }

  /// 构建drawer
  Widget? drawer(BuildContext context) {
    return null;
  }

  /// 构建endDrawer
  Widget? endDrawer(BuildContext context) {
    return null;
  }
}

/// 处理触摸事件的StatefulWidget，用于区分长按和普通点击
class _XBPageTouchHandler<T extends XBPageVM> extends StatefulWidget {
  final XBPage<T> page;
  final BuildContext context;
  final Widget child;

  const _XBPageTouchHandler({
    required this.page,
    required this.context,
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
              widget.page.longPressThresholdMilliseconds(widget.context);
        }

        // 只有在不是长按的情况下才触发endEditing
        if (!_isLongPress &&
            widget.page.needEndEditingWhileTouch(widget.context)) {
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
