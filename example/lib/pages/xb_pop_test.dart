import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBPopTest extends StatefulWidget {
  const XBPopTest({Key? key}) : super(key: key);

  @override
  _XBPopTestState createState() => _XBPopTestState();
}

class _XBPopTestState extends State<XBPopTest> {
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Container(
        color: Colors.white,
        alignment: Alignment.center,
        child: XBButton(
            coverTransparentWhileOpacity: true,
            onTap: () {
              /// 调用 maybePop
              Navigator.of(context).maybePop({"key": "value"});
            },
            child: Text("maybe pop")),
      ),
      onPopInvokedWithResult: (didPop, result) {
        print('didPop: $didPop, result: $result');
      },
    );
  }
}
