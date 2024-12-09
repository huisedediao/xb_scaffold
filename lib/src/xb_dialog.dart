import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/configs/xb_color_config.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
export 'common/xb_dialog_input.dart';

dialogWidget(Widget widget) {
  try {
    _dialogWidget(widget: widget);
  } catch (e) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dialogWidget(widget: widget);
    });
  }
}

dialogContent(
    {required String title,
    TextStyle? titleStyle,
    required Widget content,
    required List<String> btnTitles,
    Color? btnHighLightColor,
    Color? btnDefaultColor,
    required ValueChanged<int> onSelected,
    double? maxWidth}) {
  Widget child = ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: Container(
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: spaces.gapDef,
          ),
          Text(
            title,
            style: titleStyle ??
                TextStyle(
                    fontSize: fontSizes.s18, fontWeight: fontWeights.semiBold),
          ),
          Padding(
            padding: EdgeInsets.only(
                left: spaces.gapDef,
                right: spaces.gapDef,
                top: spaces.gapLess,
                bottom: spaces.gapDef),
            child: content,
          ),
          Container(
            height: onePixel,
            color: lineColor,
          ),
          Row(
            children: _setupBtns(
                btnTitles: btnTitles,
                onSelected: onSelected,
                btnHighLightColor: btnHighLightColor,
                btnDefaultColor: btnDefaultColor),
          )
        ],
      ),
    ),
  );
  if (maxWidth != null) {
    if (maxWidth > screenW - spaces.gapDef * 2) {
      maxWidth = screenW - spaces.gapDef * 2;
    }
    dialogWidget(SizedBox(width: maxWidth, child: child));
  } else {
    dialogWidget(Padding(
      padding: EdgeInsets.only(left: spaces.gapLarge, right: spaces.gapLarge),
      child: child,
    ));
  }
}

dialog(
    {required String title,
    TextStyle? titleStyle,
    required String msg,
    required List<String> btnTitles,
    Color? btnHighLightColor,
    Color? btnDefaultColor,
    required ValueChanged<int> onSelected,
    double? maxWidth}) {
  dialogContent(
      title: title,
      titleStyle: titleStyle,
      content: Text(msg),
      btnTitles: btnTitles,
      onSelected: onSelected,
      btnHighLightColor: btnHighLightColor,
      btnDefaultColor: btnDefaultColor,
      maxWidth: maxWidth);
}

_dialogWidget({
  required Widget widget,
}) {
  showDialog(
    barrierDismissible: false,
    context: xbGlobalContext,
    builder: (BuildContext context) {
      return WillPopScope(
        onWillPop: () async {
          return false;
        },
        child: Padding(
          padding: const EdgeInsets.only(bottom: 50),
          child: Material(
              type: MaterialType.transparency,
              child: Container(alignment: Alignment.center, child: widget)),
        ),
      );
    },
  );
}

List<Widget> _setupBtns({
  required List<String> btnTitles,
  required ValueChanged<int> onSelected,
  required Color? btnHighLightColor,
  required Color? btnDefaultColor,
}) {
  if (btnTitles.length == 1) {
    return [
      _buildBtn(btnTitles[0], btnHighLightColor ?? Colors.blue, () {
        pop();
        onSelected(0);
      })
    ];
  } else {
    return [
      _buildBtn(btnTitles[0], btnDefaultColor ?? Colors.black, () {
        pop();
        onSelected(0);
      }),
      Container(
        height: 50,
        width: onePixel,
        color: lineColor,
      ),
      _buildBtn(btnTitles[1], btnHighLightColor ?? Colors.blue, () {
        pop();
        onSelected(1);
      })
    ];
  }
}

Widget _buildBtn(String title, Color color, VoidCallback onTap) {
  return Expanded(
      child: XBButton(
          effect: XBButtonTapEffect.cover,
          onTap: onTap,
          child: Container(
            height: 50,
            alignment: Alignment.center,
            child: Text(
              title,
              style: TextStyle(color: color),
            ),
          )));
}
