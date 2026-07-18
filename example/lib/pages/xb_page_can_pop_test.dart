import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBPageCanPopTest extends XBPage<XBPageCanPopTestVM> {
  const XBPageCanPopTest({super.key});

  @override
  generateVM(BuildContext context) {
    return XBPageCanPopTestVM(context: context);
  }

  @override
  Widget buildPage(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      child: const Text('XBPageCanPopTest'),
    );
  }

  @override
  bool canPop(BuildContext context) {
    return true;
  }

  @override
  void handlePopSuccess(BuildContext context, result) {
    xbError('handlePopSuccess $result');
  }

  @override
  void handlePopFailure(BuildContext context, result) {
    xbError('handlePopFailure $result');
    Navigator.of(context).pop();
  }
}

class XBPageCanPopTestVM extends XBPageVM<XBPageCanPopTest> {
  XBPageCanPopTestVM({required super.context});
}
