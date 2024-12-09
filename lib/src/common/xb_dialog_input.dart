import 'package:flutter/services.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBDialogInput extends XBWidget<InputDoubleAsVM> {
  final String title;
  final String? placeholder;
  final String? initValue;
  final String? cancelTitle;
  final String? confirmTitle;
  final ValueChanged<String> onDone;
  final List<TextInputFormatter>? inputFormatters;
  final double? maxWidth;
  final double? bottomMargin;
  const XBDialogInput(
      {required this.title,
      this.placeholder,
      this.initValue,
      this.inputFormatters,
      this.cancelTitle,
      this.confirmTitle,
      required this.onDone,
      this.maxWidth,
      this.bottomMargin,
      super.key});

  @override
  generateVM(BuildContext context) {
    return InputDoubleAsVM(context: context);
  }

  @override
  Widget buildWidget(InputDoubleAsVM vm, BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottomMargin ?? 100),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          color: Colors.white,
          width: maxWidth ?? (screenW - spaces.gapDef * 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: spaces.gapDef + 5,
              ),
              Text(
                title,
                style: TextStyle(
                    fontSize: fontSizes.s16, fontWeight: fontWeights.semiBold),
              ),
              Padding(
                padding: EdgeInsets.only(
                    left: spaces.gapDef,
                    right: spaces.gapDef,
                    top: spaces.gapDef),
                child: XBBG(
                  paddingH: spaces.gapDef,
                  borderColor: Colors.grey.withAlpha(80),
                  borderWidth: onePixel,
                  defAllRadius: 6,
                  child: XBTextField(
                    focused: true,
                    initValue: initValue,
                    placeholder: placeholder,
                    inputFormatters: inputFormatters,
                    onChanged: (value) {
                      vm.value = value;
                    },
                  ),
                ),
              ),
              xbSpace(height: spaces.gapDef),
              xbLine(),
              Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                          left: spaces.gapDef, right: spaces.gapDef * 0.5),
                      child: XBCellCenterTitle(
                          contentHeight: 50,
                          contentBorderRadius: BorderRadius.circular(6),
                          titleStyle: const TextStyle(color: Colors.grey),
                          title: cancelTitle ?? "取消",
                          onTap: () {
                            pop();
                          }),
                    ),
                  ),
                  SizedBox(height: 50, child: xbLine(direction: 1)),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                          left: spaces.gapDef * 0.5, right: spaces.gapDef),
                      child: XBCellCenterTitle(
                          contentHeight: 50,
                          contentBorderRadius: BorderRadius.circular(6),
                          titleStyle: const TextStyle(color: Colors.blue),
                          title: confirmTitle ?? "确定",
                          onTap: () {
                            pop();
                            onDone(vm.value);
                          }),
                    ),
                  )
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}

class InputDoubleAsVM extends XBVM<XBDialogInput> {
  InputDoubleAsVM({required super.context}) {
    value = widget.initValue ?? "";
  }

  late String value;
}
