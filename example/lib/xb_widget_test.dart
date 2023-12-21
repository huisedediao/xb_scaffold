import 'package:example/theme/app_extension.dart';
import 'package:example/xb_page_test.dart';
import 'package:example/xb_widget_test_vm.dart';
import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBWidgetTest extends XBWidget<XBWidgetTestVM> {
  const XBWidgetTest({super.key});

  @override
  XBWidgetTestVM generateVM(BuildContext context) {
    return XBWidgetTestVM(context: context);
  }

  @override
  Widget buildWidget(XBWidgetTestVM vm, BuildContext context) {
    return Column(
      children: [
        Container(
          height: 100,
          width: 100,
          color: Colors.red,
          alignment: Alignment.center,
          child: Container(
            color: app.colors.white,
            child: XBImage(
              vm.app.images.arrow_down,
              width: 30,
              height: 40,
            ),
          ),
        ),
        XBButton(
            onTap: vm.changeTheme,
            child: const Padding(
              padding: EdgeInsets.all(8.0),
              child: Text('切换主题'),
            )),
        XBButton(
            onTap: () {
              vm.push(const XBPageTest());
            },
            child: const Padding(
              padding: EdgeInsets.all(8.0),
              child: Text('进入新页面'),
            ))
      ],
    );
  }
}
