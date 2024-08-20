import 'dart:io';
import 'package:flutter/foundation.dart';

bool get isHarmony {
  if (kIsWeb) return false;
  return Platform.isAndroid == false &&
      Platform.isIOS == false &&
      Platform.isMacOS == false &&
      Platform.isWindows == false &&
      Platform.isLinux == false &&
      Platform.isFuchsia == false;
}
