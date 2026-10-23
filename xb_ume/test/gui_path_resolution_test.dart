import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/ide_gui.dart' as gui;

/// Windows 上 GUI 的源码定位链路：file URI → 本机路径 → 项目根 →
/// package_config 包根。这些函数必须与运行平台无关（Windows 路径在
/// macOS 上也要解析正确），否则只能在 Windows 上手工回归。
void main() {
  group('fileUriToLocalPath', () {
    test('Windows 盘符与百分号编码', () {
      expect(
        gui.fileUriToLocalPath(
          'file:///C:/Users/John%20Doe/AppData/Local/Temp/f_jlink/lib/main.dart',
        ),
        'C:/Users/John Doe/AppData/Local/Temp/f_jlink/lib/main.dart',
      );
    });

    test('POSIX 路径保持绝对', () {
      expect(
        gui.fileUriToLocalPath('file:///Users/x/app/lib/main.dart'),
        '/Users/x/app/lib/main.dart',
      );
    });

    test('非 file URI / 空路径返回 null', () {
      expect(gui.fileUriToLocalPath('package:app/main.dart'), isNull);
      expect(gui.fileUriToLocalPath('dart:core'), isNull);
      expect(gui.fileUriToLocalPath(''), isNull);
    });
  });

  group('projectRootForLibraries', () {
    test('Windows：跳过 pub-cache，取 .dart_tool 所在项目根', () {
      expect(
        gui.projectRootForLibraries(<String>[
          'file:///C:/Users/x/AppData/Local/Pub/Cache/hosted/pub.dev/'
              'dio-5.7.0/lib/dio.dart',
          'file:///C:/dev/f_jlink/.dart_tool/flutter_build/abc/'
              'dart_plugin_registrant.dart',
          'file:///C:/dev/f_jlink/lib/main.dart',
        ]),
        'C:/dev/f_jlink',
      );
    });

    test('Windows 无 flutter_build 时按 /lib/ 截断', () {
      expect(
        gui.projectRootForLibraries(<String>[
          'file:///D:/work/my%20app/lib/main.dart',
        ]),
        'D:/work/my app',
      );
    });

    test('macOS 行为不变', () {
      expect(
        gui.projectRootForLibraries(<String>[
          'file:///Users/x/app/.dart_tool/flutter_build/abc/'
              'dart_plugin_registrant.dart',
        ]),
        '/Users/x/app',
      );
    });

    test('优先返回真实带 package_config.json 的项目根', () {
      final dir = Directory.systemTemp.createTempSync('xbume_root_');
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/.dart_tool').createSync(recursive: true);
      File('${dir.path}/.dart_tool/package_config.json')
          .writeAsStringSync('{"configVersion":2,"packages":[]}');
      final appLib = Uri.file('${dir.path}/lib/main.dart').toString();
      expect(
        gui.projectRootForLibraries(<String>[
          'file:///tmp/not-my-project/lib/main.dart',
          appLib,
        ]),
        dir.path,
      );
    });

    test('无可识别库返回 null', () {
      expect(gui.projectRootForLibraries(const <String>['dart:core']), isNull);
    });
  });

  group('packageRootPath', () {
    test('Windows pub-cache 绝对 rootUri', () {
      expect(
        gui.packageRootPath(
          'file:///C:/Users/x/AppData/Local/Pub/Cache/hosted/pub.dev/'
              'dio-5.7.0',
          'C:/dev/f_jlink',
        ),
        'C:/Users/x/AppData/Local/Pub/Cache/hosted/pub.dev/dio-5.7.0',
      );
    });

    test('相对 rootUri 以 .dart_tool 为基准归一化', () {
      expect(gui.packageRootPath('../', 'C:/dev/f_jlink'), 'C:/dev/f_jlink');
      expect(gui.packageRootPath('../', '/Users/x/app'), '/Users/x/app');
    });

    test('结尾斜杠被去掉', () {
      expect(
        gui.packageRootPath('file:///C:/pub/dio-5.7.0/', 'C:/dev/app'),
        'C:/pub/dio-5.7.0',
      );
    });
  });
}
