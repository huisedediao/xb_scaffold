.PHONY: help install-cli uninstall-cli list-cli

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
