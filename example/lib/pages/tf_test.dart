import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class TFTest extends XBPage<TFTestVM> {
  const TFTest({super.key});

  @override
  generateVM(BuildContext context) {
    return TFTestVM(context: context);
  }

  // @override
  // bool needEndEditingWhileTouch(TFTestVM vm) {
  //   return false;
  // }

  @override
  Widget buildPage(TFTestVM vm, BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          alignment: Alignment.center,
          child: XBTextField(
            placeholder: "type msg here",
          ),
        ),
        const SizedBox(height: 20),
        Container(
          width: 200,
          height: 100,
          color: Colors.blue.withOpacity(0.3),
          child: GestureDetector(
            onLongPress: () {
              vm.showToast("长按触发了！");
            },
            onTap: () {
              vm.showToast("普通点击触发了！");
            },
            child: const Center(
              child: Text(
                "测试区域\n点击或长按试试",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          "说明：\n1. 在输入框中输入文字\n2. 点击测试区域应该会收起键盘\n3. 长按测试区域不应该收起键盘",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
        ),
      ],
    );
  }
}

class TFTestVM extends XBPageVM<TFTest> {
  TFTestVM({required super.context});

  void showToast(String message) {
    toast(message);
  }
}
