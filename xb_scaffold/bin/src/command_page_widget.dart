part of xb_cli;

String _withOuterBlankLines(String content) {
  final normalized = content.endsWith('\n') ? content : '$content\n';
  return '\n\n$normalized\n\n';
}

String? _buildSnippet(String command, List<String> args) {
  switch (_normalize(command)) {
    case 'xb.page':
      return _singleArg(args, _pageSnippet);
    case 'xb.widget':
      return _singleArg(args, _widgetSnippet);
    default:
      return null;
  }
}

String _normalize(String command) {
  final c = command.trim().toLowerCase();
  switch (c) {
    case 'xb_page':
    case 'xb.page':
    case 'page':
      return 'xb.page';
    case 'xb_widget':
    case 'xb.widget':
    case 'widget':
      return 'xb.widget';
    case 'xb_extension':
    case 'xb.extension':
    case 'extension':
      return 'xb.extension';
    case 'xb_updateimg':
    case 'xb.updateimg':
    case 'updateimg':
      return 'xb.updateimg';
    case 'xb_setup':
    case 'xb.setup':
    case 'setup':
      return 'xb.setup';
    case 'xb_skill':
    case 'xb.skill':
    case 'skill':
      return 'xb.skill';
    case 'xb_parsemodel':
    case 'xb.parsemodel':
    case 'parsemodel':
      return 'xb.parsemodel';
    case 'xb_newmodel':
    case 'xb.newmodel':
    case 'newmodel':
      return 'xb.newmodel';
    default:
      return c;
  }
}

String? _singleArg(List<String> args, String Function(String value) builder) {
  if (args.length != 1) return null;
  return builder(args.first);
}

bool _looksLikePath(String value) {
  return value.startsWith('/') ||
      value.startsWith('./') ||
      value.startsWith('../') ||
      value.contains('/') ||
      value.endsWith('.dart') ||
      value.endsWith('.txt') ||
      value.endsWith('.json');
}

String _pageSnippet(String nameInput) {
  final className = _toPascalCase(nameInput);
  return """import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class $className extends XBPage<${className}VM> {
  const $className({super.key});

  @override
  ${className}VM generateVM(BuildContext context) {
    return ${className}VM(context: context);
  }

  @override
  Widget buildPage(BuildContext context) {
    return Container();
  }
}

class ${className}VM extends XBPageVM<$className> {
  ${className}VM({required super.context});
}
""";
}

void _writeSplitPageFiles(String nameInput, String outputPath) {
  final className = _toPascalCase(nameInput);
  final pageFile = File(_resolvePageFilePath(nameInput, outputPath));
  final dir = pageFile.parent;
  dir.createSync(recursive: true);

  final pageFileName = _basename(pageFile.path);
  final vmFileName = _withVmSuffix(pageFileName);
  final vmFile = File('${dir.path}/$vmFileName');

  final pageContent = """import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';
import '$vmFileName';

class $className extends XBPage<${className}VM> {
  const $className({super.key});

  @override
  ${className}VM generateVM(BuildContext context) {
    return ${className}VM(context: context);
  }

  @override
  Widget buildPage(BuildContext context) {
    return Container();
  }
}
""";

  final vmContent = """import 'package:xb_scaffold/xb_scaffold.dart';
import '$pageFileName';

class ${className}VM extends XBPageVM<$className> {
  ${className}VM({required super.context});
}
""";

  pageFile.writeAsStringSync(_withOuterBlankLines(pageContent));
  vmFile.writeAsStringSync(_withOuterBlankLines(vmContent));

  stdout.writeln('Generated: ${pageFile.path}');
  stdout.writeln('Generated: ${vmFile.path}');
}

String _resolvePageFilePath(String nameInput, String outputPath) {
  final pageFileName = _toSnakeCase(nameInput);
  if (_looksLikeDirPath(outputPath)) {
    final dir = outputPath.endsWith('/') || outputPath.endsWith('\\')
        ? outputPath.substring(0, outputPath.length - 1)
        : outputPath;
    return '$dir/$pageFileName.dart';
  }
  return _ensureDartFilePath(outputPath);
}

String _ensureDartFilePath(String path) {
  if (path.endsWith('.dart')) {
    return path;
  }
  return '$path.dart';
}

String _ensureMarkdownFilePath(String path) {
  if (path.endsWith('.md')) {
    return path;
  }
  return '$path.md';
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  if (index == -1) return normalized;
  return normalized.substring(index + 1);
}

String _withVmSuffix(String fileName) {
  if (fileName.endsWith('.dart')) {
    return '${fileName.substring(0, fileName.length - 5)}_vm.dart';
  }
  return '${fileName}_vm.dart';
}
