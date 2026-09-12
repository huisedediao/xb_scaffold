import 'dart:io';
import 'package:flutter/foundation.dart';

bool get isHarmony {
  if (kIsWeb) return false;
  return Platform.operatingSystem == 'ohos';
}
