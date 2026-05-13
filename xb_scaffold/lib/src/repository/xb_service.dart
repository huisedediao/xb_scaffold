import 'package:flutter/foundation.dart';
import 'xb_data_source.dart';

abstract class XBService {
  List<XBDataSource> get dataSources => [];

  @mustCallSuper
  void init() {
    for (final ds in dataSources) {
      ds.init();
    }
  }

  @mustCallSuper
  void dispose() {
    for (final ds in dataSources.reversed) {
      ds.dispose();
    }
  }
}
