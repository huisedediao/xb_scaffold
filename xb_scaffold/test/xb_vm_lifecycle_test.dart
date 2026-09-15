import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

/// VM 生命周期回归测试：
/// 1. reset() 后新 VM 应重新收到 widgetDidBuilt
///    （原 bug：postFrame 回调只在 initState 注册一次，reset 换新 VM 后永不触发）
/// 2. dispose 链路上的 notify 不应崩溃
///    （原 bug：销毁窗口期 mounted 假阳性——_disposed 在 dispose 末尾才置位、
///     state.mounted 在 super.dispose() 前仍为 true，notify 通过检查打到正在销毁的 element）

class _LifecycleWidget extends XBWidget<_LifecycleVM> {
  const _LifecycleWidget({super.key, required this.log});

  final List<String> log;

  @override
  _LifecycleVM generateVM(BuildContext context) =>
      _LifecycleVM(context: context, log: log);

  @override
  Widget buildWidget(BuildContext context) => const SizedBox();
}

class _LifecycleVM extends XBVM<_LifecycleWidget> {
  _LifecycleVM({required super.context, required this.log});

  final List<String> log;

  @override
  void widgetDidBuilt() {
    super.widgetDidBuilt();
    log.add('widgetDidBuilt');
  }
}

/// 模拟业务在 dispose 中触发刷新（销毁窗口期的 notify 应被 mounted 防护拦截）
class _DisposeNotifyWidget extends XBWidget<_DisposeNotifyVM> {
  const _DisposeNotifyWidget({super.key});

  @override
  _DisposeNotifyVM generateVM(BuildContext context) =>
      _DisposeNotifyVM(context: context);

  @override
  Widget buildWidget(BuildContext context) => const SizedBox();
}

/// 最近创建的 _DisposeNotifyVM（销毁后 VM 实例已被 State 释放，需提前登记引用）
_DisposeNotifyVM? _lastDisposeNotifyVM;

class _DisposeNotifyVM extends XBVM<_DisposeNotifyWidget> {
  _DisposeNotifyVM({required super.context}) {
    _lastDisposeNotifyVM = this;
  }

  /// dispose 链路中观测到的 mounted 值（销毁窗口期应为 false）
  bool? mountedDuringDispose;

  @override
  void dispose() {
    mountedDuringDispose = mounted;
    notify();
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reset 后新 VM 重新收到 widgetDidBuilt', (tester) async {
    final log = <String>[];
    final key = GlobalKey<XBWidgetState<_LifecycleVM>>();

    await tester.pumpWidget(MaterialApp(home: _LifecycleWidget(key: key, log: log)));
    await tester.pump();
    expect(log, ['widgetDidBuilt'], reason: '首个 VM 构建后应回调一次');

    key.currentState!.reset();
    await tester.pump();
    expect(log.length, 2,
        reason: 'reset 生成的新 VM 构建后也应收到 widgetDidBuilt，'
            '否则新 VM 的首屏初始化逻辑永远不会执行');
  });

  testWidgets('reset 后旧 VM 不再收到 widgetDidBuilt', (tester) async {
    final log = <String>[];
    final key = GlobalKey<XBWidgetState<_LifecycleVM>>();

    await tester.pumpWidget(MaterialApp(home: _LifecycleWidget(key: key, log: log)));
    await tester.pump();
    final oldVM = key.currentState!.vmInstance;

    key.currentState!.reset();
    await tester.pump();

    expect(oldVM.disposed, isTrue, reason: '旧 VM 应已销毁');
    expect(identical(key.currentState!.vmInstance, oldVM), isFalse,
        reason: 'reset 应生成新 VM');
  });

  testWidgets('VM dispose 链路上的 notify 不崩溃且 mounted 已失效', (tester) async {
    final key = GlobalKey<XBWidgetState<_DisposeNotifyVM>>();
    await tester.pumpWidget(MaterialApp(home: _DisposeNotifyWidget(key: key)));
    await tester.pump();

    // 替换根节点触发销毁：dispose 重写里的 notify 不应打到正在销毁的 element
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    // 销毁链路开始时 mounted 就应失效：
    // 旧逻辑 _disposed 在 dispose 末尾才置位、state.mounted 在
    // super.dispose() 前仍为 true，mounted 假阳性使防护形同虚设
    expect(key.currentState, isNull, reason: 'State 已销毁');
    expect(_lastDisposeNotifyVM!.mountedDuringDispose, isFalse,
        reason: 'dispose 链路上 mounted 应已失效，notify 应为无操作');
  });
}
