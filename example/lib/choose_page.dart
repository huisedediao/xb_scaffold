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
      itemCount: vm.titles.length,
      separatorBuilder: (context, index) {
        return Container(
          height: 10,
        );
      },
      itemBuilder: (context, index) {
        String title = vm.titles[index];
        return XBCellTitleSubtitle(
          backgroundColor: colors.randColor,
          padding: EdgeInsets.all(spaces.gapDef),
          title: title,
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

  List<String> titles = [
    "XBCell demo",
    "XBCellGroup demo",
    "XBPage demo",
    "XBDialogInput demo",
    "XBButton demo",
    "XBToast demo",
    "XBWaitTask demo",
    "VM访问演示",
    "TFTest",
    "Hide top bar test",
    "Error catch test",
    "XBRoute 功能测试",
    "XBImageTestPage",
    "xb_simple_router 测试页",
    "xb_network 测试页",
  ];

  void onTapIndex(int index) {
    if (index == 0) {
      // push(const XBCellDemo());
      Get.to(() => const XBCellDemo());
    } else if (index == 1) {
      push(const XBCellGroupDemo());
    } else if (index == 2) {
      push(const XBPageDemo());
    } else if (index == 3) {
      push(const XBDialogInputDemo());
    } else if (index == 4) {
      push(const XBButtonDemo());
    } else if (index == 5) {
      push(const XBToastDemo());
    } else if (index == 6) {
      push(const XBWaitTaskDemo());
    } else if (index == 7) {
      push(const VMAccessDemo());
    } else if (index == 8) {
      push(const TFTest());
    } else if (index == 9) {
      push(const HideTopBarTest());
    } else if (index == 10) {
      push(const ErrorTestPage());
    } else if (index == 11) {
      push(const XBRouteTestPage());
    } else if (index == 12) {
      push(const XBImageTestPage());
    } else if (index == 13) {
      push(const XBSimpleRouterTestPage());
    } else if (index == 14) {
      push(const XBNetworkTestPage());
    }
  }
}
