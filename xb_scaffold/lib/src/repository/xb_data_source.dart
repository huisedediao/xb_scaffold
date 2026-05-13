import 'package:flutter/foundation.dart';

abstract class XBDataSource {
  @mustCallSuper
  void init() {}

  @mustCallSuper
  void dispose() {}
}
