part of xb_cli;

const String _skillName = 'xb-scaffold';
const String _skillDefaultGuideFileName = 'xb-scaffold-ai-guide.md';

/// Locate the bundled skill directory inside the xb_scaffold package.
Future<Directory?> _resolveSkillSourceDir() async {
  final packageRootDir = await _resolvePackageRoot();
  final packageRoot = packageRootDir?.path;
  if (packageRoot == null) {
    return null;
  }
  return Directory('$packageRoot/skill/$_skillName');
}

/// Copy the framework README.md into the project root as README_XBScaffold.md
/// (silent overwrite to keep it in sync with the installed package version).
Future<void> _writeScaffoldReadme() async {
  final packageRootDir = await _resolvePackageRoot();
  final packageRoot = packageRootDir?.path;
  if (packageRoot == null) {
    stderr
        .writeln('xb.setup: skip README_XBScaffold.md, package root not found.');
    return;
  }
  final source = File('$packageRoot/README.md');
  if (!source.existsSync()) {
    stderr.writeln(
        'xb.setup: skip README_XBScaffold.md, source not found: ${source.path}');
    return;
  }
  final target = File('README_XBScaffold.md');
  target.writeAsStringSync(source.readAsStringSync());
  stdout.writeln('Generated (overwrite): ${target.path}');
}

const String _snippetFileName = 'xb_scaffold_code_snippets.code-snippets';
const String _snippetGroupName = 'xb_scaffold_code_snippets';

/// 安装 xb_scaffold 代码片段（每次 xb.setup 静默覆盖，保持与包版本同步）：
/// - VS Code 系（VS Code/Cursor/Qoder 等）：写入项目级 `.vscode/$_snippetFileName`，
///   随项目走、可进 Git，所有 VS Code 系 IDE 共用同一份；
/// - Android Studio/IntelliJ：JSON 转换为 Live Templates 组 XML 写入用户级
///   templates 目录（JetBrains Live Templates 无项目级存储，仅支持用户级）；
/// 片段单一数据源：<packageRoot>/bin/templates/$_snippetFileName
Future<void> _installCodeSnippets() async {
  final packageRootDir = await _resolvePackageRoot();
  final packageRoot = packageRootDir?.path;
  if (packageRoot == null) {
    stderr.writeln('xb.setup: skip code snippets, package root not found.');
    return;
  }
  final source = File('$packageRoot/bin/templates/$_snippetFileName');
  if (!source.existsSync()) {
    stderr.writeln(
        'xb.setup: skip code snippets, source not found: ${source.path}');
    return;
  }
  final content = source.readAsStringSync();

  // Project-level snippets dir: shared by all VS Code-based IDEs
  // (VS Code / Cursor / Qoder read the same .vscode/ of the workspace root).
  final vsCodeDir = Directory('.vscode');
  final vsCodeTarget = File('${vsCodeDir.path}/$_snippetFileName');
  vsCodeDir.createSync(recursive: true);
  vsCodeTarget.writeAsStringSync(content);
  stdout.writeln('Generated (overwrite): ${vsCodeTarget.path} (project level, shared by VS Code/Cursor/Qoder)');

  var jetBrainsCount = 0;
  for (final dir in _jetBrainsTemplatesDirs()) {
    final target = File('${dir.path}/$_snippetGroupName.xml');
    dir.createSync(recursive: true);
    target.writeAsStringSync(_convertSnippetsToLiveTemplatesXml(content));
    stdout.writeln('Generated (overwrite): ${target.path}');
    jetBrainsCount++;
  }
  if (jetBrainsCount == 0) {
    stdout.writeln(
        'xb.setup: Android Studio/IntelliJ config dir not found, skipped.');
  } else {
    stdout.writeln(
        'Restart Android Studio/IntelliJ to load "$_snippetGroupName" live templates.');
  }
}

String? _userHomeDir() {
  if (Platform.isWindows) {
    return Platform.environment['USERPROFILE'];
  }
  return Platform.environment['HOME'];
}

/// Android Studio/IntelliJ 用户级 Live Templates 目录候选
/// （<configRoot>/<IDE 版本目录>/templates，仅返回 IDE 配置目录已存在者）
List<Directory> _jetBrainsTemplatesDirs() {
  final home = _userHomeDir();
  if (home == null) {
    return const [];
  }
  List<String> roots;
  if (Platform.isMacOS) {
    roots = [
      '$home/Library/Application Support/Google',
      '$home/Library/Application Support/JetBrains',
    ];
  } else if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'] ?? '';
    roots = ['$appData/Google', '$appData/JetBrains'];
  } else {
    roots = ['$home/.config/Google', '$home/.config/JetBrains'];
  }
  const idePrefixes = ['AndroidStudio', 'IntelliJIDEA', 'IntelliJIdea'];
  final result = <Directory>[];
  for (final root in roots) {
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) {
      continue;
    }
    for (final entry in rootDir.listSync()) {
      if (entry is! Directory) {
        continue;
      }
      final name = entry.uri.pathSegments.reversed
          .firstWhere((segment) => segment.isNotEmpty, orElse: () => '');
      if (idePrefixes.any((prefix) => name.startsWith(prefix))) {
        result.add(Directory('${entry.path}/templates'));
      }
    }
  }
  return result;
}

