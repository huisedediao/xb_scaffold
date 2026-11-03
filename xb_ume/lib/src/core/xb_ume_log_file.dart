// app 日志落盘（跨会话、跨重启可回溯）的抽象。
//
// 为什么要落盘：`XBUme.controller.logs` 只是内存环形缓冲（默认 2000 条），
// app 重启就没了；而 AI 验收 / 修 bug 往往要对比「改动前后两轮」的日志。
// 落盘之后，MCP 侧可以：
//   1. `xbume_console` 拿到 `logFilePath`；
//   2. `xbume_sandbox`(`action: "read"`, `path`, `offset`, `max`) 按字节分页读完，
//      不受内存缓冲条数限制，也不怕 app 重启。
//
// Web 端没有文件系统，工厂返回 null（调用方按「不落盘」处理），
// 这样 `package:xb_ume` 保持 Web 可编译 —— 见 [xb_ume_log_file_factory.dart]。
abstract class XBUmeLogFile {
  /// 当前写入文件的绝对路径；不可用时为 null。
  String? get path;

  /// 追加一条日志。实现内部必须自行缓冲 + 异步落盘，不能阻塞 UI 线程。
  void append({
    required DateTime time,
    required String level,
    required String tag,
    required String message,
    String? stack,
  });

  /// 立刻把内存缓冲刷到磁盘（失败静默：日志写不进去不能影响宿主 app）。
  Future<void> flush();

  /// 关闭文件（幂等，进程退出 / controller dispose 时调用）。
  Future<void> close();
}
