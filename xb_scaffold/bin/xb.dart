import 'dart:convert';
import 'dart:io';

const String _themeExtensionDirName = 'xb_scaffold_extension';

void main(List<String> args) {
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

void _writeThemeExtensionFiles(String basePath) {
  final normalizedBase = (basePath.endsWith('/') || basePath.endsWith('\\'))
      ? basePath.substring(0, basePath.length - 1)
      : basePath;
  final dir = Directory('$normalizedBase/$_themeExtensionDirName');
  dir.createSync(recursive: true);

  final files = <String, String>{
    'app_theme_color.dart': """import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

extension AppThemeColor on XBThemeColor {
  /// 添加需要的颜色
  Color get exampleColor => const Color.fromARGB(255, 172, 72, 72);
}
""",
    'app_theme_font_size.dart':
        """import 'package:xb_scaffold/xb_scaffold.dart';

extension AppThemeFontSize on XBThemeFontSize {
  /// 添加需要的字号
  double get s50 => 50;
}
""",
    'app_theme_font_weights.dart': """import 'package:flutter/material.dart';
import 'package:xb_scaffold/xb_scaffold.dart';

extension AppThemeFontWeight on XBThemeFontWeight {
  /// 添加需要的字重
  FontWeight get thin100 => FontWeight.w100;
}
""",
    'app_theme_image.dart': """import 'package:xb_scaffold/xb_scaffold.dart';

extension AppThemeImage on XBThemeImage {
  // 添加需要的图片路径，使用脚本生成
}
""",
    'app_theme_space.dart': """import 'package:xb_scaffold/xb_scaffold.dart';

extension AppThemeSpace on XBThemeSpace {
  /// 添加需要的间距
  double get j4 => 4;
}
""",
  };

  for (final entry in files.entries) {
    final file = File('${dir.path}/${entry.key}');
    file.writeAsStringSync(_withOuterBlankLines(entry.value));
    stdout.writeln('Generated: ${file.path}');
  }
}

void _updateAppThemeImage(String imageDirPath) {
  final imageDir = Directory(imageDirPath);
  if (!imageDir.existsSync()) {
    stderr.writeln('Image directory not found: ${imageDir.path}');
    exitCode = 64;
    return;
  }

  final dartFile = _findAppThemeImageFile();
  if (dartFile == null) {
    stderr.writeln('Cannot find app_theme_image.dart in current project.');
    exitCode = 64;
    return;
  }

  final original = dartFile.readAsStringSync();
  final openBraceIndex = original.indexOf('{');
  final lastBraceIndex = original.lastIndexOf('}');
  if (openBraceIndex == -1 ||
      lastBraceIndex == -1 ||
      lastBraceIndex <= openBraceIndex) {
    stderr.writeln('Invalid Dart file format: ${dartFile.path}');
    exitCode = 64;
    return;
  }

  final header = original.substring(0, openBraceIndex + 1);
  final body = original.substring(openBraceIndex + 1, lastBraceIndex);
  final reservedLines = body
      .split('\n')
      .where((line) => !_isGetterLine(line))
      .map((line) => line.trimRight())
      .toList();

  final files = imageDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => _basename(f.path) != '.DS_Store')
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final entries = <_ImgEntry>[];
  for (final file in files) {
    final filename = _basename(file.path);
    final relativePath =
        _relativePath(imageDir.path, file.path).replaceAll('\\', '/');
    entries.add(_ImgEntry(filename: filename, relativePath: relativePath));
  }

  final getterLines = _buildGetterLines(entries);
  final lines = <String>[];
  for (final line in reservedLines) {
    if (line.trim().isEmpty && lines.isEmpty) {
      continue;
    }
    lines.add(line);
  }
  if (lines.isNotEmpty && lines.last.trim().isNotEmpty) {
    lines.add('');
  }
  lines.addAll(getterLines);

  final next = '$header\n${lines.join('\n')}\n}';
  dartFile.writeAsStringSync(_withOuterBlankLines(next));
  stdout.writeln('Updated: ${dartFile.path}');
}

