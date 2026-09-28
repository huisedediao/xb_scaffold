export './src/xb_theme/xb_theme_vm.dart';
export './src/xb_theme/xb_theme_mixin.dart';

export './src/xb_page.dart';
export './src/xb_page_vm.dart';
// xb_widget.dart 是 xb_vm.dart 的 part，其中的 XBWidget/XBWidgetState
// 随下方 export './src/xb_vm.dart' 一并导出，不能单独 export part 文件

export './src/repository/xb_data_source.dart';
export './src/repository/xb_service.dart';
export './src/repository/xb_repository.dart';
export './src/xb_vmless_widget.dart';
export './src/xb_vm.dart'; // 含 part: xb_widget.dart
export './src/xb_select.dart';
export './src/xb_root_widget.dart';
export './src/xb_vm_extensions.dart';

export './src/xb_sys_config.dart';
export './src/xb_sys_space.dart';
export './src/xb_dialog.dart';
export './src/xb_log.dart';
export './src/xb_print.dart';
export './src/xb_action_sheet.dart';
export './src/xb_toast.dart';

export 'src/configs/xb_def.dart';
export 'src/configs/xb_dialog_style.dart';
export 'src/configs/xb_strings.dart';

export 'src/common/xb_common.dart';
export 'src/utils/xb_utils.dart';

export 'src/xb_error/xb_error.dart';

/// 重新导出 provider 的 context.select 扩展：
/// 让业务方无需直接依赖 provider 即可在 XBSelect/XBSelectMulti 的
/// selector 闭包中使用 context.select
export 'package:provider/provider.dart' show SelectContext;

export 'package:xb_scaffold/src/utils/xb_import.dart'
    if (dart.library.html) 'package:xb_scaffold/src/utils/xb_import_html.dart';
