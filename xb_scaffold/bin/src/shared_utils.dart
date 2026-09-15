part of xb_cli;

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
