import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/configs/color_config.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

extension XBVMDialog on XBVM {
  static dialogWidgetStatic({
    required BuildContext context,
    required Widget widget,
  }) {
    showDialog(
      barrierDismissible: false,
      context: context,
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

  /// dialog的形式展示一个widget
  dialogWidget({required Widget widget}) {
    dialogWidgetStatic(
      context: context,
      widget: widget,
    );
  }

  static dialogStatic(
      {required BuildContext context,
      required String title,
      required String msg,
      required List<String> btnTitles,
      required ValueChanged<int> onSelected}) {
    dialogWidgetStatic(
        context: context,
        widget: Padding(
          padding: EdgeInsets.only(
              left: XBThemeMixin.appStatic.spaces.gapLarge,
              right: XBThemeMixin.appStatic.spaces.gapLarge),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              color: Colors.white,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: XBThemeMixin.appStatic.spaces.gapDef,
                  ),
                  Text(
                    title,
                    style: TextStyle(
                        fontSize: XBThemeMixin.appStatic.fontSizes.s18,
                        fontWeight: XBThemeMixin.appStatic.fontWeights.medium),
                  ),
                  Padding(
                    padding: EdgeInsets.only(
                        left: XBThemeMixin.appStatic.spaces.gapDef,
                        right: XBThemeMixin.appStatic.spaces.gapDef,
                        top: XBThemeMixin.appStatic.spaces.gapLess,
                        bottom: XBThemeMixin.appStatic.spaces.gapDef),
                    child: Text(msg),
                  ),
                  Container(
                    height: XBSysSpaceMixin.getOnePixel(context),
                    color: lineColor,
                  ),
                  Row(
                    children: _setupBtns(context, btnTitles, onSelected),
                  )
                ],
              ),
            ),
          ),
        ));
  }

  /// 展示一个Dialog
  dialog(
      {required String title,
      required String msg,
      required List<String> btnTitles,
      required ValueChanged<int> onSelected}) {
    dialogStatic(
        context: context,
        title: title,
        msg: msg,
        btnTitles: btnTitles,
        onSelected: onSelected);
  }

  static List<Widget> _setupBtns(BuildContext context, List<String> btnTitles,
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
          width: XBSysSpaceMixin.getOnePixel(context),
          color: lineColor,
        ),
        _buildBtn(btnTitles[1], Colors.blue, () {
          Navigator.of(context, rootNavigator: false).pop();
          onSelected(1);
        })
      ];
    }
  }

  static Widget _buildBtn(String title, Color color, VoidCallback onTap) {
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
}
