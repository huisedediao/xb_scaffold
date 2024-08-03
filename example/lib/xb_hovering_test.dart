import 'package:example/xb_hovering_test_vm.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBHoveringTest extends XBPage<XBHoveringTestVM> {
  const XBHoveringTest({super.key});

  @override
  generateVM(BuildContext context) {
    return XBHoveringTestVM(context: context);
  }

  @override
  String setTitle(XBHoveringTestVM vm) {
    return "测试 悬浮段头列表";
  }

  @override
  bool needLoading(vm) {
    return true;
  }

  @override
  Widget buildPage(vm, BuildContext context) {
    return XBHoveringHeaderList(
      ///分组信息，每组有几个item
      itemCounts: vm.itemCounts,

      ///header builder
      sectionHeaderBuild: (ctx, section) {
        if (section % 2 == 0) {
          return Container(
            color: Colors.red,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Text(
                  "我是第一种段头 $section",
                ),
              ],
            ),
          );
        } else {
          return Container(
            color: Colors.blue,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Text(
                  "我是第二种段头 $section",
                ),
              ],
            ),
          );
        }
      },

      ///header高度
      headerHeightForSection: (section) {
        if (section % 2 == 0) {
          return 40;
        } else {
          return 20;
        }
      },

      ///item builder
      itemBuilder: (ctx, indexPath, height) {
        return Text("我是cell $indexPath");
      },

      ///item高度
      itemHeightForIndexPath: (indexPath) {
        return 50;
      },

      ///分割线builder
      separatorBuilder: (ctx, indexPath, height, isLast) {
        return Container(
          color: Colors.orange,
        );
      },

      ///分割线高度
      separatorHeightForIndexPath: (indexPath, isLast) {
        return onePixel;
      },

      ///滚动到底部和离开底部的回调
      onEndChanged: (end) {
//          print("end : $end");
      },

      ///offset改变回调
      onOffsetChanged: (offset, maxOffset) {
//        print("111111:offset : $offset");
      },

      ///滚动到顶部和离开顶部的回调
      onTopChanged: (top) {
//          print("top:$top");
      },

      ///是否需要悬停header
      hover: true,

      //  needSafeArea: true,
    );
  }
}
