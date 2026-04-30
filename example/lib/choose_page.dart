import 'package:example/pages/error_test_page.dart';
import 'package:example/pages/hide_top_bar_test.dart';
import 'package:example/pages/xb_network_test_page.dart';
import 'package:example/pages/xb_button_demo.dart';
import 'package:example/pages/xb_dialog_input_demo.dart';
import 'package:example/pages/xb_image_test_page.dart';
import 'package:example/pages/xb_page_demo.dart';
import 'package:example/pages/xb_route_test_page.dart';
import 'package:example/pages/xb_simple_router_test_page.dart';
import 'package:example/pages/xb_cell_demo.dart';
import 'package:example/pages/xb_cell_group_demo.dart';
import 'package:example/pages/xb_toast_demo.dart';
import 'package:example/pages/xb_wait_task_demo.dart';
import 'package:example/pages/vm_access_demo.dart';
import 'package:example/pages/tf_test.dart';
import 'package:get/get.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:xb_simple_router/xb_simple_router.dart';
import 'package:flutter/material.dart';

class ChoosePage extends XBPage<ChoosePageVM> {
  const ChoosePage({super.key});

  @override
  generateVM(BuildContext context) {
    return ChoosePageVM(context: context);
  }

  @override
  Widget? leading(BuildContext context) {
    return null;
  }

  @override
  Widget buildPage(BuildContext context) {
    final vm = vmOf(context);
    return ListView.separated(
      itemCount: vm.itemCount,
      separatorBuilder: (context, index) {
        return Container(
          height: 10,
        );
      },
      itemBuilder: (context, index) {
        return XBCellTitleSubtitle(
          backgroundColor: colors.randColor,
          padding: EdgeInsets.all(spaces.gapDef),
          title: vm.titleAt(index),
          onTap: () {
            vm.onTapIndex(index);
          },
          subtitle: '',
          isShowArrow: true,
        );
      },
    );
  }
}

class ChoosePageVM extends XBPageVM<ChoosePage> with RouteAware {
  ChoosePageVM({required super.context});

  final List<_ChooseMenuItem> _menuItems = [
    const _ChooseMenuItem(
      title: 'XBCell demo',
      mode: _ChooseNavMode.get,
      pageBuilder: _buildXBCellDemo,
    ),
    const _ChooseMenuItem(
      title: 'XBCellGroup demo',
      pageBuilder: _buildXBCellGroupDemo,
    ),
    const _ChooseMenuItem(
      title: 'XBPage demo',
      pageBuilder: _buildXBPageDemo,
    ),
    const _ChooseMenuItem(
      title: 'XBDialogInput demo',
      pageBuilder: _buildXBDialogInputDemo,
    ),
    const _ChooseMenuItem(
      title: 'XBButton demo',
      pageBuilder: _buildXBButtonDemo,
    ),
    const _ChooseMenuItem(
      title: 'XBToast demo',
      pageBuilder: _buildXBToastDemo,
    ),
    const _ChooseMenuItem(
      title: 'XBWaitTask demo',
      pageBuilder: _buildXBWaitTaskDemo,
    ),
    const _ChooseMenuItem(
      title: 'VM访问演示',
      pageBuilder: _buildVMAccessDemo,
    ),
    const _ChooseMenuItem(
      title: 'TFTest',
      pageBuilder: _buildTFTest,
    ),
    const _ChooseMenuItem(
      title: 'Hide top bar test',
      pageBuilder: _buildHideTopBarTest,
    ),
    const _ChooseMenuItem(
      title: 'Error catch test',
      pageBuilder: _buildErrorTestPage,
    ),
    const _ChooseMenuItem(
      title: 'XBRoute 功能测试',
      pageBuilder: _buildXBRouteTestPage,
    ),
    const _ChooseMenuItem(
      title: 'XBImageTestPage',
      pageBuilder: _buildXBImageTestPage,
    ),
    const _ChooseMenuItem(
      title: 'xb_simple_router 测试页',
      pageBuilder: _buildXBSimpleRouterTestPage,
    ),
    const _ChooseMenuItem(
      title: 'xb_network 测试页',
      pageBuilder: _buildXBNetworkTestPage,
    ),
  ];

  int get itemCount => _menuItems.length;

  String titleAt(int index) => _menuItems[index].title;

  void onTapIndex(int index) {
    if (index < 0 || index >= _menuItems.length) return;
    final item = _menuItems[index];
    if (item.mode == _ChooseNavMode.get) {
      Get.to(item.pageBuilder);
    } else {
      push(item.pageBuilder());
    }
  }

  static Widget _buildXBCellDemo() => const XBCellDemo();
  static Widget _buildXBCellGroupDemo() => const XBCellGroupDemo();
  static Widget _buildXBPageDemo() => const XBPageDemo();
  static Widget _buildXBDialogInputDemo() => const XBDialogInputDemo();
  static Widget _buildXBButtonDemo() => const XBButtonDemo();
  static Widget _buildXBToastDemo() => const XBToastDemo();
  static Widget _buildXBWaitTaskDemo() => const XBWaitTaskDemo();
  static Widget _buildVMAccessDemo() => const VMAccessDemo();
  static Widget _buildTFTest() => const TFTest();
  static Widget _buildHideTopBarTest() => const HideTopBarTest();
  static Widget _buildErrorTestPage() => const ErrorTestPage();
  static Widget _buildXBRouteTestPage() => const XBRouteTestPage();
  static Widget _buildXBImageTestPage() => const XBImageTestPage();
  static Widget _buildXBSimpleRouterTestPage() =>
      const XBSimpleRouterTestPage();
  static Widget _buildXBNetworkTestPage() => const XBNetworkTestPage();
}

enum _ChooseNavMode {
  push,
  get,
}

class _ChooseMenuItem {
  final String title;
  final _ChooseNavMode mode;
  final Widget Function() pageBuilder;

  const _ChooseMenuItem({
    required this.title,
    required this.pageBuilder,
    this.mode = _ChooseNavMode.push,
  });
}
