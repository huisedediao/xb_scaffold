import 'package:flutter/services.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class XBDialogInput extends XBWidget<InputDoubleAsVM> {
  final String title;
  final String? subTitle;
  final TextStyle? subTitleStyle;
  final String? placeholder;
  final String? initValue;
  final String? cancelTitle;
  final String? confirmTitle;
  final ValueChanged<String> onDone;
  final List<TextInputFormatter>? inputFormatters;
  final double? maxWidth;
  final double? bottomMargin;
  final String? notEmptyTip;
  final Widget? clearLeftWidget;
  final Widget? clearRightWidget;
  final Widget? unit;
  const XBDialogInput(
      {required this.title,
      this.subTitle,
      this.subTitleStyle,
      this.placeholder,
      this.initValue,
      this.inputFormatters,
      this.cancelTitle,
      this.confirmTitle,
      required this.onDone,
      this.maxWidth,
      this.bottomMargin,
      this.notEmptyTip,
      this.clearLeftWidget,
      this.clearRightWidget,
      this.unit,
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
              if (subTitle != null)
                Padding(
                  padding: EdgeInsets.only(
                      left: spaces.gapDef,
                      right: spaces.gapDef,
                      top: spaces.gapDef),
                  child: Text(subTitle ?? "",
                      style: subTitleStyle ??
                          TextStyle(
                              fontSize: fontSizes.s14, color: Colors.grey)),
                ),
              Padding(
                padding: EdgeInsets.only(
                    left: spaces.gapDef,
                    right: unit == null ? spaces.gapDef : 0,
                    top: spaces.gapDef),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: XBBG(
                        // paddingH: spaces.gapDef,
                        borderColor: Colors.grey.withAlpha(80),
                        borderWidth: onePixel,
                        defAllRadius: 6,
                        child: Row(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(left: 10),
                                child: XBTextField(
                                  key: ValueKey(vm.inputKey),
                                  focused: true,
                                  initValue: vm.value,
                                  placeholder: placeholder,
                                  inputFormatters: inputFormatters,
                                  onChanged: (value) {
                                    vm.value = value;
                                  },
                                ),
                              ),
                            ),
                            if (clearLeftWidget != null) clearLeftWidget!,
                            XBButton(
                              onTap: vm.clear,
                              coverTransparentWhileOpacity: true,
                              child: const Padding(
                                padding: EdgeInsets.all(6.0),
                                child: Icon(Icons.close,
                                    size: 20, color: Colors.grey),
                              ),
                            ),
                            if (clearRightWidget != null) clearRightWidget!,
                          ],
                        ),
                      ),
                    ),
                    if (unit != null) unit!,
                  ],
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
                          titleStyle: TextStyle(color: colors.primary),
                          title: confirmTitle ?? "确定",
                          onTap: () {
                            if (vm.value.isEmpty) {
                              toast(notEmptyTip ?? "请输入内容",
                                  bottom: screenH * 0.6);
                              return;
                            }
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

  int inputKey = 0;

  void clear() {
    value = "";
    inputKey++;
    notify();
  }
}
