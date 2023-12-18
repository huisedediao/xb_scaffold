import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xb_scaffold/src/xb_stateless_widget.dart';
import 'xb_vm.dart';

abstract class XBWidget<T extends XBVM> extends XBStatelessWidget {
  const XBWidget({super.key});

  T generateVM(BuildContext context);

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (ctx) => generateVM(context),
      builder: (context, child) {
        return Consumer<T>(
          builder: (context, vm, child) {
            return buildWidget(vm, vm.context);
          },
        );
      },
    );
  }

  Widget buildWidget(T vm, BuildContext context);
}
