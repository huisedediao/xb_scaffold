class XBUmeWidgetNode {
  XBUmeWidgetNode({
    required this.depth,
    required this.widgetType,
    this.key,
    this.renderSummary,
    this.childCount = 0,
  });

  final int depth;
  final String widgetType;
  final String? key;
  final String? renderSummary;
  final int childCount;
}
