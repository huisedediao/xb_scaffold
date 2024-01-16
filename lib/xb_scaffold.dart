library xb_scaffold;

import 'src/xb_theme/xb_theme_vm.dart';

export './src/xb_page.dart';
export './src/xb_page_vm.dart';
export './src/xb_state.dart';
export './src/xb_stateless_widget.dart';
export './src/xb_widget.dart';
export './src/xb_vmless_widget.dart';
export './src/xb_vm.dart';
export './src/xb_theme/xb_theme_vm.dart';
export './src/common/xb_animation_rotate.dart';
export './src/common/xb_button.dart';
export './src/common/xb_empty_app_bar.dart';
export './src/common/xb_fade_widget.dart';
export './src/common/xb_image.dart';
export './src/common/xb_shadow_container.dart';
export './src/common/xb_navigator_back_btn.dart';
export './src/xb_theme/xb_theme_mixin.dart';
export './src/xb_route_mixin.dart';
export './src/xb_route.dart';

export './src/utils/xb_unique_list.dart';

/// 初始化
/// imgPrefixs图片的前缀，每个主题使用的图片不同，如果没有设置，则使用"assets/images/default/"
initXBScaffold({required List<String> imgPrefixs}) async {
  for (int i = 0; i < imgPrefixs.length; i++) {
    XBThemeVM().setThemeForIndex(XBTheme(imagesPath: imgPrefixs[i]), i);
  }
  return Future.value(1);
}
