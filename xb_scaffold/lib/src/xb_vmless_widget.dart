import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/xb_vm.dart';
import 'package:xb_scaffold/src/xb_widget.dart';

abstract class XBVMLessWidget extends XBWidget<XBVM> {
  const XBVMLessWidget({super.key});

  @override
  XBVM generateVM(BuildContext context) {
    return XBVM(context: context);
  }
}
