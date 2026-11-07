// Web / 不支持的平台：直连服务不做任何事（没有 dart:io 的 Socket）。
library;

import '../core/xb_ume_controller.dart';
import 'xb_ume_agent_types.dart';

Future<XBUmeAgentServer?> startXBUmeAgentServer({
  required XBUmeController controller,
  XBUmeAgentOptions options = const XBUmeAgentOptions(),
}) async {
  return null;
}