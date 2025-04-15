import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/xb_cell/xb_right_icon.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
export 'xb_cell_center_title.dart';
export 'xb_cell_title_subtitle_arrow.dart';
export 'xb_cell_title_subtitle_left_arrow.dart';
export 'xb_cell_title_subtitle.dart';
export 'xb_cell_title_subtitle_left.dart';
export 'xb_cell_icon_title_arrow.dart';
export 'xb_cell_title_icon_arrow.dart';
export 'xb_cell_title_select.dart';
export 'xb_cell_icon_title_select.dart';
export 'xb_cell_title_switch.dart';
export 'xb_cell_icon_title_switch.dart';
export 'xb_cell_icon_title_tb.dart';
export 'xb_cell_icon_title_point_arrow.dart';
export 'xb_cell_title_point_arrow.dart';
export 'xb_cell_icon_title.dart';
export 'xb_cell_title_arrow.dart';

abstract class XBCell extends StatelessWidget {
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final Color? backgroundColor;
  final double? contentHeight;
  final BorderRadiusGeometry contentBorderRadius;
  final Color? arrowColor;
  final bool isShowArrow;
  final double? arrowLeftPadding;
  const XBCell(
      {this.margin,
      this.padding,
      this.onTap,
      this.backgroundColor,
      this.contentHeight,
      this.contentBorderRadius = BorderRadius.zero,
      this.arrowColor,
      this.isShowArrow = false,
      this.arrowLeftPadding,
      super.key});

  bool get isNeedBtn => true;

  @override
  Widget build(BuildContext context) {
    Widget child = ClipRRect(
      borderRadius: contentBorderRadius,
      child: Container(
        color: backgroundColor,
        child: Padding(
          padding: padding ?? const EdgeInsets.all(0),
          child: SizedBox(
              height: contentHeight,
              child: Row(
                children: [
                  leftWidget(),
                  Expanded(child: buildContent()),
                  rightWidget(),
                  rightArrowWidget(),
                ],
              )),
        ),
      ),
    );
    if (isNeedBtn) {
      child = XBButton(
        preventMultiTapMilliseconds: 0,
        onTap: onTap,
        coverTransparentWhileOpacity: true,
        child: child,
      );
    }
    return Padding(
      padding: margin ?? const EdgeInsets.all(0),
      child: child,
    );
  }

  Widget buildContent();

  Widget leftWidget() {
    return Container();
  }

  Widget rightWidget() {
    return Container();
  }

  Widget rightArrowWidget() {
    if (!isShowArrow) {
      return Container();
    }
    return Padding(
      padding: EdgeInsets.only(left: arrowLeftPadding ?? 5),
      child: XBCellArrow(
        color: arrowColor,
      ),
    );
  }
}
