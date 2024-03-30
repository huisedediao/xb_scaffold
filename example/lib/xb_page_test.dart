import 'package:example/theme/app_extension.dart';
import 'package:example/xb_button_test.dart';
import 'package:example/xb_global_key_test.dart';
import 'package:example/xb_hovering_test.dart';
import 'package:example/xb_page_test_vm.dart';
import 'package:example/xb_push_page.dart';
import 'package:example/xb_rotate_test.dart';
import 'package:example/xb_widget_test.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBPageTest extends XBPage<XBPageTestVM> {
  const XBPageTest({super.key});

  @override
  XBPageTestVM generateVM(BuildContext context) {
    return XBPageTestVM(context: context);
  }

  @override
  String setTitle(XBPageTestVM vm) {
    return 'XBPage测试';
  }

  @override
  bool needInitLoading() {
    return false;
  }

  @override
  bool needLoading() {
    return true;
  }

  @override
  bool needResponseNavigationBarLeftWhileLoading() {
    return true;
  }

  @override
  bool needResponseNavigationBarCenterWhileLoading() {
    return false;
  }

  @override
  bool needResponseNavigationBarRightWhileLoading() {
    return false;
  }

  @override
  Widget buildPage(XBPageTestVM vm, BuildContext context) {
    return GestureDetector(
      onTap: () {
        actionSheet(titles: ["测试toast其他区域点击"], onSelected: (asIndex) {});
      },
      child: Container(
        color: app.colors.orange,
        height: screenH,
        width: screenW,
        child: SingleChildScrollView(
          child: Column(
            children: [
              Wrap(
                children: [
                  _buildWidget(vm, 'show dialog', () {
                    dialog(
                        title: "温馨提示",
                        msg:
                            "msgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsg",
                        btnTitles: ["取消", "确定"],
                        onSelected: (index) {
                          if (index == 0) {
                            // replace(const XBPushPage());
                            pushAndClearStack(const XBPushPage());
                          } else if (index == 1) {
                            push(const XBPushPage());
                          }
                        });
                  }),
                  _buildWidget(vm, 'show action sheet', () {
                    actionSheet(
                        titles: [
                          "1",
                          "2",
                          "1",
                          "2",
                          "1",
                          "2",
                          "1",
                          "2",
                          "1",
                          "2",
                          "1",
                          "2"
                        ],
                        dismissTitle: "取消",
                        onTapDismiss: () {
                          print("点击了取消");
                        },
                        selectedIndex: 0,
                        selectedColor: Colors.red,
                        // dismissTitleColor: Colors.amber,
                        // dismissTitleFontSize: 30,
                        onSelected: (index) {
                          print(index);
                        });
                    // vm.actionSheetWidget(
                    //     widget: ClipRRect(
                    //   borderRadius: BorderRadius.circular(10),
                    //   child: Container(
                    //     height: 200,
                    //     color: app.colors.randColor,
                    //   ),
                    // ));
                  }),
                  _buildWidget(vm, 'show toast', () {
                    toast("isTop:${topIsWidget(this)}",
                        backgroundColor: Colors.red.withAlpha(100),
                        msgStyle:
                            TextStyle(fontSize: 30, color: Colors.yellow));

                    Future.delayed(const Duration(seconds: 2), () {
                      toast("isInStack:${stackContainWidget(this)}");
                    });

                    // vm.toast(
                    //     "msgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsg",
                    //     duration: 5);
                    // vm.toastWidget(Container(
                    //   height: 100,
                    //   width: 100,
                    //   color: app.colors.randColor,
                    // ));
                  }),
                  _buildWidget(vm, 'show loading', () {
                    vm.showLoading();
                    Future.delayed(const Duration(seconds: 3), () {
                      vm.hideLoading();
                    });
                  }),
                  _buildWidget(vm, 'show global loading', () {
                    showLoadingGlobal();
                    // Future.delayed(const Duration(seconds: 3), () {
                    //   showLoadingGlobal();
                    //   Future.delayed(const Duration(seconds: 3), () {
                    //     hideLoadingGlobal();
                    //   });
                    // });
                  }),
                  _buildWidget(vm, '进入 悬浮段头列表页面', () {
                    push(XBHoveringTest());
                  }),
                  _buildWidget(vm, '进入 XBButton测试页面', () {
                    push(XBButtonTest());
                  }),
                  _buildWidget(vm, '进入 旋转测试页面', () {
                    push(XBRotateTest());
                  }),
                  _buildWidget(vm, '进入 globalKey测试页面', () {
                    push(XBGlobalKeyTest());
                  })
                ],
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWidget(XBPageTestVM vm, String title, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Container(
        height: 50,
        width: screenW * 0.33,
        color: Colors.blue,
        child: XBButton(onTap: onTap, child: Center(child: Text(title))),
      ),
    );
  }
}
