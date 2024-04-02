import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'xb_vm.dart';

abstract class XBWidget<T extends XBVM> extends StatefulWidget {
  const XBWidget({required super.key});

  /// 生成vm
  T generateVM(BuildContext context);

  /// 构建主体
  Widget buildWidget(T vm, BuildContext context);

  void didChangeDependencies(XBWidgetState state, T vm) {}

  void didUpdateWidget(
      covariant XBWidget<T> oldWidget, XBWidgetState state, T vm) {}

  @override
  XBWidgetState createState() => XBWidgetState<T>();
}

class XBWidgetState<T extends XBVM> extends State<XBWidget<T>> {
  /// 在外部使用时，不应该保存vm，避免生命周期问题
  late T vm;

  /// 刷新UI
  rebuild({bool regenerateVM = false}) {
    if (regenerateVM) {
      if (mounted) {
        setState(() {
          vm = widget.generateVM(context);
        });
      }
    } else {
      vm.notify();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.didChangeDependencies(this, vm);
  }

  @override
  void didUpdateWidget(covariant XBWidget<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.didUpdateWidget(oldWidget, this, vm);
  }

  @override
  void initState() {
    super.initState();
    vm = widget.generateVM(context);
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<T>.value(
      value: vm,
      child: Consumer<T>(
        builder: (context, vm, child) {
          return widget.buildWidget(vm, context);
        },
      ),
    );
  }

  @override
  void dispose() {
    debugPrint("$runtimeType dispose");
    vm.dispose();
    super.dispose();
  }
}
