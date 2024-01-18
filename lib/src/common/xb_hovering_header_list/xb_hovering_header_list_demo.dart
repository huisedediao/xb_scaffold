import 'package:flutter/material.dart';
import 'xb_hovering_header_list.dart';

class XBHoveringHeaderListDemo extends StatefulWidget {
  const XBHoveringHeaderListDemo({super.key});

  @override
  State createState() => _XBHoveringHeaderListDemoState();
}

class _XBHoveringHeaderListDemoState extends State<XBHoveringHeaderListDemo> {
  final GlobalKey<XBHoveringHeaderListState> _globalKey = GlobalKey();
  final List<int> _itemCounts = [5, 5];

  @override
  Widget build(ctx) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("hovering_header_list"),
      ),
      body: XBHoveringHeaderList(
        key: _globalKey,

        ///分组信息，每组有几个item
        itemCounts: _itemCounts,

        ///header builder
        sectionHeaderBuild: (ctx, section) {
          if (section % 2 == 0) {
            return Header(
              "我是第一种段头 $section",
            );
          } else {
            return Header2(
              "我是第二种段头 $section",
            );
          }
        },

        ///header高度
        headerHeightForSection: (section) {
          if (section % 2 == 0) {
            return Header.height;
          } else {
            return Header2.height;
          }
        },

        ///item builder
        itemBuilder: (ctx, indexPath, height) {
          if (indexPath.index % 2 == 0) {
            return CellOne("我是第一种cell $indexPath", () {
//              _globalKey.currentState.animateToIndexPath(SectionIndexPath(2, 3),
//                  duration: Duration(seconds: 1), curve: Curves.ease);
            });
          } else {
            return CellTwo("我是第二种cell $indexPath", () {
//              _globalKey.currentState.animateToIndexPath(SectionIndexPath(3, 2),
//                  duration: Duration(seconds: 1), curve: Curves.ease);
            });
          }
        },

        ///item高度
        itemHeightForIndexPath: (indexPath) {
          if (indexPath.index % 2 == 0) {
            return CellOne.height;
          } else {
            return CellTwo.height;
          }
        },

        ///分割线builder
        separatorBuilder: (ctx, indexPath, height, isLast) {
//        print("indexPath : $indexPath,$isLast");
          return Separator();
        },

        ///分割线高度
        separatorHeightForIndexPath: (indexPath, isLast) {
          return Separator.height;
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

//          needSafeArea: true,
      ),
    );
  }
}

class CellOne extends StatelessWidget {
  static const height = 44.0;
  final String title;
  final VoidCallback onPressed;

  const CellOne(this.title, this.onPressed, {super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: height,
        color: Colors.black38,
        alignment: Alignment.center,
        child: Text(title, style: TextStyle(color: Colors.white)),
      ),
    );
  }
}

class CellTwo extends StatelessWidget {
  static const height = 88.0;
  final String title;
  final VoidCallback onPressed;

  const CellTwo(this.title, this.onPressed, {super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: height,
        color: Colors.black54,
        alignment: Alignment.center,
        child: Text(
          title,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}

class Separator extends StatelessWidget {
  static const height = 1.0;

  const Separator({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      color: Colors.white,
    );
  }
}

class Header extends StatelessWidget {
  static const height = 50.0;
  final String title;
  final Color? color;

  const Header(this.title, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: const Alignment(-0.8, 0.0),
      height: height,
      color: color ?? Colors.orange,
      child: Text(
        title,
        style: const TextStyle(fontSize: 20, color: Colors.white),
      ),
    );
  }
}

class Header2 extends StatelessWidget {
  static const height = 80.0;
  final String title;
  final Color? color;

  const Header2(this.title, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: const Alignment(-0.8, 0.0),
      height: height,
      color: color ?? Colors.green,
      child: Text(
        title,
        style: const TextStyle(fontSize: 20, color: Colors.white),
      ),
    );
  }
}
