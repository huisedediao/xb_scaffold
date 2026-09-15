part of xb_cli;

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

  // Copy the framework README.md into the project root (silent overwrite).
  _writeScaffoldReadme();

  // Generate the AI self-install guide (overwrite silently to keep it up to date).
  _installSkill(['--force'], null);

  // Install code snippets to VS Code / Android Studio (user level, overwrite every run).
  _installCodeSnippets();
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
	xb.newmodel \
 	xb.skill \
	xb.build

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
