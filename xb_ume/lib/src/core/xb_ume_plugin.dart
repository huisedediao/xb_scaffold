import 'package:flutter/material.dart';

import 'xb_ume_controller.dart';

abstract class XBUmePlugin {
  String get id;
  String get title;
  IconData get icon;

  void onRegister(XBUmeController controller) {}

  void onUnregister(XBUmeController controller) {}

  Widget buildPanel(BuildContext context, XBUmeController controller);
}
