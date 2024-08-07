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
            preventMultiTapMilliseconds: 5000,
            enable: false,
            // disableColor: Colors.black38,
            onTap: () {
              xbError("XBButton 1 clicked");
            },
            onTapDisable: () {
              xbError("XBButton 1 onTapDisable");
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
            preventMultiTapMilliseconds: 2000,
            enable: true,
            onTap: () {
              xbError("XBButton 2 clicked");
            },
            child: Container(
              height: 50,
              color: Colors.blue,
              alignment: Alignment.center,
              child: Text("enable test"),
            )),
        XBButton(
          onTap: () {
            xbError("red clicked");
          },
          child: Container(
            width: 200,
            height: 200,
            color: Colors.red,
            alignment: Alignment.center,
            child: XBButton(
              onTap: () {
                xbError("green clicked");
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
        ),
        Container(
          color: Colors.amber.withAlpha(20),
          child: XBButton(
              onTap: () {
                xbError("cover test");
              },
              coverTransparentWhileOpacity: true,
              child: Container(
                width: 200,
                height: 300,
                alignment: Alignment.center,
                child: Text("cover test"),
              )),
        )
      ],
    );
  }
}

class XBButtonTestVM extends XBPageVM<XBButtonTest> {
  XBButtonTestVM({required super.context});
}