File? _findAppThemeImageFile() {
  final preferred =
      File('./lib/public/$_themeExtensionDirName/app_theme_image.dart');
  if (preferred.existsSync()) {
    return preferred;
  }

  for (final entity in Directory.current.listSync(recursive: true)) {
    if (entity is File && _basename(entity.path) == 'app_theme_image.dart') {
      return entity;
    }
  }
  return null;
}

String _relativePath(String baseDir, String fullPath) {
  final base = Directory(baseDir).absolute.path.replaceAll('\\', '/');
  final full = File(fullPath).absolute.path.replaceAll('\\', '/');
  final prefix = '$base/';
  if (full.startsWith(prefix)) {
    return full.substring(prefix.length);
  }
  return _basename(fullPath);
}

String _getterNameFromFilename(String filename) {
  final withoutExt = filename.contains('.')
      ? filename.substring(0, filename.lastIndexOf('.'))
      : filename;
  final normalized = withoutExt
      .replaceAll(RegExp(r'[^A-Za-z0-9_]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp('^_|_\$'), '');
  if (normalized.isEmpty) {
    return 'img';
  }
  if (RegExp(r'^[0-9]').hasMatch(normalized)) {
    return 'img_$normalized';
  }
  return normalized;
}

bool _isGetterLine(String line) {
  return RegExp(r'^\s*String\s+get\s+\w+\s*=>\s*imgPath\(.+\);\s*$')
      .hasMatch(line);
}

List<String> _buildGetterLines(List<_ImgEntry> entries) {
  final used = <String>{};
  final byBase = <String, List<_ImgEntry>>{};
  for (final entry in entries) {
    final base = _getterNameFromFilename(entry.filename);
    byBase.putIfAbsent(base, () => <_ImgEntry>[]).add(entry);
  }

  final result = <String>[];
  final sortedBases = byBase.keys.toList()..sort();
  for (final base in sortedBases) {
    final group = byBase[base]!
      ..sort((a, b) => a.relativePath.compareTo(b.relativePath));
    if (group.length == 1) {
      final name = _uniqueGetterName(base, used);
      result
          .add("  String get $name => imgPath('${group.first.relativePath}');");
      continue;
    }

    final extSeen = <String, int>{};
    for (final entry in group) {
      final ext = _extLower(entry.filename);
      var candidate = '${base}_$ext';
      final extCount = (extSeen[candidate] ?? 0) + 1;
      extSeen[candidate] = extCount;
      if (extCount > 1) {
        candidate = '${candidate}_$extCount';
      }
      final name = _uniqueGetterName(candidate, used);
      result.add("  String get $name => imgPath('${entry.relativePath}');");
    }
  }
  return result;
}

String _extLower(String filename) {
  final idx = filename.lastIndexOf('.');
  if (idx == -1 || idx == filename.length - 1) {
    return 'file';
  }
  return filename.substring(idx + 1).toLowerCase();
}

String _uniqueGetterName(String base, Set<String> used) {
  var name = base;
  var i = 2;
  while (used.contains(name)) {
    name = '${base}_$i';
    i++;
  }
  used.add(name);
  return name;
}

class _ImgEntry {
  _ImgEntry({required this.filename, required this.relativePath});

  final String filename;
  final String relativePath;
}

void _newModelFromJson({
  required String fileName,
  required String? outPath,
  required String jsonString,
}) {
  dynamic decoded;
  try {
    decoded = jsonDecode(jsonString);
  } catch (e) {
    stderr.writeln('Invalid JSON string: $e');
    exitCode = 64;
    return;
  }

  if (decoded is! Map<String, dynamic>) {
    stderr.writeln('Top-level JSON must be an object.');
    exitCode = 64;
    return;
  }

  final rootClassName = _toPascalCase(fileName);
  final generator = _ModelGenerator(rootClassName: rootClassName);
  final content = generator.generate(decoded);

  if (outPath == null || outPath.trim().isEmpty) {
    stdout.write(_withOuterBlankLines(content));
    return;
  }

  final filePath = _resolveModelOutputFilePath(fileName, outPath);
  final file = File(filePath);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(_withOuterBlankLines(content));
  stdout.writeln('Generated: ${file.path}');
}

String _resolveModelOutputFilePath(String fileName, String outPath) {
  if (_looksLikeDirPath(outPath)) {
    final dir = outPath.endsWith('/') || outPath.endsWith('\\')
        ? outPath.substring(0, outPath.length - 1)
        : outPath;
    return '$dir/${_toSnakeCase(fileName)}.dart';
  }
  return _ensureDartFilePath(outPath);
}

class _ModelGenerator {
  _ModelGenerator({required this.rootClassName});

  final String rootClassName;
  final List<_ModelClassDef> _classes = <_ModelClassDef>[];
  final Set<String> _generatedClassNames = <String>{};

  String generate(Map<String, dynamic> rootMap) {
    _buildClass(rootClassName, rootMap);
    final buffer = StringBuffer();
    buffer.writeln("import 'package:xb_scaffold/xb_scaffold.dart';");
    buffer.writeln();

    for (int i = 0; i < _classes.length; i++) {
      if (i > 0) {
        buffer.writeln();
      }
      buffer.write(_classes[i].toCode());
    }
    return buffer.toString().trimRight();
  }

  void _buildClass(String className, Map<String, dynamic> map) {
    if (_generatedClassNames.contains(className)) return;
    _generatedClassNames.add(className);

    final fields = <_ModelField>[];
    for (final entry in map.entries) {
      final key = entry.key;
      final value = entry.value;
      final fieldName = _safeFieldName(_toCamelCase(key));
      final type = _inferType(
        parentClassName: className,
        jsonKey: key,
        value: value,
      );
      fields.add(
        _ModelField(
          jsonKey: key,
          name: fieldName,
          type: type,
        ),
      );
    }
    _classes.add(_ModelClassDef(name: className, fields: fields));
  }

  _ModelType _inferType({
    required String parentClassName,
    required String jsonKey,
    required dynamic value,
  }) {
    if (value == null) {
      return _ModelType.dynamicType();
    }
    if (value is String) {
      return _ModelType.primitive('String');
    }
    if (value is int) {
      return _ModelType.primitive('int');
    }
    if (value is double) {
      return _ModelType.primitive('double');
    }
    if (value is bool) {
      return _ModelType.primitive('bool');
    }
    if (value is Map<String, dynamic>) {
      final nestedClassName =
          _uniqueClassName('$parentClassName${_toPascalCase(jsonKey)}');
      _buildClass(nestedClassName, value);
      return _ModelType.object(nestedClassName);
    }
    if (value is List) {
      if (value.isEmpty) {
        return _ModelType.listOf('dynamic');
      }
      final firstNonNull = value.firstWhere((e) => e != null, orElse: () => null);
      if (firstNonNull == null) {
        return _ModelType.listOf('dynamic');
      }
      if (firstNonNull is String) return _ModelType.listOf('String');
      if (firstNonNull is int) return _ModelType.listOf('int');
      if (firstNonNull is double) return _ModelType.listOf('double');
      if (firstNonNull is bool) return _ModelType.listOf('bool');
      if (firstNonNull is Map<String, dynamic>) {
        final nestedClassName =
            _uniqueClassName('$parentClassName${_toPascalCase(jsonKey)}Item');
        _buildClass(nestedClassName, firstNonNull);
        return _ModelType.listOfObject(nestedClassName);
      }
      return _ModelType.listOf('dynamic');
    }
    return _ModelType.dynamicType();
  }

  String _uniqueClassName(String base) {
    if (!_generatedClassNames.contains(base)) return base;
    int i = 2;
    while (_generatedClassNames.contains('$base$i')) {
      i++;
    }
    return '$base$i';
  }
}

class _ModelClassDef {
  _ModelClassDef({
    required this.name,
    required this.fields,
  });

  final String name;
  final List<_ModelField> fields;

  String toCode() {
    final buffer = StringBuffer();
    buffer.writeln('class $name {');
    for (final field in fields) {
      buffer.writeln('  ${field.declarationType}? ${field.name};');
    }
    buffer.writeln();
    buffer.writeln('  $name({');
    for (final field in fields) {
      buffer.writeln('    this.${field.name},');
    }
    buffer.writeln('  });');
    buffer.writeln();
    buffer.writeln('  $name.fromJson(Map<String, dynamic> json) {');
    for (final field in fields) {
      buffer.writeln('    ${field.name} = ${field.fromJsonExpr};');
    }
    buffer.writeln('  }');
    buffer.writeln();
    buffer.writeln('  Map<String, dynamic> toJson() {');
    buffer.writeln('    final Map<String, dynamic> retMap = {};');
    for (final field in fields) {
      buffer.writeln('    ${field.toJsonStmt}');
    }
    buffer.writeln('    return retMap;');
    buffer.writeln('  }');
    buffer.writeln('}');
    return buffer.toString();
  }
}

class _ModelField {
  _ModelField({
    required this.jsonKey,
    required this.name,
    required this.type,
  });

  final String jsonKey;
  final String name;
  final _ModelType type;

  String get declarationType => type.declarationType;

  String get fromJsonExpr {
    if (type.isPrimitive || type.isDynamic) {
      return "xbParse<${type.baseType}>(json['$jsonKey'])";
    }
    if (type.isObject) {
      return "xbParse(json['$jsonKey'], factory: ${type.baseType}.fromJson)";
    }
    if (type.isListPrimitive) {
      return "xbParseList<${type.baseType}>(json['$jsonKey'])";
    }
    if (type.isListObject) {
      return "xbParseList(json['$jsonKey'], factory: ${type.baseType}.fromJson)";
    }
    return "json['$jsonKey']";
  }

  String get toJsonStmt {
    if (type.isObject) {
      return "retMap['$jsonKey'] = $name?.toJson();";
    }
    if (type.isListObject) {
      return "if ($name != null) { retMap['$jsonKey'] = $name!.map((v) => v.toJson()).toList(); }";
    }
    return "retMap['$jsonKey'] = $name;";
  }
}

class _ModelType {
  _ModelType._({
    required this.baseType,
    this.collection = _Collection.none,
  });

  final String baseType;
  final _Collection collection;

  factory _ModelType.primitive(String type) => _ModelType._(baseType: type);

  factory _ModelType.object(String type) => _ModelType._(baseType: type);

  factory _ModelType.listOf(String type) =>
      _ModelType._(baseType: type, collection: _Collection.listPrimitive);

  factory _ModelType.listOfObject(String type) =>
      _ModelType._(baseType: type, collection: _Collection.listObject);

  factory _ModelType.dynamicType() => _ModelType._(baseType: 'dynamic');

  bool get isDynamic => baseType == 'dynamic' && collection == _Collection.none;
  bool get isPrimitive =>
      collection == _Collection.none &&
      (baseType == 'String' ||
          baseType == 'int' ||
          baseType == 'double' ||
          baseType == 'bool' ||
          baseType == 'dynamic');
  bool get isObject => collection == _Collection.none && !isPrimitive;
  bool get isListPrimitive => collection == _Collection.listPrimitive;
  bool get isListObject => collection == _Collection.listObject;

  String get declarationType {
    if (collection == _Collection.listPrimitive ||
        collection == _Collection.listObject) {
      return 'List<$baseType>';
    }
    return baseType;
  }
}

enum _Collection { none, listPrimitive, listObject }

String _toCamelCase(String input) {
  if (!input.contains(RegExp(r'[^A-Za-z0-9]+'))) {
    if (input.isEmpty) return input;
    return '${input[0].toLowerCase()}${input.substring(1)}';
  }
  final parts =
      input.split(RegExp(r'[^A-Za-z0-9]+')).where((e) => e.isNotEmpty).toList();
  if (parts.isEmpty) return input;
  final first = parts.first.toLowerCase();
  final rest = parts
      .skip(1)
      .map((p) => '${p[0].toUpperCase()}${p.substring(1).toLowerCase()}')
      .join();
  return '$first$rest';
}

String _safeFieldName(String name) {
  var ret = name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  if (ret.isEmpty) ret = 'value';
  if (RegExp(r'^[0-9]').hasMatch(ret)) {
    ret = 'f$ret';
  }
  const keywords = <String>{
    'abstract',
    'as',
    'assert',
    'async',
    'await',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'covariant',
    'default',
    'deferred',
    'do',
    'dynamic',
    'else',
    'enum',
    'export',
    'extends',
    'extension',
    'external',
    'factory',
    'false',
    'final',
    'finally',
    'for',
    'Function',
    'get',
    'hide',
    'if',
    'implements',
    'import',
    'in',
    'interface',
    'is',
    'late',
    'library',
    'mixin',
    'new',
    'null',
    'on',
    'operator',
    'part',
    'required',
    'rethrow',
    'return',
    'set',
    'show',
    'static',
    'super',
    'switch',
    'sync',
    'this',
    'throw',
    'true',
    'try',
    'typedef',
    'var',
    'void',
    'while',
    'with',
    'yield',
  };
  if (keywords.contains(ret)) {
    ret = '${ret}Value';
  }
  return ret;
}

void _parseModelFile(String filePath) {
  final file = File(filePath);
  if (!file.existsSync()) {
    stderr.writeln('File not found: $filePath');
    exitCode = 64;
    return;
  }

  final input = file.readAsStringSync();
  final result = _transformModelInput(input);
  stdout.writeln(result);
}

String _transformModelInput(String input) {
  final classRegex = RegExp(r'class\s+(\w+)\s*\{([^}]*)\}', multiLine: true);
  final output = <String>[];

  for (final classMatch in classRegex.allMatches(input)) {
    final className = classMatch.group(1);
    final classBody = classMatch.group(2);
    if (className == null || classBody == null) {
      continue;
    }

    final variableRegex =
        RegExp(r'(\w+\s*\?\s*\w+;|\w+\s+\w+;|List<\w+>\s*\?\s*\w+;|List<\w+>\s+\w+;)');
    final variables = variableRegex
        .allMatches(classBody)
        .map((m) => m.group(0)!)
        .toList(growable: false);

    final classOutput = <String>[
      '\n\n\n----------------------------$className----------------------------',
      '\n$className.fromJson(Map<String, dynamic> json) {',
    ];

    const continueTypes = <String>{'return'};
    final fieldRegex = RegExp(r'(\w+)(?:<([^>]+)>)?\s*\??\s*(\w+)');

    for (final variable in variables) {
      final match = fieldRegex.firstMatch(variable);
      if (match == null) continue;

      final varType = match.group(1) ?? '';
      final innerType = match.group(2) ?? '';
      final varName = match.group(3) ?? '';
      final isNullable = variable.contains('?');

      if (continueTypes.contains(varType) || varName.isEmpty) continue;

      final defaultValue = <String, String>{
            'String': '""',
            'int': '0',
            'double': '0.0',
            'bool': 'false',
            'List': '[]',
          }[varType] ??
          '$varType()';
      final append = isNullable ? '' : ' ?? $defaultValue';

      switch (varType) {
        case 'String':
        case 'int':
        case 'double':
        case 'bool':
          classOutput
              .add("    $varName = xbParse<$varType>(json['$varName'])$append;");
          break;
        case 'dynamic':
        case 'Null':
          classOutput.add("    $varName = json['$varName'];");
          break;
        case 'List':
          switch (innerType) {
            case 'String':
            case 'int':
            case 'double':
            case 'bool':
            case 'Null':
              classOutput.add(
                  "    $varName = xbParseList<$innerType>(json['$varName'])$append;");
              break;
            default:
              classOutput.add(
                  "    $varName = xbParseList(json['$varName'], factory: $innerType.fromJson)$append;");
              break;
          }
          break;
        default:
          classOutput.add(
              "    $varName = xbParse(json['$varName'], factory: $varType.fromJson)$append;");
          break;
      }
    }

    classOutput.add('}');

    final toJsonOutput = <String>[
      '\nMap<String, dynamic> toJson() {',
      '    final Map<String, dynamic> retMap = {};',
    ];

    for (final variable in variables) {
      final match = fieldRegex.firstMatch(variable);
      if (match == null) continue;

      final varType = match.group(1) ?? '';
      final innerType = match.group(2) ?? '';
      final varName = match.group(3) ?? '';

      if (continueTypes.contains(varType) || varName.isEmpty) continue;

      if (varType == 'List') {
        if (innerType == 'bool' ||
            innerType == 'int' ||
            innerType == 'double' ||
            innerType == 'String' ||
            innerType == 'Null') {
          toJsonOutput.add("    retMap['$varName'] = $varName;");
        } else {
          toJsonOutput.add('    if ($varName != null) {');
          toJsonOutput
              .add("        retMap['$varName'] = $varName!.map((v) => v.toJson()).toList();");
          toJsonOutput.add('    }');
        }
      } else if (varType == 'dynamic' ||
          varType == 'bool' ||
          varType == 'int' ||
          varType == 'double' ||
          varType == 'String' ||
          varType == 'Null') {
        toJsonOutput.add("    retMap['$varName'] = $varName;");
      } else {
        toJsonOutput.add("    retMap['$varName'] = $varName?.toJson();");
      }
    }

    toJsonOutput.add('    return retMap;');
    toJsonOutput.add('}\n');

    output.add(classOutput.join('\n'));
    output.add(toJsonOutput.join('\n'));
  }

  return output.join('\n');
}

void _setupCliShortcuts() {
  _writeProjectMakefile();

  final makeResult = Process.runSync('make', ['install-cli']);
  if (makeResult.stdout != null &&
      makeResult.stdout.toString().trim().isNotEmpty) {
    stdout.write(makeResult.stdout);
  }
  if (makeResult.stderr != null &&
      makeResult.stderr.toString().trim().isNotEmpty) {
    stderr.write(makeResult.stderr);
  }
  if (makeResult.exitCode != 0) {
    stderr.writeln(
        'make install-cli failed with exit code: ${makeResult.exitCode}');
  }

  if (Platform.isMacOS) {
    _ensureZshPath();
    stdout.writeln('PATH config written for macOS zsh.');
    stdout.writeln('Run in your current terminal: source ~/.zshrc');
    stdout.writeln('If still not found, run: hash -r');
  } else if (Platform.isWindows) {
    stdout.writeln(
      'Please add %USERPROFILE%\\.local\\bin to your PATH environment variable.',
    );
  }

  // Bootstrap extension files and image getters with default paths.
  _writeThemeExtensionFiles('lib/');
  _updateAppThemeImage('./assets/images');
}

void _writeProjectMakefile() {
  const content = r'''.PHONY: help install-cli uninstall-cli list-cli

BIN_DIR ?= $(HOME)/.local/bin
RUNNER ?= dart run xb_scaffold:xb

CMDS := \
	xb.page \
	xb.widget \
	xb.extension \
	xb.updateimg \
	xb.parsemodel \
	xb.newmodel

help:
	@echo "Usage:"
	@echo "  make install-cli                     # install xb.* commands to $(BIN_DIR)"
	@echo "  make install-cli BIN_DIR=./.bin      # install to custom dir"
	@echo "  make uninstall-cli                   # remove installed xb.* commands"
	@echo "  make list-cli                        # show command names"
	@echo ""
	@echo "After install, you can run:"
	@echo "  xb.page test_page lib/src/"
	@echo "  xb.extension"
	@echo "  xb.updateimg"
	@echo "  xb.parsemodel lib/model/user_model.dart"
	@echo "  xb.newmodel user_model '{\"name\":\"tom\"}'"

install-cli:
	@mkdir -p "$(BIN_DIR)"
	@for cmd in $(CMDS); do \
		file="$(BIN_DIR)/$$cmd"; \
		printf '%s\n' '#!/usr/bin/env bash' > "$$file"; \
		printf '%s\n' 'set -euo pipefail' >> "$$file"; \
		printf '%s\n' '$(RUNNER) '"$$cmd"' "$$@"' >> "$$file"; \
		chmod +x "$$file"; \
		echo "Installed $$file"; \
	done
	@echo ""
	@echo "If command not found, add to PATH:"
	@echo '  export PATH="$(BIN_DIR):$$PATH"'

uninstall-cli:
	@for cmd in $(CMDS); do \
		file="$(BIN_DIR)/$$cmd"; \
		if [ -f "$$file" ]; then rm -f "$$file" && echo "Removed $$file"; fi; \
	done

list-cli:
	@for cmd in $(CMDS); do echo "$$cmd"; done
''';

  final file = File('Makefile');
  file.writeAsStringSync(content);
  stdout.writeln('Generated: ${file.path}');
}

void _ensureZshPath() {
  final zshrc = File('${Platform.environment['HOME']}/.zshrc');
  if (!zshrc.existsSync()) {
    zshrc.createSync(recursive: true);
  }
  const line = 'export PATH="\$HOME/.local/bin:\$PATH"';
  final text = zshrc.readAsStringSync();
  if (!text.contains(line)) {
    final needsNewline = text.isNotEmpty && !text.endsWith('\n');
    final next = '${needsNewline ? '\n' : ''}$line\n';
    zshrc.writeAsStringSync(text + next);
    stdout.writeln('Updated: ${zshrc.path}');
  }
}

String _toPascalCase(String input) {
  final parts =
      input.split(RegExp(r'[^A-Za-z0-9]+')).where((e) => e.isNotEmpty).toList();
  if (parts.isEmpty) return input;
  return parts
      .map((part) =>
          '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}')
      .join();
}

String _toSnakeCase(String input) {
  final withUnderscore = input
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .toLowerCase();
  return withUnderscore.replaceAll(RegExp(r'^_|_$'), '');
}

bool _looksLikeDirPath(String value) {
  if (value.endsWith('/') || value.endsWith('\\')) return true;
  if (!_looksLikePath(value)) return false;
  final base = _basename(value);
  return !base.contains('.');
}

String _widgetSnippet(String className) {
  return """import 'package:xb_scaffold/xb_scaffold.dart';
import 'package:flutter/material.dart';

class $className extends XBWidget<${className}VM> {
  const $className({super.key});

  @override
  ${className}VM generateVM(BuildContext context) {
    return ${className}VM(context: context);
  }

  @override
  Widget buildWidget(BuildContext context) {
    return Container();
  }
}

class ${className}VM extends XBVM<$className> {
  ${className}VM({required super.context});
}
""";
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

Commands:
  xb.page <file_name_or_class_name>
  xb.widget <ClassName>
  xb.extension <target_directory>
  xb.updateimg [image_directory]
  xb.parsemodel <dart_model_file_path>
  xb.newmodel <file_name> [out_path] <json_string>
  xb.setup
''');
}