final RegExp _snippetPlaceholderExp =
    RegExp(r'\$\{(\d+)(?::([^{}]*))?\}|\$(\d+)');

/// 把 VS Code 片段 JSON（JSONC，允许注释）转换为 JetBrains Live Templates 组 XML：
/// - $1 / ${1:default} → 命名变量 $V1$（同名变量多处出现自动联动），
///   default 记入 variable 的 defaultValue；
/// - 末尾追加 $END$（展开后光标终点）；
/// - 适用上下文限定为 Dart。
String _convertSnippetsToLiveTemplatesXml(String jsoncContent) {
  final decoded = jsonDecode(_stripJsoncComments(jsoncContent));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('snippet json must be an object');
  }
  final buffer = StringBuffer('<templateSet group="$_snippetGroupName">\n');
  decoded.forEach((name, rawSnippet) {
    final snippet = rawSnippet as Map<String, dynamic>;
    final bodyLines = (snippet['body'] as List).cast<String>();
    final description = _escapeXml((snippet['description'] ?? name).toString());
    final variables = <String, String?>{};
    final value = bodyLines
        .map((line) => _convertSnippetPlaceholders(line, variables))
        .join('\n');
    const endMark = r'$END$';
    final fullValue = value.contains(endMark) ? value : '$value\n$endMark';

    buffer.writeln('  <template name="${_escapeXml(name)}" '
        'value="${_escapeXml(fullValue)}" '
        'description="$description" '
        'toReformat="true" toShortenFQNames="true">');
    variables.forEach((varName, defaultValue) {
      buffer.writeln('    <variable name="$varName" expression="" '
          'defaultValue="${_escapeXml(defaultValue ?? '')}" '
          'alwaysStopAt="true" />');
    });
    buffer.writeln('    <context>');
    buffer.writeln('      <option name="DART" value="true" />');
    buffer.writeln('    </context>');
    buffer.writeln('  </template>');
  });
  buffer.writeln('</templateSet>');
  return buffer.toString();
}

/// 剥离 JSONC 注释（字符串感知：不处理字符串内部的 //，如 dart import 路径）
String _stripJsoncComments(String content) {
  final buffer = StringBuffer();
  var inString = false;
  var i = 0;
  while (i < content.length) {
    final char = content[i];
    if (inString) {
      buffer.write(char);
      if (char == r'\' && i + 1 < content.length) {
        buffer.write(content[i + 1]);
        i += 2;
        continue;
      }
      if (char == '"') {
        inString = false;
      }
      i++;
      continue;
    }
    if (char == '"') {
      inString = true;
      buffer.write(char);
      i++;
      continue;
    }
    if (char == '/' && i + 1 < content.length) {
      final next = content[i + 1];
      if (next == '/') {
        while (i < content.length && content[i] != '\n') {
          i++;
        }
        continue;
      }
      if (next == '*') {
        i += 2;
        while (i + 1 < content.length &&
            !(content[i] == '*' && content[i + 1] == '/')) {
          i++;
        }
        i += 2;
        continue;
      }
    }
    buffer.write(char);
    i++;
  }
  return buffer.toString();
}

String _convertSnippetPlaceholders(
    String text, Map<String, String?> variables) {
  return text.replaceAllMapped(_snippetPlaceholderExp, (match) {
    final index = match[1] ?? match[3];
    final varName = 'V$index';
    variables.putIfAbsent(varName, () => match[2]);
    return '\$$varName\$';
  });
}

