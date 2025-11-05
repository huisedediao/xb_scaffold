import 'package:example/pages/xb_button_demo.dart';
import 'package:example/pages/xb_dialog_input_demo.dart';
import 'package:example/pages/xb_page_demo.dart';
import 'package:example/pages/xb_cell_demo.dart';
import 'package:example/pages/xb_cell_group_demo.dart';
import 'package:example/pages/xb_toast_demo.dart';
import 'package:example/pages/xb_wait_task_demo.dart';
import 'package:example/pages/vm_access_demo.dart';
import 'package:example/pages/tf_test.dart';
import 'package:get/get.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class ChoosePage extends XBPage<ChoosePageVM> {
  const ChoosePage({super.key});

  @override
  generateVM(BuildContext context) {
    return ChoosePageVM(context: context);
  }

  @override
  Widget? leading(ChoosePageVM vm) {
    return null;
  }

  @override
  Widget buildPage(ChoosePageVM vm, BuildContext context) {
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
    "TFTest"
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
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    xbRrouteObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    xbRrouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPush() {
    // 页面已入栈（可访问 this 和 context）
    xbError("didPush");
  }

  @override
  void didPopNext() {
    // 上一个页面出栈，当前页面重新可见
    xbError("didPopNext");
  }

  /// Called when the current route has been popped off.
  @override
  void didPop() {
    xbError("didPop");
  }

  /// Called when a new route has been pushed, and the current route is no
  /// longer visible.
  @override
  void didPushNext() {
    xbError("didPushNext");
  }
}
