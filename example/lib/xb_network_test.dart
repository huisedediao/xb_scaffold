import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

import 'xb_network_test_vm.dart';

class XBNetwrokTest extends XBPage<XBNetwrokTestVM> {
  const XBNetwrokTest({super.key});

  @override
  generateVM(BuildContext context) {
    return XBNetwrokTestVM(context: context);
  }

  @override
  Widget buildPage(vm, BuildContext context) {
    return Container();
  }
}
