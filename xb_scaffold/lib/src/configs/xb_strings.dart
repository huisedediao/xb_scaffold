/// XBScaffold 全局默认文案配置（i18n 预留）
///
/// 框架内置 UI 的兜底文案默认为中文；有对外/多语言场景时，
/// 在 app 启动早期调用 [xbSetDefaultStrings] 整体替换，
/// 各调用点的局部参数（如 dialogInput 的 cancelTitle）优先级仍高于此处。
///
/// 解析优先级：局部参数 > 全局 [XBScaffoldStrings] > 各字段默认值。
class XBScaffoldStrings {
  /// 输入对话框的取消按钮（XBDialogInput.cancelTitle 兜底）
  final String dialogInputCancel;

  /// 输入对话框的确定按钮（XBDialogInput.confirmTitle 兜底）
  final String dialogInputConfirm;

  /// 输入对话框内容为空时的提示（XBDialogInput.notEmptyTip 兜底）
  final String dialogInputNotEmptyTip;

  /// 多选 ActionSheet 的取消按钮
  final String actionSheetCancel;

  /// 多选 ActionSheet 的完成按钮
  final String actionSheetDone;

  /// 双击退出应用时的提示（XBScaffold.willExitTip 兜底）
  final String exitAppTip;

  /// 错误页提示语（XBErrorView.message 兜底）
  final String errorViewMessage;

  /// 错误页复制按钮文案（XBErrorView.copyButtonText 兜底）
  final String errorViewCopyButton;

  /// 错误页复制成功提示（XBErrorView.copiedHintText 兜底）
  final String errorViewCopiedHint;

  const XBScaffoldStrings({
    this.dialogInputCancel = '取消',
    this.dialogInputConfirm = '确定',
    this.dialogInputNotEmptyTip = '请输入内容',
    this.actionSheetCancel = '取消',
    this.actionSheetDone = '确定',
    this.exitAppTip = '再按一次退出应用',
    this.errorViewMessage = '页面发生异常，请稍后重试',
    this.errorViewCopyButton = '复制异常',
    this.errorViewCopiedHint = '已复制异常信息',
  });
}
