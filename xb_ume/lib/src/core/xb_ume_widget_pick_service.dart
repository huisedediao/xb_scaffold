import 'package:flutter/widgets.dart';

import 'xb_ume_widget_locator_resolver.dart';

class XBUmeWidgetPickService {
  XBUmeWidgetPickService._();

  static final XBUmeWidgetPickService instance = XBUmeWidgetPickService._();

  final ValueNotifier<bool> picking = ValueNotifier<bool>(false);
  final ValueNotifier<XBUmeWidgetLocatorResult?> selectedResult =
      ValueNotifier<XBUmeWidgetLocatorResult?>(null);

  void start() {
    picking.value = true;
  }

  void stop() {
    picking.value = false;
    clearSelection();
  }

  void publishSelection(XBUmeWidgetLocatorResult? result) {
    if (identical(selectedResult.value, result)) {
      selectedResult.value = null;
    }
    selectedResult.value = result;
  }

  void clearSelection() {
    selectedResult.value = null;
  }
}
