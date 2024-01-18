import 'package:flutter/material.dart';
import 'xb_section_index_path.dart';
export 'xb_section_index_path.dart';

typedef HeaderBuilder = Widget Function(BuildContext context, int section);
typedef HoverHeaderListItemBuilder = Widget Function(
    BuildContext context, XBSectionIndexPath indexPath, double height);
typedef SectionListItemBuilder = Widget Function(
    BuildContext context, XBSectionIndexPath indexPath);
typedef HoverHeaderListSeparatorBuilder = Widget Function(BuildContext context,
    XBSectionIndexPath indexPath, double height, bool isLast);
typedef SectionListSeparatorBuilder = Widget Function(
    BuildContext context, XBSectionIndexPath indexPath, bool isLast);
typedef HoverHeaderBuilder = Widget Function(
    BuildContext context, double offset, Widget child, bool visible);
typedef HeaderHeightForSection = double Function(int section);
typedef ItemHeightForIndexPath = double Function(XBSectionIndexPath indexPath);
typedef SeparatorHeightForIndexPath = double Function(
    XBSectionIndexPath indexPath, bool isLast);
typedef SectionListOffsetChanged = void Function(
    double currentOffset, double maxOffset);
