import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/configs/color_config.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

extension XBVMDialog on XBVM {
  /// dialog的形式展示一个widget
  dialogWidget(Widget widget) {
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

  /// 展示一个Dialog
  dialog(
      {required String title,
      required String msg,
      required List<String> btnTitles,
      required ValueChanged<int> onSelected}) {
    dialogWidget(Padding(
      padding: EdgeInsets.only(
          left: app.spaces.gapLarge, right: app.spaces.gapLarge),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          color: Colors.white,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: app.spaces.gapDef,
              ),
              Text(
                title,
                style: TextStyle(
                    fontSize: app.fontSizes.s18,
                    fontWeight: app.fontWeights.medium),
              ),
              Padding(
                padding: EdgeInsets.only(
                    left: app.spaces.gapDef,
                    right: app.spaces.gapDef,
                    top: app.spaces.gapLess,
                    bottom: app.spaces.gapDef),
                child: Text(msg),
              ),
              Container(
                height: onePixel,
                color: lineColor,
              ),
              Row(
                children: _setupBtns(btnTitles, onSelected),
              )
            ],
          ),
        ),
      ),
    ));
  }

  List<Widget> _setupBtns(
      List<String> btnTitles, ValueChanged<int> onSelected) {
    if (btnTitles.length == 1) {
      return [
        _buildBtn(btnTitles[0], Colors.blue, () {
          pop();
          onSelected(0);
        })
      ];
    } else {
      return [
        _buildBtn(btnTitles[0], Colors.black, () {
          pop();
          onSelected(0);
        }),
        Container(
          height: 50,
          width: onePixel,
          color: lineColor,
        ),
        _buildBtn(btnTitles[1], Colors.blue, () {
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
}
