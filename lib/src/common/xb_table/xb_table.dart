import 'package:flutter/material.dart';
import 'xb_table_header.dart';
import 'xb_table_index.dart';
import 'xb_table_typedef.dart';

class XBTable extends StatefulWidget {
  /// 每列的宽度比例
  final List<int>? flexs;

  /// 标题的个数
  final int titleCount;

  /// 除去标题，数据的行数
  final int cellRowCount;

  /// 数据的构建器
  final XBTableCellBuilder cellBuilder;

  /// 标题的构建器
  final XBTableHeaderItemBuilder titleBuilder;

  /// 标题的高度
  final double? titleHeight;

  /// 是否可以滑动
  final bool isCanScroll;

  const XBTable(
      {required this.titleCount,
      required this.cellRowCount,
      required this.titleBuilder,
      required this.cellBuilder,
      this.titleHeight,
      this.flexs,
      this.isCanScroll = true,
      super.key})
      : assert(flexs == null || flexs.length == titleCount,
            "flexs不为null时，flexs的长度必须和titleCount相等");

  @override
  State<XBTable> createState() => _XBTableState();
}

class _XBTableState extends State<XBTable> {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        XBTableHeader(
          height: widget.titleHeight ?? 50,
          flexs: widget.flexs,
          itemCount: widget.titleCount,
          itemBuilder: widget.titleBuilder,
        ),
        Expanded(
          child: ListView.builder(
              physics: widget.isCanScroll
                  ? null
                  : const NeverScrollableScrollPhysics(),
              itemCount: widget.cellRowCount,
              itemBuilder: ((context, rowIndex) {
                return Row(
                  children: List.generate(widget.titleCount, (columnIndex) {
                    int flex = 1;
                    if (widget.flexs != null) {
                      flex = widget.flexs![columnIndex];
                    }
                    final pathIndex =
                        XBTableIndex(row: rowIndex, column: columnIndex);
                    return Expanded(
                        flex: flex, child: widget.cellBuilder(pathIndex));
                  }),
                );
              })),
        ),
      ],
    );
  }
}
