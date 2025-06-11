import 'package:flutter/cupertino.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class XBTitlePicker extends StatefulWidget {
  final List<String> titles;
  final int initIndex;
  final ValueChanged<int>? onSelected;
  final Widget? selectedBG;
  final TextStyle? norStyle;
  final TextStyle? selectedStyle;

  const XBTitlePicker(
      {super.key,
      required this.titles,
      this.selectedBG,
      this.initIndex = 0,
      this.onSelected,
      this.norStyle,
      this.selectedStyle});

  @override
  State createState() => _XBTitlePickerState();
}

class _XBTitlePickerState extends State<XBTitlePicker> {
  late FixedExtentScrollController _controller;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _controller = FixedExtentScrollController(initialItem: widget.initIndex);
    _currentIndex = widget.initIndex;
  }

  @override
  void didUpdateWidget(XBTitlePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有当initIndex真的发生变化时才更新
    if (widget.initIndex != oldWidget.initIndex &&
        widget.initIndex != _currentIndex) {
      _currentIndex = widget.initIndex;
      // 使用animateToItem来平滑滚动到新位置
      _controller.animateToItem(
        widget.initIndex,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  final Color _lineColor = const Color(0xFFCCCCCC);

  @override
  Widget build(BuildContext context) {
    return CupertinoPicker(
        scrollController: _controller,
        itemExtent: 50,
        selectionOverlay: widget.selectedBG ??
            Container(
              decoration: BoxDecoration(
                  border: Border(
                      top: BorderSide(color: _lineColor, width: onePixel),
                      bottom: BorderSide(color: _lineColor, width: onePixel))),
            ),
        onSelectedItemChanged: (value) {
          setState(() {
            _currentIndex = value;
          });
          if (widget.onSelected != null) {
            widget.onSelected!(value);
          }
        },
        children: List.generate(widget.titles.length, (index) {
          return Center(
            child: Text(
              widget.titles[index],
              style: index == _currentIndex
                  ? (widget.selectedStyle ?? const TextStyle(fontSize: 14))
                  : (widget.norStyle ?? const TextStyle(fontSize: 14)),
            ),
          );
        }));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
