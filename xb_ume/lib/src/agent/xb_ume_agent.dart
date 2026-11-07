// 直连 Agent 服务的对外入口。
//
// 用条件导入隔离 dart:io：Web 构建（xb_scaffold 的 example 也跑 web）拿到的是
// no-op 实现，不会因为 import 'dart:io' 直接在编译期挂掉。
library;

import '../core/xb_ume_controller.dart';
import 'xb_ume_agent_stub.dart' if (dart.library.io) 'xb_ume_agent_io.dart'
    as impl;
import 'xb_ume_agent_types.dart';

export 'xb_ume_agent_types.dart';

/// 启动 app 内直连服务；`options.enabled == false` 或平台不支持时返回 null。
Future<XBUmeAgentServer?> startXBUmeAgentServer({
  required XBUmeController controller,
  XBUmeAgentOptions options = const XBUmeAgentOptions(),
}) {
  return impl.startXBUmeAgentServer(
    controller: controller,
    options: options,
  );
}