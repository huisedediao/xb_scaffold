import 'package:flutter/material.dart';
import 'package:xb_scaffold/src/common/xb_fade_widget.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

abstract class XBPageVM<T> extends XBVM<T> {
  XBPageVM({required super.context}) {
    if ((widget as XBPage).needInitLoading()) {
      _isLoading = true;
    }
  }

  bool _isLoading = false;

  bool get isLoading => _isLoading;

  GlobalKey<XBFadeWidgetState>? _fadeKey;

  GlobalKey<XBFadeWidgetState> get fadeKey {
    _fadeKey ??= GlobalKey();
    return _fadeKey!;
  }

  bool get needLoading => (widget as XBPage).needLoading();

  showLoading() {
    if (needLoading) {
      _isLoading = true;
      notify();

      fadeKey.currentState?.show();
    }
  }

  hideLoading() {
    if (needLoading) {
      fadeKey.currentState?.hide(() {
        _isLoading = false;
        notify();
      });
    }
  }
}
