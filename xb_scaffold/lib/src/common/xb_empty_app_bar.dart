import 'package:flutter/material.dart';

class XBEmptyAppBar extends StatelessWidget implements PreferredSizeWidget {
  const XBEmptyAppBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Container();
  }

  @override
  Size get preferredSize => const Size(0.0, 0.0);
}
