import 'package:flutter/material.dart';
import 'xb_table_typedef.dart';

class XBTableHeader extends StatelessWidget {
  final int itemCount;
  final double height;
  final List<int>? flexs;
  final XBTableHeaderItemBuilder itemBuilder;

  const XBTableHeader(
      {this.height = 50,
      required this.itemCount,
      required this.itemBuilder,
      this.flexs,
      super.key})
      : assert(flexs == null || flexs.length == itemCount,
            "flexs不为null时，flexs的长度必须和itemCount相等");

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        children: [
          ...List.generate(itemCount, (index) {
            int flex = 1;
            if (flexs != null) {
              flex = flexs![index];
            }
            return Expanded(flex: flex, child: itemBuilder(index));
          }),
        ],
      ),
    );
  }
}
