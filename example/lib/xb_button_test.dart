import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBButtonTest extends XBPage<XBButtonTestVM> {
  const XBButtonTest({super.key});

  @override
  generateVM(BuildContext context) {
    return XBButtonTestVM(context: context);
  }

  @override
  Widget buildPage(vm, BuildContext context) {
    return XBButton(
      effect: XBButtonTapEffect.none,
      onTap: () {
        debugPrint("XBButton 1 clicked");
      },
      child: Container(
        color: Colors.orange,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 80,
              color: Colors.green,
            ),
            XBButton(
              // effect: XBButtonTapEffect.none,
              onTap: () {
                debugPrint("XBButton 2 clicked");
              },
              child: GestureDetector(
                onTap: () {
                  debugPrint("GestureDetector clicked");
                },
                child: CupertinoSwitch(
                    value: true,
                    onChanged: (newValue) {
                      debugPrint("改变状态");
                    }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class XBButtonTestVM extends XBPageVM<XBButtonTest> {
  XBButtonTestVM({required super.context});
}
