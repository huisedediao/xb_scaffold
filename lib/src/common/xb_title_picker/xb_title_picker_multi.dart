import 'package:flutter/material.dart';
import 'xb_title_picker.dart';
import 'xb_title_picker_index.dart';

class XBTitlePickerMulti extends StatelessWidget {
  final List<List<String>> mulTitles;
  final ValueChanged<XBTitlePickerIndex>? onSelected;
  final List<int> selecteds;
  final Widget? selectedBG;
  final TextStyle? norStyle;
  final TextStyle? selectedStyle;

  const XBTitlePickerMulti(
      {super.key,
      required this.mulTitles,
      required this.selecteds,
      this.selectedBG,
      this.onSelected,
      this.norStyle,
      this.selectedStyle})
      : assert(mulTitles.length > 0, "mulTitles元素个数不能为0"),
        assert(selecteds.length == mulTitles.length,
            "mulTitles和selecteds的元素个数必须相同");

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(mulTitles.length, (column) {
        return Expanded(
          child: XBTitlePicker(
            selectedStyle: selectedStyle,
            norStyle: norStyle,
            selectedBG: selectedBG,
            titles: mulTitles[column],
            onSelected: (index) {
              if (onSelected != null) {
                onSelected!(XBTitlePickerIndex(column, index));
              }
            },
            initIndex: selecteds[column],
          ),
        );
      }),
    );
  }
}
