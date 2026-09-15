part of xb_cli;

bool _isBuildCommand(String command) {
  final c = command.trim().toLowerCase();
  return c == 'xb.build' || c == 'xb_build' || c == 'build';
}

/// 定位当前运行的 xb_scaffold 包根目录（pub cache / git 缓存 / 本地路径均可）。
Future<Directory?> _resolvePackageRoot() async {
  Uri? uri;
  try {
    uri = await Isolate.resolvePackageUri(
        Uri.parse('package:xb_scaffold/xb_scaffold.dart'));
  } catch (_) {
    return null;
  }
  if (uri == null || !uri.isScheme('file')) {
    return null;
  }
  final path = Uri.parse(uri.toString().replaceFirst('file://', '')).path;
  final libIndex = path.indexOf('/lib/');
  if (libIndex == -1) {
    return null;
  }
  return Directory(path.substring(0, libIndex));
}

/// xb.build：以当前目录为项目根，调起通用打包工具（Python 实现）。
/// 透传全部原始参数，stdout/stderr 直接透传实现实时日志。
Future<void> _runBuild(List<String> params) async {
  final packageRoot = await _resolvePackageRoot();
  if (packageRoot == null || !packageRoot.existsSync()) {
    stderr.writeln('xb.build: 无法定位 xb_scaffold 包目录');
    exitCode = 1;
    return;
  }
  final script = File('${packageRoot.path}/tool/build/xb_build.py');
  if (!script.existsSync()) {
    stderr.writeln('xb.build: 未找到打包脚本 ${script.path}');
    exitCode = 1;
    return;
  }
  final proc = await Process.start(
    'python3',
    [script.path, '--project-dir', Directory.current.path, ...params],
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await proc.exitCode;
}
