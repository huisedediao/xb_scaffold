part of xb_cli;

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
