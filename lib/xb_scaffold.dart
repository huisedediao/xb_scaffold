library xb_scaffold;

import 'dart:async';

import 'package:flutter/material.dart';
import './src/xb_navigator_observer.dart';
import 'src/xb_theme/xb_theme_vm.dart';

export './src/xb_page.dart';
export './src/xb_page_vm.dart';
export './src/xb_widget.dart';
export './src/xb_vmless_widget.dart';
export './src/xb_vm.dart';
export './src/xb_theme/xb_theme_vm.dart';
export './src/common/xb_animation_rotate.dart';
export './src/common/xb_button.dart';
export './src/common/xb_empty_app_bar.dart';
export './src/common/xb_fade_widget.dart';
export './src/common/xb_image.dart';
export './src/common/xb_file_image.dart';
export './src/common/xb_shadow_container.dart';
export './src/common/xb_loading_widget.dart';
export './src/common/xb_navigator_back_btn.dart';
export './src/common/xb_hovering_header_list/xb_hovering_header_list.dart';
export './src/xb_theme/xb_theme_mixin.dart';
export './src/xb_route.dart';
export './src/xb_life_cycle_mixin.dart';

export './src/utils/xb_unique_list.dart';
export './src/utils/xb_stack_list.dart';
export './src/utils/xb_img_size_util.dart';
export './src/utils/xb_refresh_task/xb_refresh_task_util.dart';
export './src/xb_sys_space.dart';
export './src/xb_dialog.dart';
export './src/xb_action_sheet.dart';
export './src/xb_toast.dart';
export './src/xb_tip.dart';

/// 路由栈监听
XBNavigatorObserver _xbRouteObserver = XBNavigatorObserver();
XBNavigatorObserver get xbRouteObserver => _xbRouteObserver;
final StreamController<XBStackChangedEvent> _xbRouteStackStreamController =
    StreamController<XBStackChangedEvent>.broadcast();
StreamController<XBStackChangedEvent> get xbStackStreamController =>
    _xbRouteStackStreamController;
Stream<XBStackChangedEvent> get xbRouteStackStream =>
    _xbRouteStackStreamController.stream;

/// 全局BuildContext
late BuildContext _xbGlobalContext;
BuildContext get xbGlobalContext => _xbGlobalContext;

/// 结束输入框编辑
void get endEditing => FocusScope.of(xbGlobalContext).requestFocus(FocusNode());

/// 用于外部控制loading要长什么样
typedef XBLoadingBuilder = Widget Function(BuildContext context);
XBLoadingBuilder? _xbLoadingBuilder;
XBLoadingBuilder? get xbLoadingBuilder => _xbLoadingBuilder;

/// toast的背景颜色
Color? _xbToastBackgroundColor;
Color? get xbToastBackgroundColor => _xbToastBackgroundColor;

class XBScaffold extends StatefulWidget {
  final Widget child;

  /// 图片路径，区分主题
  final List<String> imgPrefixs;

  /// loading要长什么样
  final XBLoadingBuilder? loadingBuilder;

  /// toast的背景颜色
  final Color? toastBackgroundColor;

  const XBScaffold(
      {required this.child,
      required this.imgPrefixs,
      this.loadingBuilder,
      this.toastBackgroundColor,
      super.key});

  @override
  State<XBScaffold> createState() => _MyWidgetState();
}

class _MyWidgetState extends State<XBScaffold> {
  @override
  void initState() {
    super.initState();
    _xbLoadingBuilder = widget.loadingBuilder;
    _xbToastBackgroundColor = widget.toastBackgroundColor;
    _initXBScaffold(imgPrefixs: widget.imgPrefixs);
  }

  @override
  Widget build(BuildContext context) {
    _xbGlobalContext = context;
    return widget.child;
  }
}

/// 初始化
/// imgPrefixs图片的前缀，每个主题使用的图片不同，如果没有设置，则使用"assets/images/default/"
_initXBScaffold({required List<String> imgPrefixs}) async {
  for (int i = 0; i < imgPrefixs.length; i++) {
    XBThemeVM().setThemeForIndex(XBTheme(imagesPath: imgPrefixs[i]), i);
  }
  return Future.value(1);
}
