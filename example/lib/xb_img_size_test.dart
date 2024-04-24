import 'package:example/xb_img_size_test_vm.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBImgSizeTest extends XBPage<XBImgSizeTestVM> {
  const XBImgSizeTest({super.key});

  @override
  generateVM(BuildContext context) {
    return XBImgSizeTestVM(context: context);
  }

  @override
  Widget buildPage(vm, BuildContext context) {
    return Container(
      child: Column(
        children: [
          XBButton(onTap: vm.onGetSizeFromNet, child: Text("获取网络图片size")),
          XBButton(onTap: vm.onGetSizeFromAsset, child: Text("获取asset图片size")),
          // XBButton(onTap: vm.onGetSizeFromFile, child: Text("获取File图片size")),
          // XBButton(onTap: vm.onGetSizeFromMemory, child: Text("获取Memory图片size")),
        ],
      ),
    );
  }
}
