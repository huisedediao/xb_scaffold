import 'package:example/pages/xb_button_demo_vm.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBButtonDemo extends XBPage<XBButtonDemoVM> {
  const XBButtonDemo({super.key});

  @override
  generateVM(BuildContext context) {
    return XBButtonDemoVM(context: context);
  }

  @override
  Color? backgroundColor(XBButtonDemoVM vm) {
    return Colors.white;
  }

  @override
  Widget buildPage(XBButtonDemoVM vm, BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        XBButtonText(text: "点击", onTap: () {}),
        XBButtonText(
            text: "点击",
            borderColor: Colors.red,
            borderRadius: 10,
            backgroundColor: colors.primary,
            style: TextStyle(color: Colors.white, fontSize: fontSizes.s12),
            // width: double.infinity,
            padding: EdgeInsets.only(
                left: spaces.gapLarge,
                right: spaces.gapLarge,
                top: 10,
                bottom: 10),
            onTap: () {
              if (XBThemeVM().themeIndex == 0) {
                XBThemeVM().changeTheme(1);
              } else {
                XBThemeVM().changeTheme(0);
              }
            }),
      ],
    );
  }
}
