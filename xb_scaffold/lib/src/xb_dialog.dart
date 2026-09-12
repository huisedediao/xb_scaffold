import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/configs/xb_color_config.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'common/xb_dialog_manager.dart';
export 'common/xb_dialog_input.dart';

dialogWidget(Widget widget, {int priority = 0}) {
  XBDialogManager().show(widget: widget, priority: priority);
}

dialogContent(
    {required String title,
    TextStyle? titleStyle,
    required Widget content,
    required List<String> btnTitles,
    Color? btnHighLightColor,
    Color? btnDefaultColor,
    double? btnFontSize,
    required ValueChanged<int> onSelected,
    double? maxWidth,
    int priority = 0}) {
  final style = xbDialogStyle;
  final builders = style?.partBuilders;
  final separatorColor = style?.lineColor ?? lineColor;
  final btnHeight = style?.btnHeight ?? 50;
  Widget child = ClipRRect(
    borderRadius: BorderRadius.circular(style?.radius ?? 10),
    child: Container(
      color: style?.backgroundColor ?? Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          XBDialogPart(
            builder: builders?.title,
            defaultChild: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: spaces.gapDef,
                ),
                Text(
                  title,
                  style: titleStyle ??
                      style?.titleStyle ??
                      TextStyle(
                          fontSize: fontSizes.s18,
                          fontWeight: fontWeights.medium),
                ),
              ],
            ),
          ),
          XBDialogPart(
            builder: builders?.content,
            defaultChild: Padding(
              padding: style?.contentPadding ??
                  EdgeInsets.only(
                      left: spaces.gapDef,
                      right: spaces.gapDef,
                      top: spaces.gapLess,
                      bottom: spaces.gapDef),
              child: content,
            ),
          ),
          XBDialogPart(
            builder: builders?.buttons,
            defaultChild: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: onePixel,
                  color: separatorColor,
                ),
                Row(
                  children: _setupBtns(
                      btnTitles: btnTitles,
                      onSelected: onSelected,
                      btnHighLightColor:
                          btnHighLightColor ?? style?.btnHighLightColor,
                      btnDefaultColor:
                          btnDefaultColor ?? style?.btnDefaultColor,
                      fontSize:
                          btnFontSize ?? style?.btnFontSize ?? fontSizes.s16,
                      btnHeight: btnHeight,
                      separatorColor: separatorColor),
                )
              ],
            ),
          ),
        ],
      ),
    ),
  );
  if (maxWidth != null) {
    if (maxWidth > screenW - spaces.gapDef * 2) {
      maxWidth = screenW - spaces.gapDef * 2;
    }
    dialogWidget(SizedBox(width: maxWidth, child: child), priority: priority);
  } else {
    dialogWidget(Padding(
      padding: EdgeInsets.only(left: spaces.gapLarge, right: spaces.gapLarge),
      child: child,
    ), priority: priority);
  }
}

dialog(
    {required String title,
    TextStyle? titleStyle,
    required String msg,
    TextStyle? msgStyle,
    required List<String> btnTitles,
    Color? btnHighLightColor,
    Color? btnDefaultColor,
    double? btnFontSize,
    required ValueChanged<int> onSelected,
    double? maxWidth,
    int priority = 0}) {
  dialogContent(
      title: title,
      titleStyle: titleStyle,
      content: Text(msg,
          style: msgStyle ??
              xbDialogStyle?.msgStyle ??
              TextStyle(
                  fontSize: fontSizes.s15, color: const Color(0xFF808080))),
      btnTitles: btnTitles,
      onSelected: onSelected,
      btnHighLightColor: btnHighLightColor,
      btnDefaultColor: btnDefaultColor,
      btnFontSize: btnFontSize,
      maxWidth: maxWidth,
      priority: priority);
}

List<Widget> _setupBtns({
  required List<String> btnTitles,
  required ValueChanged<int> onSelected,
  required Color? btnHighLightColor,
  required Color? btnDefaultColor,
  required double fontSize,
  required double btnHeight,
  required Color separatorColor,
}) {
  if (btnTitles.length == 1) {
    return [
      _buildBtn(btnTitles[0], btnHighLightColor ?? colors.primary, fontSize,
          btnHeight, () {
        xbNavigatorState.pop();
        onSelected(0);
      })
    ];
  } else {
    return [
      _buildBtn(btnTitles[0], btnDefaultColor ?? Colors.black, fontSize,
          btnHeight, () {
        xbNavigatorState.pop();
        onSelected(0);
      }),
      Container(
        height: btnHeight,
        width: onePixel,
        color: separatorColor,
      ),
      _buildBtn(btnTitles[1], btnHighLightColor ?? colors.primary, fontSize,
          btnHeight, () {
        xbNavigatorState.pop();
        onSelected(1);
      })
    ];
  }
}

Widget _buildBtn(String title, Color color, double fontSize, double height,
    VoidCallback onTap) {
  return Expanded(
      child: XBButton(
          effect: XBButtonTapEffect.cover,
          onTap: onTap,
          child: Container(
            height: height,
            alignment: Alignment.center,
            child: Text(
              title,
              style: TextStyle(color: color, fontSize: fontSize),
            ),
          )));
}
