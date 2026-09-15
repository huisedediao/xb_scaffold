part of xb_cli;

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
