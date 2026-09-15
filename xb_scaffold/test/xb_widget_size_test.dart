import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class _SizeWidget extends XBWidget<_SizeVM> {
  const _SizeWidget();

  @override
  _SizeVM generateVM(BuildContext context) => _SizeVM(context: context);

  @override
  Widget buildWidget(BuildContext context) => const SizedBox.expand();
}

class _SizeVM extends XBVM<_SizeWidget> {
  _SizeVM({required super.context}) {
    last = this;
  }

  /// 测试读取入口（generateVM 每次重建 VM）
  static _SizeVM? last;

  final List<Size> changedSizes = [];

  @override
  void widgetSizeDidChanged() {
    super.widgetSizeDidChanged();
    changedSizes.add(widgetSize);
    // 关键回归点：回调内直接 notify()，
    // 同步回调会在 build 期触发 markNeedsBuild 断言
    notify();
  }
}

Widget _host(Size size) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: const _SizeWidget(),
          ),
        ),
      ),
    );

void main() {
  testWidgets('widgetSizeDidChanged 延迟到帧末触发，回调内 notify 不报 build 期断言',
      (tester) async {
    await tester.pumpWidget(_host(const Size(100, 50)));
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: '回调内的 notify() 不应触发 build 期断言');
    expect(_SizeVM.last!.changedSizes, const [Size(100, 50)],
        reason: '首次布局后应收到一次尺寸回调');
  });

  testWidgets('尺寸变化后再次回调，拿到新尺寸', (tester) async {
    await tester.pumpWidget(_host(const Size(100, 50)));
    await tester.pump();

    await tester.pumpWidget(_host(const Size(200, 80)));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(_SizeVM.last!.changedSizes.last, const Size(200, 80));
  });

  testWidgets('尺寸不变时不重复回调', (tester) async {
    await tester.pumpWidget(_host(const Size(100, 50)));
    await tester.pump();
    expect(_SizeVM.last!.changedSizes.length, 1);

    // 再次构建相同尺寸，不应触发回调
    await tester.pumpWidget(_host(const Size(100, 50)));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(_SizeVM.last!.changedSizes.length, 1,
        reason: '尺寸未变化不应触发 widgetSizeDidChanged');
  });
}