String _escapeXml(String text) {
  return text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

bool _confirmOverwrite(String targetPath) {
  stdout.write('xb.skill: target exists: $targetPath\nOverwrite? [y/N] ');
  final answer = stdin.readLineSync();
  return answer != null && answer.trim().toLowerCase() == 'y';
}

/// Return the leading `--- ... ---` frontmatter block of [content],
/// or null when the content has no frontmatter.
String? _frontmatterOf(String content) {
  if (!content.startsWith('---')) {
    return null;
  }
  final end = content.indexOf('\n---', 3);
  if (end == -1) {
    return null;
  }
  return content.substring(0, end + 4).trimRight();
}

/// Strip the leading frontmatter block from [content].
String _stripFrontmatter(String content) {
  final frontmatter = _frontmatterOf(content);
  if (frontmatter == null) {
    return content.trimLeft();
  }
  return content.substring(frontmatter.length).trimLeft();
}

const List<String> _skillReferenceFileNames = [
  'core.md',
  'ui-components.md',
  'theme-cli-repository.md',
  'utils-pitfalls.md',
];

/// Assemble the AI self-install guide from the bundled skill files.
/// The skill directory stays the single source of truth; the guide is
/// rebuilt at every run so it can never drift from the skill content.
String _buildAiGuideDoc(Directory sourceDir) {
  final skillFile = File('${sourceDir.path}/SKILL.md');
  if (!skillFile.existsSync()) {
    throw StateError('SKILL.md not found in ${sourceDir.path}');
  }
  final skillContent = skillFile.readAsStringSync();
  final frontmatter = _frontmatterOf(skillContent);
  final skillBody = _stripFrontmatter(skillContent);

  final buffer = StringBuffer();
  buffer.writeln('''# xb_scaffold AI Skill Install Guide (for AI assistants)

This document was generated by the `xb.skill` command of the xb_scaffold
Flutter package. It contains the complete xb_scaffold knowledge base plus
instructions for you (the AI assistant reading this) to install that
knowledge as a native skill / rule of the tool you are currently running in.

## Part 1: Instructions for the AI assistant

1. Read Part 2 below. It holds the skill knowledge, split into sections
   marked with `<!-- section: <relative-path> -->` comments.
2. Install the knowledge as a native skill / rule of YOUR tool. Common
   mappings (adjust to whatever your tool actually supports):

   | Tool | Where to write what |
   |---|---|
   | Qoder | `.qoder/skills/xb-scaffold/SKILL.md` (with the YAML frontmatter) |
   | Claude Code | `.claude/skills/xb-scaffold/SKILL.md` (with the YAML frontmatter) |
   | Cursor | `.cursor/rules/xb-scaffold.mdc` (convert the frontmatter to mdc format: description, alwaysApply: false) |
   | Windsurf | `.windsurf/rules/xb-scaffold.md` |
   | Other / unsure | Your tool's project rules/memory mechanism, or a root `AGENTS.md` entry |

3. Splitting rules:
   - The `<!-- section: SKILL.md -->` section becomes the main skill file.
     Prepend the YAML frontmatter template provided inside that section.
   - Each `<!-- section: reference/<name>.md -->` section becomes
     `reference/<name>.md` next to the main skill file.
   - Keep file names, headings, code blocks and the frontmatter exactly as
     given (translate nothing).
   - If a previous installation of this skill already exists at the target
     location, overwrite it entirely with the current content — do not
     merge or keep stale sections.
4. When your tool needs an index/description, reuse the skill's `name` and
   `description` from the frontmatter template.
5. After writing the files, confirm to the user where the skill was
   installed and that future xb_scaffold tasks will use it automatically.
   If your tool has no skill/rules mechanism at all, keep this guide file in
   the repository and read it whenever you work on xb_scaffold-related code.

---

## Part 2: Skill knowledge base
''');

  buffer.writeln('<!-- section: SKILL.md -->');
  buffer.writeln();
  if (frontmatter != null) {
    buffer.writeln('Use the following frontmatter when writing SKILL.md:');
    buffer.writeln();
    buffer.writeln('```yaml');
    buffer.writeln(frontmatter);
    buffer.writeln('```');
    buffer.writeln();
  }
  buffer.writeln(skillBody);
  buffer.writeln();

  final referenceDir = Directory('${sourceDir.path}/reference');
  for (final name in _skillReferenceFileNames) {
    final file = File('${referenceDir.path}/$name');
    if (!file.existsSync()) {
      continue;
    }
    buffer.writeln('<!-- section: reference/$name -->');
    buffer.writeln();
    buffer.writeln(_stripFrontmatter(file.readAsStringSync()));
    buffer.writeln();
  }

  return buffer.toString();
}

/// xb.skill [--out <path>] [--force]
/// Generates a single AI self-install guide document at the project root
/// (default: xb-scaffold-ai-guide.md). The document teaches any AI coding
/// assistant how to install the bundled xb_scaffold knowledge as a native
/// skill / rule of whatever tool it is running in.
Future<void> _installSkill(List<String> params, String? outputPath) async {
  final force = params.contains('--force');

  final remaining = params
      .where((p) => !p.startsWith('--') && p.trim().isNotEmpty)
      .toList();
  final targetPath = _ensureMarkdownFilePath(outputPath ??
      (remaining.isNotEmpty ? remaining.first : _skillDefaultGuideFileName));

  final sourceDir = await _resolveSkillSourceDir();
  if (sourceDir == null || !sourceDir.existsSync()) {
    stderr.writeln('xb.skill: bundled skill directory not found inside the '
        'xb_scaffold package (skill/$_skillName).');
    exitCode = 1;
    return;
  }

  final target = File(targetPath);
  if (target.existsSync() && !force && !_confirmOverwrite(targetPath)) {
    stdout.writeln('xb.skill: skipped $targetPath');
    return;
  }

  String doc;
  try {
    doc = _buildAiGuideDoc(sourceDir);
  } catch (e) {
    stderr.writeln('xb.skill: failed to assemble the guide: $e');
    exitCode = 1;
    return;
  }

  target.parent.createSync(recursive: true);
  target.writeAsStringSync(doc);
  stdout.writeln('xb.skill: AI self-install guide generated at $targetPath');
  stdout.writeln(
      'xb.skill: ask your AI assistant to read and execute the instructions '
          'in that file to install the xb_scaffold skill.');
}
