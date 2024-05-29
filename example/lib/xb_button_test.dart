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
            onTapDisable: () {
              debugPrint("XBButton 1 onTapDisable");
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
        XBButton(
          onTap: () {
            debugPrint("red clicked");
          },
          child: Container(
            width: 200,
            height: 200,
            color: Colors.red,
            alignment: Alignment.center,
            child: XBButton(
              onTap: () {
                debugPrint("green clicked");
                XBEventBus.fire("test event bus");
                XBEventBus.fire(111);
                XBEventBus.fire(222.0);
              },
              child: Container(
                width: 100,
                height: 100,
                color: Colors.green,
              ),
            ),
          ),
        )
      ],
    );
  }
}

class XBButtonTestVM extends XBPageVM<XBButtonTest> {
  XBButtonTestVM({required super.context});
}
