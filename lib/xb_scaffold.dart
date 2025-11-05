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
export './src/xb_vm_extensions.dart';
export './src/xb_theme/xb_theme_vm.dart';
export './src/common/xb_animation_rotate.dart';
export 'src/common/xb_button/xb_button.dart';
export 'src/common/xb_button/xb_button_text.dart';
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

export './src/utils/xb_unique_list.dart';
export './src/utils/xb_stack_list.dart';
export './src/utils/xb_select_model.dart';
export './src/utils/xb_timer.dart';
export './src/utils/xb_text_size_util.dart';
export './src/utils/xb_img_size_util.dart';
export 'src/utils/xb_prevent_multi_task.dart';
export 'src/utils/xb_wait_task.dart';
export 'src/utils/xb_event_bus.dart';
export './src/utils/xb_refresh_task/xb_refresh_task_util.dart';
export './src/xb_sys_config.dart';
export './src/xb_sys_space.dart';
export './src/xb_dialog.dart';
export './src/xb_log.dart';
export './src/xb_print.dart';
export './src/xb_action_sheet.dart';
export './src/xb_toast.dart';
export 'src/common/xb_float_widget/xb_float_widget.dart';
export 'src/common/xb_table/xb_table.dart';
export 'src/utils/xb_parse.dart';
export './src/network/xb_http.dart';
export 'src/common/xb_cell/xb_cell.dart';
export 'src/common/xb_line.dart';
export 'src/common/xb_title_picker/xb_title_picker.dart';
export 'src/common/xb_title_picker/xb_title_picker_index.dart';
export 'src/common/xb_title_picker/xb_title_picker_multi.dart';
export 'src/configs/xb_def.dart';
export 'src/common/xb_bg.dart';
export 'src/common/xb_gradient_widget.dart';
export 'src/common/xb_disable.dart';
export 'src/common/xb_text_field/xb_text_field.dart';
export 'src/common/xb_text_field/xb_text_input_formatter.dart';
export 'package:xb_scaffold/src/utils/xb_import.dart'
    if (dart.library.html) 'package:xb_scaffold/src/utils/xb_import_html.dart';

/// 页面展示隐藏监听
final RouteObserver<ModalRoute<void>> xbRrouteObserver =
    RouteObserver<ModalRoute<void>>();

/// 路由栈监听
XBNavigatorObserver _xbNavigatorObserver = XBNavigatorObserver();
XBNavigatorObserver get xbNavigatorObserver => _xbNavigatorObserver;
final StreamController<XBStackChangedEvent> _xbRouteStackStreamController =
    StreamController<XBStackChangedEvent>.broadcast();
StreamController<XBStackChangedEvent> get xbStackStreamController =>
    _xbRouteStackStreamController;
Stream<XBStackChangedEvent> get xbRouteStackStream =>
    _xbRouteStackStreamController.stream;

/// 全局BuildContext
late BuildContext _xbGlobalContext;
bool _isInitXBScaffold = false;
BuildContext get xbGlobalContext {
  if (_isInitXBScaffold) {
    return _xbGlobalContext;
  }
  assert(tempContext != null, "请初始化XBScaffold或者设置tempContext");
  return tempContext!;
}

BuildContext? tempContext;

/// 结束输入框编辑
void endEditing({BuildContext? context}) =>
    FocusScope.of(context ?? xbGlobalContext).requestFocus(FocusNode());

/// 用于外部控制loading要长什么样
typedef XBLoadingBuilder = Widget Function(BuildContext context, String? msg);
XBLoadingBuilder? _xbLoadingBuilder;
XBLoadingBuilder? get xbLoadingBuilder => _xbLoadingBuilder;

/// toast的背景颜色
Color? _xbToastBackgroundColor;
Color? get xbToastBackgroundColor => _xbToastBackgroundColor;

/// max page log len
int? _maxPageLogLen;
int? get maxPageLogLen => _maxPageLogLen;

class XBScaffold extends StatefulWidget {
  final Widget child;

  /// 图片路径，区分主题
  final List<XBThemeConfig> themeConfigs;

  /// loading要长什么样
  final XBLoadingBuilder? loadingBuilder;

  /// toast的背景颜色
  final Color? toastBackgroundColor;

  /// max page log len, 默认30
  final int? maxPageLogLen;

  const XBScaffold(
      {required this.child,
      required this.themeConfigs,
      this.loadingBuilder,
      this.toastBackgroundColor,
      this.maxPageLogLen,
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
    _maxPageLogLen = widget.maxPageLogLen;
    _initXBScaffold(configs: widget.themeConfigs);
  }

  @override
  Widget build(BuildContext context) {
    _xbGlobalContext = context;
    _isInitXBScaffold = true;
    return widget.child;
  }
}

/// 初始化
/// imgPrefixs图片的前缀，每个主题使用的图片不同，如果没有设置，则使用"assets/images/default/"
_initXBScaffold({required List<XBThemeConfig> configs}) async {
  for (int i = 0; i < configs.length; i++) {
    XBThemeVM().setThemeForIndex(
        XBTheme(
            config: XBThemeConfig(
                imgPrefix: configs[i].imgPrefix,
                primaryColor: configs[i].primaryColor)),
        i);
  }
  return Future.value(1);
}
