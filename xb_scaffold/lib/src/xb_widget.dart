import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'xb_vm.dart';

abstract class XBWidget<T extends XBVM> extends StatefulWidget {
  const XBWidget({super.key});

  /// 生成vm
  T generateVM(BuildContext context);

  /// 构建主体
  Widget buildWidget(BuildContext context);

  /// 保持页面状态
  bool get wantKeepAlive => false;

  /// 获取vm实例（不监听变化）
  T vmOf(BuildContext context) {
    return Provider.of<T>(context, listen: false);
  }

  /// 获取vm实例（监听变化，会触发rebuild）
  T vmWatchOf(BuildContext context) {
    return Provider.of<T>(context, listen: true);
  }

  @override
  XBWidgetState createState() => XBWidgetState<T>();
}

class XBWidgetState<T extends XBVM> extends State<XBWidget<T>>
    with AutomaticKeepAliveClientMixin {
  /// 在外部使用时，不应该保存vm，避免生命周期问题
  late T vm;

  /// 获取当前vm实例（不监听变化）
  T get vmInstance => vm;

  /// 获取当前vm实例（监听变化）
  T get vmWatch => Provider.of<T>(context, listen: true);

  /// 重置vm，所有状态回到初始状态，然后刷新ui
  /// 重置引起的vm的dispose，不会触发XBPageVm的willDispose
  reset() {
    if (mounted) {
      setState(() {
        final tempVM = vm;
        _generateVM();
        tempVM.disposeFromHost();
        // 新 VM 需重新调度 widgetDidBuilt（postFrame 只在 initState
        // 注册一次的话，reset 后的新 VM 永远收不到该回调）
        _scheduleWidgetDidBuilt();
      });
    }
  }

  /// 刷新UI
  rebuildUI() {
    vm.notify();
  }

  /// widgetDidBuilt 回调是否已调度：同一帧内多次 reset 合并，
  /// 只在帧末回调一次、且回调的是当前 VM（未 build 过的旧 VM 不回调）
  bool _widgetDidBuiltScheduled = false;

  /// 调度当前帧结束后回调 vm 的 [XBVM.widgetDidBuilt]。
  ///
  /// postFrame 回调必须在每次生成新 VM 后重新调度（initState 与 reset），
  /// 否则 reset 换出的新 VM 永远收不到 widgetDidBuilt，
  /// 依赖它做首屏初始化的页面会静默失效。
  void _scheduleWidgetDidBuilt() {
    if (_widgetDidBuiltScheduled) return;
    _widgetDidBuiltScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _widgetDidBuiltScheduled = false;
      if (mounted) {
        vm.widgetDidBuilt();
      }
    });
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
    _scheduleWidgetDidBuilt();
  }

  _generateVM() {
    vm = widget.generateVM(context);
    vm.initState(this);
    vm.didCreated();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ChangeNotifierProvider<T>.value(
      value: vm,
      child: Consumer<T>(
        builder: (context, vm, child) {
          return LayoutBuilder(
            builder: (context, constraints) {
              // build 期仅更新值，widgetSizeDidChanged 回调延迟到帧结束后触发
              vm.updateWidgetSize(
                  Size(constraints.maxWidth, constraints.maxHeight));
              return widget.buildWidget(context);
            },
          );
        },
      ),
    );
  }

  @override
  bool get wantKeepAlive => widget.wantKeepAlive;

  @override
  void dispose() {
    debugPrint("$runtimeType dispose");
    // 先关闭 mounted 防护再销毁：避免 VM 重写的 dispose 及其同步回调
    // 在销毁窗口期通过 mounted 检查，notify 到正在销毁的 element
    vm.disposeFromHost();
    super.dispose();
  }
}
