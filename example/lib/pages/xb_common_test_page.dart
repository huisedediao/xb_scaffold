import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBCommonTestPage extends XBPage<XBCommonTestPageVM> {
  const XBCommonTestPage({super.key});

  @override
  XBCommonTestPageVM generateVM(BuildContext context) {
    return XBCommonTestPageVM(context: context);
  }

  @override
  Widget buildPage(BuildContext context) {
    return Container();
  }
}

class XBCommonTestPageVM extends XBPageVM<XBCommonTestPage> {
  XBCommonTestPageVM({required super.context});
}
