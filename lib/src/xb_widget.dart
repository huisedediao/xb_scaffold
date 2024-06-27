import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'xb_vm.dart';

abstract class XBWidget<T extends XBVM> extends StatefulWidget {
  const XBWidget({required super.key});

  /// 生成vm
  T generateVM(BuildContext context);

  /// 构建主体
  Widget buildWidget(T vm, BuildContext context);

  /// 保持页面状态
  bool get wantKeepAlive => false;

  @override
  XBWidgetState createState() => XBWidgetState<T>();
}

class XBWidgetState<T extends XBVM> extends State<XBWidget<T>>
    with AutomaticKeepAliveClientMixin {
  /// 在外部使用时，不应该保存vm，避免生命周期问题
  late T vm;

  /// 重置vm，所有状态回到初始状态，然后刷新ui
  /// 重置引起的vm的dispose，不会触发XBPageVm的willDispose
  reset() {
    if (mounted) {
      setState(() {
        final tempVM = vm;
        _generateVM();
        tempVM.dispose();
      });
    }
  }

  /// 刷新UI
  rebuildUI() {
    vm.notify();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    vm.didChangeDependencies();
  }

  @override
  void didUpdateWidget(covariant XBWidget<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    vm.didUpdateWidget(oldWidget);
  }

  @override
  void initState() {
    super.initState();
    _generateVM();

    // 在页面构建完成的第一时间执行操作
    WidgetsBinding.instance.addPostFrameCallback((_) {
      vm.widgetDidBuilt();
    });
  }

  _generateVM() {
    vm = widget.generateVM(context);
    vm.state = this;
    vm.didCreated();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
  bool get wantKeepAlive => widget.wantKeepAlive;

  @override
  void dispose() {
    debugPrint("$runtimeType dispose");
    vm.dispose();
    super.dispose();
  }
}
