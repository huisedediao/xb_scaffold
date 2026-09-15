import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

void main() {
  group('XBSelect 字段级订阅', () {
    testWidgets('只在 selector 值变化时重建，无关字段 notify 不触发 builder', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _TestPage()));

      // 首帧：builder 执行一次
      expect(_TestPageVM.selectBuildCount, 1);
      expect(find.text('unread:0'), findsOneWidget);

      // 修改被订阅字段：builder 重建
      await tester.tap(find.byKey(const Key('bump')));
      await tester.pump();
      expect(find.text('unread:1'), findsOneWidget);
      expect(_TestPageVM.selectBuildCount, 2);

      // 修改无关字段：外层 Consumer 重建波及 XBSelect，
      // 但值未变，返回缓存 child，builder 不再执行
      await tester.tap(find.byKey(const Key('other')));
      await tester.pump();
      expect(_TestPageVM.selectBuildCount, 2,
          reason: '无关字段 notify 不应重建 XBSelect');
      expect(find.text('unread:1'), findsOneWidget);

      // 字段再次变化：builder 恢复重建
      await tester.tap(find.byKey(const Key('bump')));
      await tester.pump();
      expect(find.text('unread:2'), findsOneWidget);
      expect(_TestPageVM.selectBuildCount, 3);
    });
  });

  group('XBSelectMulti 跨 VM 多值订阅', () {
    testWidgets('任一 VM 的被 select 字段变化都重建，无关字段不触发', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _OuterPage()));

      // 首帧
      expect(find.text('0:a'), findsOneWidget);
      expect(_OuterVM.multiBuildCount, 1);

      // 外层 VM 被订阅字段变化：重建
      await tester.tap(find.byKey(const Key('outerBump')));
      await tester.pump();
      expect(find.text('1:a'), findsOneWidget);
      expect(_OuterVM.multiBuildCount, 2);

      // 外层 VM 无关字段变化：不重建
      await tester.tap(find.byKey(const Key('outerOther')));
      await tester.pump();
      expect(_OuterVM.multiBuildCount, 2, reason: '无关字段 notify 不应重建 XBSelectMulti');

      // 内层 VM 被订阅字段变化：重建
      await tester.tap(find.byKey(const Key('innerRename')));
      await tester.pump();
      expect(find.text('1:b'), findsOneWidget);
      expect(_OuterVM.multiBuildCount, 3);
    });
  });

  group('XBVM createNotifier 托管', () {
    testWidgets('VM dispose 后托管的 ValueNotifier 自动销毁', (tester) async {
      createdNotifier = null;
      await tester.pumpWidget(const MaterialApp(home: _NotifierPage()));
      expect(createdNotifier, isNotNull);

      // 卸载页面 → State.dispose → VM.dispose → 托管 notifier 被销毁
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();

      expect(
        () => createdNotifier!.value = 1,
        throwsA(isA<FlutterError>()),
        reason: 'VM dispose 后 notifier 应已销毁，再赋值应抛错',
      );
    });

    testWidgets('托管的 ValueNotifier 更新可正常驱动 ValueListenableBuilder',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _NotifierPage()));

      expect(find.text('v:0'), findsOneWidget);
      createdNotifier!.value = 5;
      await tester.pump();
      expect(find.text('v:5'), findsOneWidget);
    });
  });
}

ValueNotifier<int>? createdNotifier;

class _TestPage extends XBWidget<_TestPageVM> {
  const _TestPage();

  @override
  _TestPageVM generateVM(BuildContext context) => _TestPageVM(context: context);

  @override
  Widget buildWidget(BuildContext context) {
    final vm = vmOf(context);
    return Column(
      children: [
        XBSelect<_TestPageVM, int>(
          selector: (vm) => vm.unread,
          builder: (context, unread) {
            _TestPageVM.selectBuildCount++;
            return Text('unread:$unread');
          },
        ),
        ElevatedButton(
          key: const Key('bump'),
          onPressed: vm.bumpUnread,
          child: const Text('bump'),
        ),
        ElevatedButton(
          key: const Key('other'),
          onPressed: vm.touchOther,
          child: const Text('other'),
        ),
      ],
    );
  }
}

class _TestPageVM extends XBVM<_TestPage> {
  _TestPageVM({required super.context});

  /// 静态计数：XBSelect builder 实际执行次数（演示/断言用）
  static int selectBuildCount = 0;

  int unread = 0;
  int other = 0;

  void bumpUnread() {
    unread++;
    notify();
  }

  void touchOther() {
    other++;
    notify();
  }
}

class _OuterPage extends XBWidget<_OuterVM> {
  const _OuterPage();

  @override
  _OuterVM generateVM(BuildContext context) => _OuterVM(context: context);

  @override
  Widget buildWidget(BuildContext context) {
    final vm = vmOf(context);
    return Column(
      children: [
        ElevatedButton(
          key: const Key('outerBump'),
          onPressed: vm.bumpUnread,
          child: const Text('outerBump'),
        ),
        ElevatedButton(
          key: const Key('outerOther'),
          onPressed: vm.touchOther,
          child: const Text('outerOther'),
        ),
        const _InnerWidget(),
      ],
    );
  }
}

class _OuterVM extends XBVM<_OuterPage> {
  _OuterVM({required super.context});

  /// XBSelectMulti builder 实际执行次数（断言用）
  static int multiBuildCount = 0;

  int unread = 0;
  int other = 0;

  void bumpUnread() {
    unread++;
    notify();
  }

  void touchOther() {
    other++;
    notify();
  }
}

/// 内层 XBWidget：自身的 VM 在里层，同时订阅外层页面的 VM
class _InnerWidget extends XBWidget<_InnerVM> {
  const _InnerWidget();

  @override
  _InnerVM generateVM(BuildContext context) => _InnerVM(context: context);

  @override
  Widget buildWidget(BuildContext context) {
    final vm = vmOf(context);
    return Column(
      children: [
        XBSelectMulti<({int unread, String name})>(
          selector: (context) => (
            unread: context.select<_OuterVM, int>((vm) => vm.unread),
            name: context.select<_InnerVM, String>((vm) => vm.name),
          ),
          builder: (context, v) {
            _OuterVM.multiBuildCount++;
            return Text('${v.unread}:${v.name}');
          },
        ),
        ElevatedButton(
          key: const Key('innerRename'),
          onPressed: vm.rename,
          child: const Text('innerRename'),
        ),
      ],
    );
  }
}

class _InnerVM extends XBVM<_InnerWidget> {
  _InnerVM({required super.context});

  String name = 'a';

  void rename() {
    name = name == 'a' ? 'b' : 'a';
    notify();
  }
}

class _NotifierPage extends XBWidget<_NotifierVM> {
  const _NotifierPage();

  @override
  _NotifierVM generateVM(BuildContext context) => _NotifierVM(context: context);

  @override
  Widget buildWidget(BuildContext context) {
    final vm = vmOf(context);
    createdNotifier = vm.counter;
    return ValueListenableBuilder<int>(
      valueListenable: vm.counter,
      builder: (context, value, _) => Text('v:$value'),
    );
  }
}

class _NotifierVM extends XBVM<_NotifierPage> {
  _NotifierVM({required super.context});

  late final ValueNotifier<int> counter = createNotifier<int>(0);
}
