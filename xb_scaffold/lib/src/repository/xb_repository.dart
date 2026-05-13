import 'package:flutter/foundation.dart';
import 'xb_service.dart';

abstract class XBRepository {
  List<XBService> get services => [];

  @mustCallSuper
  void init() {
    for (final service in services) {
      service.init();
    }
  }

  @mustCallSuper
  void dispose() {
    for (final service in services.reversed) {
      service.dispose();
    }
  }
}
