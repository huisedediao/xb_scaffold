import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';
export 'xb_sys_space_mixin.dart';

abstract class XBState<T extends StatefulWidget> extends State<T>
    with XBSysSpaceMixin, XBThemeMixin, XBRouteMixin {}
