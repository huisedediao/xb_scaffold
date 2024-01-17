import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/configs/color_config.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

dialogWidget({
  required Widget widget,
}) {
  try {
    _dialogWidget(widget: widget);
  } catch (e) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dialogWidget(widget: widget);
    });
  }
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

dialog(
    {required String title,
    required String msg,
    required List<String> btnTitles,
    required ValueChanged<int> onSelected}) {
  dialogWidget(
      widget: Padding(
    padding: EdgeInsets.only(left: spaces.gapLarge, right: spaces.gapLarge),
    child: ClipRRect(
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
              style: TextStyle(
                  fontSize: fontSizes.s18, fontWeight: fontWeights.medium),
            ),
            Padding(
              padding: EdgeInsets.only(
                  left: spaces.gapDef,
                  right: spaces.gapDef,
                  top: spaces.gapLess,
                  bottom: spaces.gapDef),
              child: Text(msg),
            ),
            Container(
              height: onePixel,
              color: lineColor,
            ),
            Row(
              children: _setupBtns(xbGlobalContext, btnTitles, onSelected),
            )
          ],
        ),
      ),
    ),
  ));
}

List<Widget> _setupBtns(BuildContext context, List<String> btnTitles,
    ValueChanged<int> onSelected) {
  if (btnTitles.length == 1) {
    return [
      _buildBtn(btnTitles[0], Colors.blue, () {
        Navigator.of(context, rootNavigator: false).pop();
        onSelected(0);
      })
    ];
  } else {
    return [
      _buildBtn(btnTitles[0], Colors.black, () {
        Navigator.of(context, rootNavigator: false).pop();
        onSelected(0);
      }),
      Container(
        height: 50,
        width: onePixel,
        color: lineColor,
      ),
      _buildBtn(btnTitles[1], Colors.blue, () {
        Navigator.of(context, rootNavigator: false).pop();
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
