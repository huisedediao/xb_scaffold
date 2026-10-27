// 临时探针：用本机真实 flutter run 进程验证「同设备 + 同目录」体检，
// 全程只读（ps / lsof），不启动、不 kill 任何进程。
import '../xb_ume/bin/src/device/flutter_run.dart';

void main() {
  final launcher = FlutterRunLauncher();
  final all = launcher.localFlutterRuns();
  print('localFlutterRuns (${all.length}):');
  for (final r in all) {
    print('  pid=${r.pid} device=${r.device} cwd=${r.cwd}');
  }
  if (all.isEmpty) {
    print('（本机没有外部 flutter run，跳过命中判断）');
    return;
  }
  final sample = all.first;
  final hit = launcher.findConflict(device: sample.device ?? '', cwd: sample.cwd);
  print('同设备 + 同目录 → ${hit == null ? '未命中（错误）' : '命中 pid=${hit.pid}'}');
  final otherCwd = launcher.findConflict(
      device: sample.device ?? '', cwd: '/tmp/definitely-not-this-project');
  print('同设备 + 不同目录 → ${otherCwd == null ? '未命中 ✓' : '命中（错误）'}');
  final otherDev = launcher.findConflict(
      device: 'definitely-not-this-device', cwd: sample.cwd);
  print('不同设备 + 同目录 → ${otherDev == null ? '未命中 ✓' : '命中（错误）'}');
}
