import 'package:flutter/material.dart';
import 'xb_title_picker.dart';
import 'xb_title_picker_index.dart';

class XBTitlePickerMulti extends StatefulWidget {
  final List<List<String>> mulTitles;
  final ValueChanged<XBTitlePickerIndex>? onSelected;
  final List<int> selecteds;
  final Widget? selectedBG;
  final TextStyle? norStyle;
  final TextStyle? selectedStyle;
  final List<int> flexs;

  const XBTitlePickerMulti(
      {super.key,
      required this.mulTitles,
      required this.selecteds,
      this.selectedBG,
      this.onSelected,
      this.norStyle,
      this.selectedStyle,
      this.flexs = const [1, 1, 1]})
      : assert(mulTitles.length > 0, "mulTitles元素个数不能为0"),
        assert(selecteds.length == mulTitles.length,
            "mulTitles和selecteds的元素个数必须相同");

  @override
  State<XBTitlePickerMulti> createState() => _XBTitlePickerMultiState();
}

class _XBTitlePickerMultiState extends State<XBTitlePickerMulti> {
  late List<int> _currentSelecteds;

  @override
  void initState() {
    super.initState();
    _currentSelecteds = List<int>.from(widget.selecteds);
  }

  @override
  void didUpdateWidget(XBTitlePickerMulti oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 检查selecteds是否发生变化
    if (!_listsEqual(_currentSelecteds, widget.selecteds)) {
      setState(() {
        _currentSelecteds = List<int>.from(widget.selecteds);
      });
    }
  }

  // 比较两个List<int>是否相等的辅助方法
  bool _listsEqual(List<int> list1, List<int> list2) {
    if (list1.length != list2.length) return false;
    for (int i = 0; i < list1.length; i++) {
      if (list1[i] != list2[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(widget.mulTitles.length, (column) {
        return Expanded(
          flex: widget.flexs[column],
          child: XBTitlePicker(
            selectedStyle: widget.selectedStyle,
            norStyle: widget.norStyle,
            selectedBG: widget.selectedBG,
            titles: widget.mulTitles[column],
            onSelected: (index) {
              // 更新内部状态
              setState(() {
                _currentSelecteds[column] = index;
              });

              if (widget.onSelected != null) {
                widget.onSelected!(XBTitlePickerIndex(column, index));
              }
            },
            initIndex: _currentSelecteds[column],
          ),
        );
      }),
    );
  }
}
