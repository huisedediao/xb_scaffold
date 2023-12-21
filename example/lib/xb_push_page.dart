import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBPushPage extends XBPage<XBPushPageVM> {
  const XBPushPage({super.key});

  @override
  generateVM(BuildContext context) {
    return XBPushPageVM(context: context);
  }

  @override
  String setTitle(XBPushPageVM vm) {
    return "测试路由的page";
  }

  @override
  Widget buildPage(vm, BuildContext context) {
    return Container(
      color: app.colors.randColor,
    );
  }
}

class XBPushPageVM extends XBVM<XBPushPage> {
  XBPushPageVM({required super.context});
}
