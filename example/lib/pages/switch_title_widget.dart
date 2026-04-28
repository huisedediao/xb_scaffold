import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

class SwitchTitleWidget extends StatelessWidget {
  final List<String> titles;
  final int selectedIndex;
  final ValueChanged<int> onSelectedIndex;
  const SwitchTitleWidget({
    required this.titles,
    required this.selectedIndex,
    required this.onSelectedIndex,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      // color: colors.randColor,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.start,
          children: List.generate(titles.length, (index) {
            return XBButton(
              onTap: () {
                onSelectedIndex(index);
              },
              coverTransparentWhileOpacity: true,
              child: Padding(
                padding: EdgeInsets.only(
                  right: index == titles.length - 1 ? 0 : spaces.gapLess,
                  top: 8,
                  bottom: 8,
                ),
                child: Text(
                  titles[index],
                  style: TextStyle(
                    fontSize: index == selectedIndex ? 18 : 14,
                    fontWeight: index == selectedIndex
                        ? fontWeights.semiBold
                        : fontWeights.normal,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
