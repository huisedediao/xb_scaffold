import 'package:flutter/material.dart';
import 'xb_theme/xb_theme_vm.dart';

abstract class XBStatelessWidget extends StatelessWidget {
  const XBStatelessWidget({super.key});
  XBTheme get app => XBThemeVM().theme;
}
