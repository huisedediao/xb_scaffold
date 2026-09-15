library xb_cli;
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

part 'src/command_build.dart';
part 'src/command_page_widget.dart';
part 'src/command_extension.dart';
part 'src/command_updateimg.dart';
part 'src/command_model.dart';
part 'src/command_setup.dart';
part 'src/command_skill.dart';
part 'src/shared_utils.dart';

const String _themeExtensionDirName = 'xb_scaffold_extension';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _printHelp();
    exitCode = 64;
    return;
  }

  final command = args.first.trim();
  if (command == 'help' || command == '--help' || command == '-h') {
    _printHelp();
    return;
  }

  // xb.build 透传全部原始参数（含 --config 等带路径的参数），
  // 必须在 --out/路径推断逻辑之前拦截，避免参数被剥离。
  if (_isBuildCommand(command)) {
    await _runBuild(args.sublist(1));
    return;
  }

  final rawParams = args.sublist(1);
  final params = List<String>.from(rawParams);

  String? outputPath;
  final outIndex = params.indexOf('--out');
  if (outIndex != -1) {
    if (outIndex + 1 >= params.length) {
      stderr.writeln('Missing value for --out');
      exitCode = 64;
      return;
    }
    outputPath = params[outIndex + 1];
    params.removeAt(outIndex + 1);
    params.removeAt(outIndex);
  }

  if (outputPath == null && params.length >= 2 && _looksLikePath(params.last)) {
    outputPath = params.removeLast();
  }

  final normalizedCommand = _normalize(command);
  if (normalizedCommand == 'xb.extension') {
    final targetPath =
        params.isNotEmpty ? params.first : (outputPath ?? 'lib/');
    _writeThemeExtensionFiles(targetPath);
    return;
  }

  if (normalizedCommand == 'xb.updateimg') {
    final imageDir = params.isNotEmpty ? params.first : './assets/images';
    _updateAppThemeImage(imageDir);
    return;
  }

  if (normalizedCommand == 'xb.setup') {
    _setupCliShortcuts();
    return;
  }

  if (normalizedCommand == 'xb.skill') {
    await _installSkill(params, outputPath);
    return;
  }

  if (normalizedCommand == 'xb.parsemodel') {
    if (params.length != 1) {
      stderr.writeln('Usage: xb.parsemodel <dart_model_file_path>');
      exitCode = 64;
      return;
    }
    _parseModelFile(params.first);
    return;
  }

  if (normalizedCommand == 'xb.newmodel') {
    if (params.length != 2 && params.length != 3) {
      stderr.writeln(
          'Usage: xb.newmodel <file_name> [out_path] <json_string>');
      exitCode = 64;
      return;
    }
    final fileName = params.first;
    final jsonString = params.last;
    final commandOutPath = params.length == 3 ? params[1] : outputPath;
    _newModelFromJson(
      fileName: fileName,
      outPath: commandOutPath,
      jsonString: jsonString,
    );
    return;
  }

  final content = _buildSnippet(command, params);
  if (content == null) {
    _printHelp();
    exitCode = 64;
    return;
  }

  if (outputPath == null) {
    stdout.write(_withOuterBlankLines(content));
    return;
  }

  if (normalizedCommand == 'xb.page' && params.length == 1) {
    final nameInput = params.first;
    _writeSplitPageFiles(nameInput, outputPath);
    return;
  }

  final file = File(_ensureDartFilePath(outputPath));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(_withOuterBlankLines(content));
  stdout.writeln('Generated: ${file.path}');
}


void _printHelp() {
  stdout.writeln('''XB Scaffold snippet CLI

Usage:
  xb <command> [args] [path]
  xb <command> [args] --out <path>

Examples:
  xb xb.page test_page
  xb xb.page test_page lib/pages/
  xb xb.page test_page lib/pages/test_page.dart
  xb xb.extension lib/public/
  xb xb.updateimg
  xb xb.updateimg ./assets/images
  xb xb.parsemodel lib/model/user_model.dart
  xb xb.newmodel user_model '{"name":"tom"}'
  xb xb.newmodel user_model lib/model/ '{"name":"tom"}'
  xb xb.newmodel user_model lib/model/user_model.dart '{"name":"tom"}'
  xb xb.setup
  xb xb.skill [--out <path>] [--force]
  xb xb.build [--platform ios] [--build-number 100] [--build-name 1.0.0]

Commands:
  xb.page <file_name_or_class_name>
  xb.widget <ClassName>
  xb.extension <target_directory>
  xb.updateimg [image_directory]
  xb.parsemodel <dart_model_file_path>
  xb.newmodel <file_name> [out_path] <json_string>
  xb.setup
  xb.skill [--out <path>] [--force]
  xb.build [--platform android|ios|ohos] [--build-number <num>] [--build-name <ver>]
''');
}
