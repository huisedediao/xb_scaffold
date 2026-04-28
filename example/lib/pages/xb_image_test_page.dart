import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBImageTestPage extends XBPage<XBImageTestPageVM> {
  const XBImageTestPage({super.key});

  @override
  generateVM(BuildContext context) {
    return XBImageTestPageVM(context: context);
  }

  @override
  Widget buildPage(BuildContext context) {
    final vm = vmOf(context);
    return const Center(
      child: Column(
        children: [
          XBImage(
            "assets/images/home_icon_dont_pre.svg",
            svgColor: Colors.amber,
            width: 50,
          ),
          XBImage(
            "assets/images/add_icon_dvr.svg",
            height: 80,
          ),
        ],
      ),
    );
  }
}

class XBImageTestPageVM extends XBPageVM<XBImageTestPage> {
  XBImageTestPageVM({required super.context});
}
