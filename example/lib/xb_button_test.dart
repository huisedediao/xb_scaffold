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
    return Column(
      children: [
        XBButton(
            enable: false,
            // disableColor: Colors.black38,
            onTap: () {
              debugPrint("XBButton 1 clicked");
            },
            child: Container(
              height: 50,
              color: Colors.blue,
              alignment: Alignment.center,
              child: const Text(
                "enable test",
                style: TextStyle(color: Colors.white),
              ),
            )),
        XBButton(
            enable: true,
            onTap: () {
              debugPrint("XBButton 2 clicked");
            },
            child: Container(
              height: 50,
              color: Colors.blue,
              alignment: Alignment.center,
              child: Text("enable test"),
            )),
      ],
    );
  }
}

class XBButtonTestVM extends XBPageVM<XBButtonTest> {
  XBButtonTestVM({required super.context});
}
