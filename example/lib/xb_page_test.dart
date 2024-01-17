import 'package:example/theme/app_extension.dart';
import 'package:example/xb_page_test_vm.dart';
import 'package:example/xb_push_page.dart';
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
    return true;
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
    return Container(
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
                      title: "title",
                      msg:
                          "msgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsgmsg",
                      btnTitles: ["取消", "确定"],
                      onSelected: (index) {
                        if (index == 0) {
                          replace(const XBPushPage());
                        } else if (index == 1) {
                          push(const XBPushPage());
                        }
                      });
                }),
                _buildWidget(vm, 'show action sheet', () {
                  actionSheet(
                      titles: ["1", "2"],
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
                  toast("isTop:${isTop(this)}");
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
                  Future.delayed(const Duration(seconds: 3), () {
                    showLoadingGlobal(needBack: false);
                    Future.delayed(const Duration(seconds: 3), () {
                      hideLoadingGlobal();
                    });
                  });
                })
              ],
            ),
            TextField()
          ],
        ),
      ),
    );
  }

  Widget _buildWidget(XBPageTestVM vm, String title, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Container(
        height: screenH * 0.33,
        width: screenW * 0.33,
        color: Colors.blue,
        child: XBButton(onTap: onTap, child: Center(child: Text(title))),
      ),
    );
  }
}
