import 'package:flutter_test/flutter_test.dart';

import '../bin/ide.dart';

void main() {
  test('GUI 进程识别：部署脚本、快捷方式与 --gui 启动都命中', () {
    expect(
      isGuiProcessCommandLine(
          r'C:\dart-sdk\bin\dart.exe C:\Users\x\.xb_ume_ide\ide_gui.dart'),
      isTrue,
    );
    expect(
      isGuiProcessCommandLine(
          '/usr/local/bin/dart /Users/x/.xb_ume_ide/ide_gui.dart'),
      isTrue,
    );
    expect(isGuiProcessCommandLine('dart ide_gui.dart'), isTrue);
  });

  test('GUI 进程识别：install 自身、daemon 与无关命令不命中', () {
    // install 结束后自身命令行不含 GUI 脚本名，不能被自己杀掉。
    expect(isGuiProcessCommandLine('dart run xb_ume:ide --install'), isFalse);
    expect(
      isGuiProcessCommandLine('dart /Users/x/.xb_ume_ide/ide.dart --daemon'),
      isFalse,
    );
    // 编辑器 / grep 命令行也可能带脚本名，必须靠 dart 关键字排除。
    expect(isGuiProcessCommandLine('grep ide_gui.dart'), isFalse);
    expect(isGuiProcessCommandLine(''), isFalse);
  });
}
